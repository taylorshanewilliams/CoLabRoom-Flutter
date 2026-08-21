"""RunPod Serverless handler wrapping Demucs (htdemucs) source separation,
plus lightweight librosa-based BPM, instrument-presence, and song-structure
detection that ride along on the same stems before they're discarded.

Input:  {"input": {"audio_url": "<signed URL>", "filename": "song.mp3"}}
Output: {
  "harmonic_mix_b64": "<base64 mp3>",
  "bpm": <float | null>,
  "instruments": {"vocals": {...}, "guitar": {...}, "bass": {...}, "drums": {...}},
  "structure": [{"start_ms", "end_ms", "label", "repeats_section_label"}, ...]
} or {"error": "..."} on failure.

Takes a URL rather than the audio inline — RunPod's own /run endpoint
caps request bodies at 10MiB, which a base64-encoded full song blows
past easily (the failure mode of an earlier version of this pipeline).
The caller (analyze-chords Edge Function) hands this a short-lived
Supabase Storage signed URL; this handler downloads the file itself.

Returns only the bass+other mix (the harmonic content ChordMini reads —
see the Phase 0.5 validation notes) as compressed MP3, not all four raw
WAV stems. An earlier version returned all four uncompressed — RunPod's
job-result response silently dropped the output entirely once it got
that large (no error, the "output" field just never appeared). Mixing
down to one track and compressing it were both necessary, not just nice
to have.

bpm/instruments/structure are all best-effort: htdemucs' vocals.wav and
drums.wav stems are computed as a normal byproduct of separation and were
previously thrown away entirely once the harmonic mix was built — reading
them for this before discarding them is close to free. Each detector is
wrapped in its own try/except so a librosa failure on any one doesn't take
down chord detection or lyrics, which don't depend on any of this.
"""

import base64
import os
import subprocess
import tempfile

import librosa
import numpy as np
import requests
import runpod

# Matches the on-device chord-detection fallback's silence threshold in
# song_analysis_service.dart (`rms < 0.008`) — same convention, so "present"
# means roughly the same thing whether the cloud or on-device path decided it.
SILENCE_RMS_THRESHOLD = 0.008


def _load_audio(path: str) -> tuple[np.ndarray | None, int | None]:
    """Single decode+resample per file — bpm/instrument-presence/structure
    used to each independently reload drums.wav and/or the original mix,
    which meant the same audio got decoded and resampled to 22050Hz two or
    three times over on every job. Loading each file exactly once here and
    passing the waveform around cuts that redundant work out entirely.
    """
    try:
        y, sr = librosa.load(path, sr=22050, mono=True)
        return y, sr
    except Exception:
        return None, None


def _stem_presence(y: np.ndarray | None) -> dict | None:
    """Energy-presence, not real instrument recognition — confidence is a
    normalized RMS ratio, not a classifier score. Returns None (rather than
    a false "not present") if the stem couldn't be loaded at all.
    """
    if y is None:
        return None
    if y.size == 0:
        return {"present": False, "confidence": 0.0}
    rms = float(np.sqrt(np.mean(np.square(y))))
    confidence = max(0.0, min(1.0, rms / (SILENCE_RMS_THRESHOLD * 5)))
    return {"present": rms > SILENCE_RMS_THRESHOLD, "confidence": round(confidence, 3)}


def _detect_bpm(
    y_drums: np.ndarray | None,
    sr_drums: int | None,
    y_fallback: np.ndarray | None,
    sr_fallback: int | None,
) -> float | None:
    """Beat-tracks the isolated drum stem first (the natural source for
    tempo) — falls back to the full original mix when drums are silent or
    absent (a cappella, programmed/no-drums demos), rather than guessing.
    """
    for y, sr in ((y_drums, sr_drums), (y_fallback, sr_fallback)):
        if y is None or y.size == 0:
            continue
        try:
            rms = float(np.sqrt(np.mean(np.square(y))))
            if rms < SILENCE_RMS_THRESHOLD:
                continue
            tempo, _ = librosa.beat.beat_track(y=y, sr=sr, units="frames")
            bpm = float(np.asarray(tempo).reshape(-1)[0]) if np.asarray(tempo).size else 0.0
            if bpm > 0:
                return round(bpm, 1)
        except Exception:
            continue
    return None


def _detect_structure(y: np.ndarray | None, sr: int | None, target_sections: int = 8) -> list[dict]:
    """Chroma self-similarity boundary detection — labels are purely
    positional ("Section A" is whichever comes first in the timeline, not
    "the chorus"), with a separate repeat hint pointing back to an earlier
    section whose chroma closely matches. Never asserts Verse/Chorus/Bridge;
    see StructureSection's doc comment on the Dart side for why.
    """
    if y is None:
        return []
    try:
        duration_s = float(librosa.get_duration(y=y, sr=sr))
        if duration_s < 20:
            return []  # too short for a meaningful multi-section split

        chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
        frame_count = chroma.shape[1]
        if frame_count < 10:
            return []

        k = max(2, min(target_sections, frame_count // 200))
        boundary_frames = librosa.segment.agglomerative(chroma, k)
        boundary_times = sorted(float(t) for t in librosa.frames_to_time(boundary_frames, sr=sr))
        bounds = sorted(set([0.0] + boundary_times + [duration_s]))
        if len(bounds) < 3:
            return []  # fewer than 2 actual segments isn't a useful structure

        vectors: list[np.ndarray] = []
        sections: list[dict] = []
        for i in range(len(bounds) - 1):
            start_s, end_s = bounds[i], bounds[i + 1]
            start_frame = librosa.time_to_frames(start_s, sr=sr)
            end_frame = max(start_frame + 1, librosa.time_to_frames(end_s, sr=sr))
            segment_chroma = chroma[:, start_frame:end_frame]
            vector = segment_chroma.mean(axis=1) if segment_chroma.size else np.zeros(chroma.shape[0])
            norm = float(np.linalg.norm(vector))
            vectors.append(vector / norm if norm > 0 else vector)

            label = f"Section {chr(ord('A') + i)}" if i < 26 else f"Section {i + 1}"
            repeats_label = None
            best_similarity = 0.85
            for j in range(i):
                similarity = float(np.dot(vectors[i], vectors[j]))
                if similarity >= best_similarity:
                    best_similarity = similarity
                    repeats_label = sections[j]["label"]

            sections.append(
                {
                    "start_ms": round(start_s * 1000),
                    "end_ms": round(end_s * 1000),
                    "label": label,
                    "repeats_section_label": repeats_label,
                }
            )
        return sections
    except Exception:
        return []


def handler(job):
    job_input = job.get("input", {})
    audio_url = job_input.get("audio_url")
    filename = job_input.get("filename", "input.mp3")
    if not audio_url:
        return {"error": "Missing 'audio_url' in input."}

    with tempfile.TemporaryDirectory() as tmp:
        in_path = os.path.join(tmp, filename)
        try:
            response = requests.get(audio_url, timeout=60)
            response.raise_for_status()
        except requests.RequestException as error:
            return {"error": f"Could not download audio from signed URL: {error}"}
        with open(in_path, "wb") as f:
            f.write(response.content)

        out_dir = os.path.join(tmp, "separated")
        result = subprocess.run(
            ["python", "-m", "demucs", "-n", "htdemucs", "-o", out_dir, in_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return {"error": f"demucs failed: {result.stderr[-2000:]}"}

        name = os.path.splitext(os.path.basename(filename))[0]
        base = os.path.join(out_dir, "htdemucs", name)
        vocals_path = os.path.join(base, "vocals.wav")
        drums_path = os.path.join(base, "drums.wav")
        bass_path = os.path.join(base, "bass.wav")
        other_path = os.path.join(base, "other.wav")
        if not os.path.exists(bass_path) or not os.path.exists(other_path):
            return {"error": f"Expected stems not found under {base}"}

        y_vocals, _ = _load_audio(vocals_path)
        y_drums, sr_drums = _load_audio(drums_path)
        y_bass, _ = _load_audio(bass_path)
        y_other, _ = _load_audio(other_path)
        y_mix, sr_mix = _load_audio(in_path)

        bpm = _detect_bpm(y_drums, sr_drums, y_mix, sr_mix)
        instruments = {
            "vocals": _stem_presence(y_vocals),
            "drums": _stem_presence(y_drums),
            "bass": _stem_presence(y_bass),
            # "other" covers guitar/keys/synth indiscriminately at this
            # stage — labeled "guitar" on the wire for the app's existing
            # "Guitar/Keys" chip, not a claim it's specifically a guitar.
            "guitar": _stem_presence(y_other),
        }
        structure = _detect_structure(y_mix, sr_mix)

        # ffmpeg's amix mixes the two stems and re-encodes to MP3 in one
        # pass, instead of a separate numpy/soundfile mixing step plus a
        # second encode call.
        mix_path = os.path.join(tmp, "harmonic_mix.mp3")
        mix_result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                bass_path,
                "-i",
                other_path,
                "-filter_complex",
                "amix=inputs=2:duration=longest",
                "-codec:a",
                "libmp3lame",
                "-qscale:a",
                "4",
                mix_path,
            ],
            capture_output=True,
            text=True,
        )
        if mix_result.returncode != 0 or not os.path.exists(mix_path):
            return {"error": f"ffmpeg mix failed: {mix_result.stderr[-2000:]}"}

        with open(mix_path, "rb") as f:
            harmonic_mix_b64 = base64.b64encode(f.read()).decode("ascii")

        return {
            "harmonic_mix_b64": harmonic_mix_b64,
            "bpm": bpm,
            "instruments": instruments,
            "structure": structure,
        }


runpod.serverless.start({"handler": handler})
