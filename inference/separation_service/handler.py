"""RunPod Serverless handler wrapping Demucs (htdemucs_6s) source separation,
plus librosa-based BPM, key, instrument-presence, and song-structure detection
that ride along on the same stems.

Input:  {"input": {
          "audio_url": "<signed URL>",
          "filename": "song.mp3",
          "stem_uploads": {"vocals": "<signed PUT url>", ...},  # optional
          "mix_upload": "<signed PUT url>"                      # optional
        }}
Output: {
  "harmonic_mix_uploaded": true,
  "harmonic_mix_b64": "<base64 mp3>",   # only when mix_upload was absent
  "bpm": <float | null>,
  "key": "<e.g. 'A minor'> | null",
  "instruments": {"vocals": {...}, "guitar": {...}, "piano": {...}, "bass": {...}, "drums": {...}},
  "structure": [{"start_ms", "end_ms", "label", "repeats_section_label"}, ...],
  "uploaded_stems": ["vocals", "bass", ...]
} or {"error": "..."} on failure.

Takes a URL rather than the audio inline — RunPod's own /run endpoint
caps request bodies at 10MiB, which a base64-encoded full song blows
past easily (the failure mode of an earlier version of this pipeline).
The caller (analyze-chords Edge Function) hands this a short-lived
Supabase Storage signed URL; this handler downloads the file itself.

Stems go back the same way, in reverse: the Edge Function mints one signed
*upload* URL per stem and this handler PUTs each compressed stem straight to
Supabase Storage. Deliberately not returned inline — an earlier version tried
returning all four raw WAV stems in the job result and RunPod silently dropped
the entire "output" field once it got that large (no error, the field just
never appeared). Only the harmonic mix still travels inline, because the chord
service needs it immediately and it is one compressed file.

htdemucs_6s rather than htdemucs: the 6-source model splits guitar and piano
into their own stems instead of folding them into "other". That split is what
makes per-instrument playback possible, and the harmonic mix fed to ChordMini
is correspondingly the sum of bass+other+guitar+piano — with the 6-source
model, bass+other alone would be *missing* most of the harmony.

bpm/key/instruments/structure are all best-effort, each wrapped in its own
try/except so a librosa failure on any one doesn't take down chord detection
or lyrics, which don't depend on any of them.
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

# htdemucs_6s source names, as demucs writes them into its output directory.
STEM_NAMES = ("vocals", "drums", "bass", "guitar", "piano", "other")

# Stems whose sum is the harmonic content ChordMini reads.
HARMONIC_STEMS = ("bass", "other", "guitar", "piano")

PITCH_CLASSES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")

# Krumhansl-Schmuckler key profiles: the perceived stability of each scale
# degree relative to the tonic, from Krumhansl's probe-tone experiments.
# Correlating a piece's pitch-class distribution against all 24 rotations of
# these is the standard key-finding method — it actually weighs scale
# membership, unlike counting which chord root appears most, which is what
# the Edge Function used to do.
KS_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KS_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


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


def _sum_waveforms(
    waveforms: dict[str, np.ndarray | None], stems: tuple[str, ...]
) -> np.ndarray | None:
    """Sums the given stems into one waveform, zero-padding to the longest.

    All stems come from the same source file at the same sample rate, so
    lengths should already match — the padding is defensive against demucs
    rounding a stem a frame short rather than an expected case.
    """
    present = [waveforms[s] for s in stems if waveforms.get(s) is not None and waveforms[s].size > 0]
    if not present:
        return None
    length = max(y.size for y in present)
    total = np.zeros(length, dtype=np.float32)
    for y in present:
        total[: y.size] += y
    return total


def _detect_key(y: np.ndarray | None, sr: int | None) -> str | None:
    """Krumhansl-Schmuckler key estimation over the harmonic stems.

    Runs on the harmonic mix rather than the full song on purpose: drums
    contribute broadband noise to every chroma bin and vocals wander in
    pitch, both of which blur the pitch-class distribution this depends on.
    """
    if y is None or y.size == 0:
        return None
    try:
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
        if chroma.size == 0:
            return None
        profile = chroma.mean(axis=1)
        if not np.any(profile):
            return None

        best_name: str | None = None
        best_score = -2.0
        for tonic in range(12):
            # Rotate so the candidate tonic sits at index 0, matching how the
            # KS profiles are written (index 0 = tonic).
            rotated = np.roll(profile, -tonic)
            for mode, reference in (("major", KS_MAJOR), ("minor", KS_MINOR)):
                score = float(np.corrcoef(rotated, reference)[0, 1])
                if np.isnan(score):
                    continue
                if score > best_score:
                    best_score = score
                    best_name = f"{PITCH_CLASSES[tonic]} {mode}"
        return best_name
    except Exception:
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


def _encode_mp3(source_path: str, target_path: str) -> bool:
    """Demucs writes WAV; stems ship as MP3. A 4-minute stereo WAV is ~40MB
    and the same audio at V4 is ~4MB, which matters both for the upload here
    and for every playback stream the app serves later.
    """
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", source_path, "-codec:a", "libmp3lame", "-qscale:a", "4", target_path],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and os.path.exists(target_path)


def _upload_stem(signed_url: str, file_path: str) -> bool:
    """PUTs one encoded stem to a Supabase Storage signed upload URL.

    Signed upload URLs are minted by the Edge Function with the service role,
    so this worker never needs Supabase credentials of its own — the same
    reason the download side takes a signed URL rather than a key.
    """
    try:
        with open(file_path, "rb") as f:
            response = requests.put(
                signed_url,
                data=f,
                headers={"content-type": "audio/mpeg", "x-upsert": "true"},
                timeout=120,
            )
        return response.status_code in (200, 201)
    except requests.RequestException:
        return False


def handler(job):
    job_input = job.get("input", {})
    audio_url = job_input.get("audio_url")
    filename = job_input.get("filename", "input.mp3")
    stem_uploads = job_input.get("stem_uploads") or {}
    mix_upload = job_input.get("mix_upload")
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
            ["python", "-m", "demucs", "-n", "htdemucs_6s", "-o", out_dir, in_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return {"error": f"demucs failed: {result.stderr[-2000:]}"}

        name = os.path.splitext(os.path.basename(filename))[0]
        base = os.path.join(out_dir, "htdemucs_6s", name)
        stem_paths = {stem: os.path.join(base, f"{stem}.wav") for stem in STEM_NAMES}

        missing = [s for s in HARMONIC_STEMS if not os.path.exists(stem_paths[s])]
        if missing:
            return {"error": f"Expected stems {missing} not found under {base}"}

        waveforms: dict[str, np.ndarray | None] = {}
        sample_rates: dict[str, int | None] = {}
        for stem, path in stem_paths.items():
            y, sr = _load_audio(path) if os.path.exists(path) else (None, None)
            waveforms[stem] = y
            sample_rates[stem] = sr
        y_mix, sr_mix = _load_audio(in_path)

        bpm = _detect_bpm(waveforms["drums"], sample_rates["drums"], y_mix, sr_mix)
        instruments = {stem: _stem_presence(waveforms[stem]) for stem in STEM_NAMES}
        structure = _detect_structure(y_mix, sr_mix)

        # ffmpeg's amix sums the harmonic stems and re-encodes to MP3 in one
        # pass. amix always divides by the input count, which would leave the
        # mix at a quarter of its natural level — these stems are
        # complementary parts of one original mix, so their plain sum is what
        # reconstructs that mix's harmonic content.
        #
        # Multiplying the level back up with `volume` rather than passing
        # `amix=...:normalize=0`: that option only exists in ffmpeg 5+, and
        # this image ships 4.4 (the conda ffmpeg from the pytorch base), where
        # it fails the whole filter graph with "Option 'normalize' not found".
        # volume= is equivalent here and works on every ffmpeg version.
        mix_path = os.path.join(tmp, "harmonic_mix.mp3")
        mix_inputs: list[str] = []
        for stem in HARMONIC_STEMS:
            mix_inputs.extend(["-i", stem_paths[stem]])
        stem_count = len(HARMONIC_STEMS)
        mix_result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                *mix_inputs,
                "-filter_complex",
                f"amix=inputs={stem_count}:duration=longest,volume={stem_count}",
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

        # Key runs on the summed harmonic waveforms already in memory rather
        # than on the encoded mix — one less decode, and no lossy-compression
        # artifacts smearing the chroma bins this depends on.
        musical_key = _detect_key(_sum_waveforms(waveforms, HARMONIC_STEMS), 22050)

        # Best-effort: a stem that fails to encode or upload is a missing
        # playback option, not a failed analysis. Chords and lyrics don't
        # depend on any of this succeeding.
        uploaded_stems: list[str] = []
        for stem, signed_url in stem_uploads.items():
            source = stem_paths.get(stem)
            if not source or not os.path.exists(source) or not isinstance(signed_url, str):
                continue
            encoded = os.path.join(tmp, f"{stem}.mp3")
            if not _encode_mp3(source, encoded):
                continue
            if _upload_stem(signed_url, encoded):
                uploaded_stems.append(stem)

        # Preferred path: push the harmonic mix to Storage like the stems and
        # let the caller stream it straight into the chord service.
        #
        # The base64 fallback below is genuinely expensive on the caller's
        # side — the encoded string, the decoded binary string, and the byte
        # array all coexist in the Edge Function's memory, which is how a
        # 5 MB mix became a WORKER_RESOURCE_LIMIT. Only fall back when the
        # caller didn't offer somewhere to put the file.
        mix_uploaded = False
        if isinstance(mix_upload, str) and mix_upload:
            mix_uploaded = _upload_stem(mix_upload, mix_path)

        result = {
            "harmonic_mix_uploaded": mix_uploaded,
            "bpm": bpm,
            "key": musical_key,
            "instruments": instruments,
            "structure": structure,
            "uploaded_stems": uploaded_stems,
        }
        if not mix_uploaded:
            with open(mix_path, "rb") as f:
                result["harmonic_mix_b64"] = base64.b64encode(f.read()).decode("ascii")
        return result


if __name__ == "__main__":
    # Guarded so the module can be imported without booting a worker — the
    # smoke test calls handler() directly, and an unguarded start() here
    # meant importing this file launched the RunPod loop, which immediately
    # exited looking for test_input.json. The Dockerfile's CMD runs this file
    # as __main__, so the deployed path is unchanged.
    runpod.serverless.start({"handler": handler})
