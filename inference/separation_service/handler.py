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

Song structure comes from the All-In-One analyzer (Kim & Nam, ISMIR 2023),
which names sections — Intro, Verse, Chorus — rather than lettering them.
That costs a second source-separation pass, since the model wants its own;
see _detect_structure for why the trained model is the only thing that can
answer the question at all.

bpm/key/instruments/structure are all best-effort, each wrapped in its own
try/except so a failure in any one doesn't take down chord detection or
lyrics, which don't depend on any of them.
"""

import base64
import concurrent.futures
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


def _detect_beats(path: str) -> dict:
    """Beat and downbeat times, via Beat This! (ISMIR 2024, MIT licensed).

    librosa's beat_track gives a tempo number and nothing else. Downbeats —
    where each bar starts — are what actually make the analysis musical: they
    are the difference between a chord that begins "at 1.847 seconds" and one
    that begins "on beat 3 of bar 12". Bar lines, a count-in, and any future
    notation all need them, and no amount of tempo estimation produces them.

    Runs on the original mix rather than a stem: the model was trained on
    full mixes, and drums alone lose the harmonic cues it uses when a track
    has no clear kick pattern.

    Best-effort like every other detector here — a failure returns empties
    rather than taking down chords and lyrics, which don't depend on it.
    """
    empty = {"beats_ms": [], "downbeats_ms": [], "bpm": None, "beats_per_bar": None}
    try:
        import torch
        from beat_this.inference import File2Beats

        device = "cuda" if torch.cuda.is_available() else "cpu"
        # dbn=False is the paper's headline result: the postprocessing DBN it
        # replaces imposes a constant meter and tempo, which is wrong for
        # anything with a time-signature change or real rubato.
        file2beats = File2Beats(checkpoint_path="final0", device=device, dbn=False)
        beats, downbeats = file2beats(path)

        beats_ms = [round(float(t) * 1000) for t in beats]
        downbeats_ms = [round(float(t) * 1000) for t in downbeats]
        if len(beats_ms) < 2:
            return empty

        intervals = np.diff(np.asarray(beats_ms, dtype=float))
        intervals = intervals[intervals > 0]
        bpm = round(60000.0 / float(np.median(intervals)), 1) if intervals.size else None

        # Beats per bar, counted rather than assumed: how many beats fall
        # between one downbeat and the next. The median survives a pickup bar
        # or a dropped beat, where a mean would not.
        beats_per_bar = None
        if len(downbeats_ms) >= 2:
            counts = []
            for start, end in zip(downbeats_ms, downbeats_ms[1:]):
                counts.append(sum(1 for b in beats_ms if start <= b < end))
            counts = [c for c in counts if c > 0]
            if counts:
                candidate = int(round(float(np.median(counts))))
                # Anything outside this is far likelier to be a detection
                # artifact than a genuine 13/8, and asserting it would be
                # worse than saying nothing.
                if 2 <= candidate <= 12:
                    beats_per_bar = candidate

        return {
            "beats_ms": beats_ms,
            "downbeats_ms": downbeats_ms,
            "bpm": bpm,
            "beats_per_bar": beats_per_bar,
        }
    except Exception:
        return empty


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


# A section shorter than this is a boundary artifact, not a part of the song.
# Without it, chroma segmentation happily reports two-second "sections" at
# every transient, which is how a four-minute song ended up described as eight
# parts, four of them under three seconds long.
MIN_SECTION_SECONDS = 10.0

# Cosine similarity above which two segments are considered the same musical
# idea, and so the same part.
SECTION_REPEAT_SIMILARITY = 0.85

# What the all-in-one model can call a section, mapped to what a musician
# calls it. 'start' and 'end' bound the audio rather than naming parts of the
# song, and are dropped.
STRUCTURE_MARKER_LABELS = {"start", "end"}
STRUCTURE_LABEL_NAMES = {
    "intro": "Intro",
    "verse": "Verse",
    "chorus": "Chorus",
    "bridge": "Bridge",
    "inst": "Instrumental",
    "solo": "Solo",
    "break": "Break",
    "outro": "Outro",
}

# Shorter than this isn't a section, it's the model changing its mind
# mid-phrase. Folded into the part before it rather than dropped, so the form
# stays continuous.
MIN_FUNCTIONAL_SECTION_MS = 4000


def _median_gap_ms(values_ms: list[int]) -> float:
    if len(values_ms) < 2:
        return 0.0
    gaps = sorted(values_ms[i] - values_ms[i - 1] for i in range(1, len(values_ms)))
    return float(gaps[len(gaps) // 2])


def _snap_to_downbeats(time_ms: int, downbeats_ms: list[int], tolerance_ms: float) -> int:
    """Sections start where bars start.

    The structure model finds boundaries on its own beat grid; the app draws
    everything else, chords included, on the grid Beat This! produced. A
    section beginning 40ms before the bar it obviously begins on is the same
    off-by-a-frame problem chord snapping solves, and the same fix applies.
    """
    if not downbeats_ms or tolerance_ms <= 0:
        return time_ms
    nearest = min(downbeats_ms, key=lambda downbeat: abs(downbeat - time_ms))
    return nearest if abs(nearest - time_ms) <= tolerance_ms else time_ms


def _detect_structure(audio_path: str, work_dir: str, beat_info: dict) -> list[dict]:
    """Functional song structure — actual Intro/Verse/Chorus, not letters.

    Runs the All-In-One music structure analyzer (Kim & Nam, ISMIR 2023),
    whose segmentation head was trained on the Harmonix Set: around 900 pop
    songs with human structure annotations. That training is the entire point.
    Chroma self-similarity can tell that two stretches of a song are the same
    musical idea; nothing in the audio itself says which of them is the
    chorus. Only a model that has been shown what people *call* a chorus can
    name one, which is why every letter-based attempt at this reads as
    meaningless — it is meaningless, by construction.

    It is still a guess, and the app says so. The shape is usually right; the
    names are right in proportion to how much the song resembles the pop songs
    it was trained on.

    Returns [] on any failure, dropping the caller through to the chroma
    fallback.
    """
    try:
        import allin1_infer
        import torch
    except Exception:
        return []
    try:
        # WAV, not the original file. The authors warn that MP3 decoders
        # disagree with each other by 20-40ms, which is enough to shift every
        # boundary the model reports.
        wav_path = os.path.join(work_dir, "structure_input.wav")
        convert = subprocess.run(
            ["ffmpeg", "-y", "-i", audio_path, "-ac", "2", "-ar", "44100", wav_path],
            capture_output=True,
            text=True,
        )
        if convert.returncode != 0 or not os.path.exists(wav_path):
            return []

        result = allin1_infer.analyze(
            wav_path,
            device="cuda" if torch.cuda.is_available() else "cpu",
            demix_dir=os.path.join(work_dir, "allin1_demix"),
            spec_dir=os.path.join(work_dir, "allin1_spec"),
            # A worker that has already initialised CUDA is not a place to
            # fork more processes.
            multiprocess=False,
        )
        segments = getattr(result, "segments", None) or []
        if not segments:
            return []

        downbeats_ms = [int(v) for v in (beat_info.get("downbeats_ms") or [])]
        tolerance_ms = _median_gap_ms([int(v) for v in (beat_info.get("beats_ms") or [])])

        merged: list[list] = []
        for segment in segments:
            label = str(getattr(segment, "label", "")).strip().lower()
            if not label or label in STRUCTURE_MARKER_LABELS:
                continue
            start_ms = _snap_to_downbeats(
                round(float(segment.start) * 1000), downbeats_ms, tolerance_ms
            )
            end_ms = _snap_to_downbeats(
                round(float(segment.end) * 1000), downbeats_ms, tolerance_ms
            )
            if end_ms <= start_ms:
                continue
            name = STRUCTURE_LABEL_NAMES.get(label, label.replace("_", " ").title())
            # Two of the same name in a row is one section the model split,
            # and a sliver is the model changing its mind. Both fold into what
            # came before, which keeps the form continuous.
            if merged and (
                merged[-1][2] == name or end_ms - start_ms < MIN_FUNCTIONAL_SECTION_MS
            ):
                merged[-1][1] = end_ms
                continue
            merged.append([start_ms, end_ms, name])

        if len(merged) < 2:
            return []

        # Colour follows the name, so every chorus looks like every other
        # chorus at a glance.
        group_indices: dict[str, int] = {}
        sections: list[dict] = []
        for start_ms, end_ms, name in merged:
            if name not in group_indices:
                group_indices[name] = len(group_indices)
            sections.append(
                {
                    "start_ms": start_ms,
                    "end_ms": end_ms,
                    "label": name,
                    "group_index": group_indices[name],
                    "repeats_section_label": None,
                }
            )
        return sections
    except Exception as error:
        # Distinguished from "found no form", which is a legitimate answer for
        # a short or formless recording. A crash here used to be indis-
        # tinguishable from that: both produced an empty list, so a structure
        # model that had stopped working looked exactly like a song with no
        # structure. The caller surfaces this so the health check can see it.
        _structure_failure.append(f"{type(error).__name__}: {error}")
        return []


# Set by _detect_structure when the model raised rather than declined. Read
# once per job in handler(); a module-level list because the detector's
# contract is a list of sections and widening it would ripple through every
# caller for one diagnostic.
_structure_failure: list[str] = []


def _detect_structure_chroma(
    y: np.ndarray | None, sr: int | None, target_sections: int = 8
) -> list[dict]:
    """Fallback for when the structure model is unavailable or fails.

    Chroma self-similarity segmentation, reported as a song *form*: segments
    sharing a musical idea are grouped under one label, so the output reads as
    "A B A B C B" rather than a chain of "E repeats C repeats B" that has to
    be traced backwards to mean anything.

    Labels here stay abstract, and that isn't modesty — mean chroma cannot
    tell a verse from a chorus in the same key, which is exactly why this is
    the fallback now rather than the answer.
    """
    if y is None:
        return []
    try:
        duration_s = float(librosa.get_duration(y=y, sr=sr))
        if duration_s < 30:
            return []  # too short for a meaningful multi-section split

        chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
        frame_count = chroma.shape[1]
        if frame_count < 10:
            return []

        k = max(2, min(target_sections, frame_count // 200))
        boundary_frames = librosa.segment.agglomerative(chroma, k)
        boundary_times = sorted(float(t) for t in librosa.frames_to_time(boundary_frames, sr=sr))

        # Drop boundaries that would create a segment shorter than the
        # minimum, keeping the earlier one — a boundary too close to the last
        # accepted one is the artifact, not a new part.
        bounds = [0.0]
        for time in boundary_times:
            if time - bounds[-1] >= MIN_SECTION_SECONDS:
                bounds.append(time)
        # The final stretch merges into the previous part rather than standing
        # alone as a sliver at the end.
        if duration_s - bounds[-1] >= MIN_SECTION_SECONDS:
            bounds.append(duration_s)
        else:
            bounds[-1] = duration_s
        if len(bounds) < 3:
            return []  # fewer than 2 actual segments isn't a useful structure

        segments: list[tuple[float, float, np.ndarray]] = []
        for i in range(len(bounds) - 1):
            start_s, end_s = bounds[i], bounds[i + 1]
            start_frame = librosa.time_to_frames(start_s, sr=sr)
            end_frame = max(start_frame + 1, librosa.time_to_frames(end_s, sr=sr))
            segment_chroma = chroma[:, start_frame:end_frame]
            vector = segment_chroma.mean(axis=1) if segment_chroma.size else np.zeros(chroma.shape[0])
            norm = float(np.linalg.norm(vector))
            segments.append((start_s, end_s, vector / norm if norm > 0 else vector))

        # Group by similarity to each group's first occurrence, so every
        # instance of the same idea carries the same label rather than
        # pointing at whichever instance happened to precede it.
        group_vectors: list[np.ndarray] = []
        sections: list[dict] = []
        for start_s, end_s, vector in segments:
            group_index = None
            best_similarity = SECTION_REPEAT_SIMILARITY
            for index, reference in enumerate(group_vectors):
                similarity = float(np.dot(vector, reference))
                if similarity >= best_similarity:
                    best_similarity = similarity
                    group_index = index
            if group_index is None:
                group_vectors.append(vector)
                group_index = len(group_vectors) - 1

            label = chr(ord("A") + group_index) if group_index < 26 else str(group_index + 1)
            sections.append(
                {
                    "start_ms": round(start_s * 1000),
                    "end_ms": round(end_s * 1000),
                    "label": label,
                    "group_index": group_index,
                    # Retained so an older app build still renders something
                    # sensible; the label already carries the repeat.
                    "repeats_section_label": None,
                }
            )
        # Every segment landed in one group, so the answer is "the whole song
        # is Part A" — which is what a user saw and correctly called
        # meaningless. It happens because mean chroma over thirty seconds is
        # nearly identical everywhere in a song that stays in one key, so the
        # similarity test passes against everything. Saying nothing is more
        # honest than eight identical letters, and the UI already has a
        # "structure not detected" state for exactly this.
        if len(group_vectors) < 2:
            return []
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


# Loaded once and kept, rather than per job. A warm worker handles several
# jobs, and re-reading 809MB off disk for each one would be a cold start the
# image was built specifically to avoid. Lazy so importing this module — which
# the smoke test does — costs nothing.
_whisper_model = None


def _get_whisper():
    global _whisper_model
    if _whisper_model is None:
        from faster_whisper import WhisperModel

        import torch

        on_gpu = torch.cuda.is_available()
        _whisper_model = WhisperModel(
            "large-v3-turbo",
            device="cuda" if on_gpu else "cpu",
            # float16 on the GPU; int8 on CPU, where float16 is slower than
            # useless. Demucs has already exited by the time this runs, so the
            # two models never hold VRAM at the same time.
            compute_type="float16" if on_gpu else "int8",
        )
    return _whisper_model


def _transcribe(path: str, prompt: str | None = None) -> dict | None:
    """Words and their timings, or None if transcription failed outright.

    Runs with Silero VAD in front of it. That is the point of doing this here
    rather than through the API: Whisper invents fluent speech over passages
    that contain none, and an instrumental intro is exactly such a passage —
    one real recording came back with a run of Korean and Arabic numerals
    before the first line. VAD removes the silence before the decoder ever
    sees it, so there is nothing to hallucinate over.

    Best-effort like every other detector in this file. Lyrics failing must
    not take chords and structure down with them.
    """
    try:
        segments, _info = _get_whisper().transcribe(
            path,
            word_timestamps=True,
            vad_filter=True,
            # Whisper's default of temperature=0 does not mean deterministic —
            # it escalates temperature on its own when its confidence
            # thresholds fail, which is the mechanism behind the same file
            # transcribing correctly one hour and as repeated boilerplate the
            # next. A single fixed temperature refuses that escalation.
            temperature=0.0,
            condition_on_previous_text=False,
            initial_prompt=prompt,
        )
        words = []
        text_parts = []
        for segment in segments:
            text_parts.append(segment.text)
            for word in (segment.words or []):
                words.append(
                    {
                        "word": word.word,
                        "start_ms": int(round(word.start * 1000)),
                        "end_ms": int(round(word.end * 1000)),
                    }
                )
        return {"text": "".join(text_parts).strip(), "words": words}
    except Exception as error:  # noqa: BLE001 - see docstring
        return {"error": f"{type(error).__name__}: {error}"}


def handler(job):
    job_input = job.get("input", {})
    audio_url = job_input.get("audio_url")
    filename = job_input.get("filename", "input.mp3")
    stem_uploads = job_input.get("stem_uploads") or {}
    mix_upload = job_input.get("mix_upload")
    # The chords-and-lyrics pass skips section naming, which is the only part
    # of this job that runs a *second* source separation. That is roughly half
    # the GPU time, spent on the one result somebody in a hurry doesn't need.
    skip_structure = job_input.get("skip_structure") is True
    # Off unless asked for. Transcription here is meant to replace a per-minute
    # API call, but nothing has yet shown this model beats the one it would
    # replace on real songs — so it ships able to prove that before anything
    # depends on it.
    transcribe = job_input.get("transcribe") is True
    lyrics_hint = job_input.get("lyrics_hint")
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

        # Beat This! first; the librosa beat-tracker stays as a fallback for
        # when it can't find a pulse at all, since a tempo with no downbeats
        # is still better than nothing.
        beat_info = _detect_beats(in_path)
        bpm = beat_info["bpm"] or _detect_bpm(
            waveforms["drums"], sample_rates["drums"], y_mix, sr_mix
        )
        instruments = {stem: _stem_presence(waveforms[stem]) for stem in STEM_NAMES}
        # Named sections first; letters only if the model couldn't run. Placed
        # after the demucs subprocess has exited so its VRAM is already back.
        _structure_failure.clear()
        structure = (
            []
            if skip_structure
            else _detect_structure(in_path, tmp, beat_info)
            or _detect_structure_chroma(y_mix, sr_mix)
        )

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
        #
        # All six at once. Done one after another this was close to a minute
        # of the job spent waiting — each stem is an ffmpeg process and then
        # an HTTP PUT, and no stem needs anything from any other. Threads
        # rather than processes because every step here blocks either in a
        # subprocess or on the network, so the GIL is never the thing being
        # waited on.
        def encode_and_upload(entry: tuple[str, object]) -> str | None:
            stem, signed_url = entry
            source = stem_paths.get(stem)
            if not source or not os.path.exists(source) or not isinstance(signed_url, str):
                return None
            encoded = os.path.join(tmp, f"{stem}.mp3")
            if not _encode_mp3(source, encoded):
                return None
            return stem if _upload_stem(signed_url, encoded) else None

        uploaded_stems: list[str] = []
        if stem_uploads:
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(stem_uploads)) as pool:
                uploaded_stems = [
                    stem
                    for stem in pool.map(encode_and_upload, list(stem_uploads.items()))
                    if stem is not None
                ]

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

        # After separation, not before: demucs runs as a subprocess and has
        # exited by now, so its VRAM is back and the two models never contend.
        # The vocal stem rather than the original mix, which keeps this change
        # to one variable — whether a better model helps — instead of also
        # changing what it listens to, a question ground truth has so far
        # answered both ways.
        transcript = None
        if transcribe:
            vocal_path = stem_paths.get("vocals")
            if vocal_path and os.path.exists(vocal_path):
                transcript = _transcribe(vocal_path, prompt=lyrics_hint)

        result = {
            "harmonic_mix_uploaded": mix_uploaded,
            "transcript": transcript,
            "bpm": bpm,
            "key": musical_key,
            "beats_ms": beat_info["beats_ms"],
            "downbeats_ms": beat_info["downbeats_ms"],
            "beats_per_bar": beat_info["beats_per_bar"],
            "instruments": instruments,
            "structure": structure,
            # Present only when the structure model raised, as opposed to
            # declining to find a form. Those two used to look identical.
            "structure_error": _structure_failure[0] if _structure_failure else None,
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
