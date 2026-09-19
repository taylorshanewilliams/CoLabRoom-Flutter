"""Runs one short synthetic clip all the way through the separation handler.

Exists because two production failures in a row came from code that compiled,
type-checked, and deployed perfectly, then failed the first time real audio
touched it — an ffmpeg filter option the container's ffmpeg didn't have, and a
payload too large for the caller's memory. Neither is findable by static
analysis. Both are findable by running the thing once.

Runs inside the built image, on CPU, before the image is published. Fifteen
seconds of synthesized audio is enough: every step that broke was structural
(does this filter graph parse, does this file appear, is this key set), not
dependent on real music.
"""

from __future__ import annotations

import base64
import functools
import http.server
import os
import subprocess
import sys
import tempfile
import threading

import handler as separation

CLIP_SECONDS = 15
PORT = 8009
# The language this run says the clip is sung in. Any real code would do —
# what is being proved is that the handler takes one, hands it to the model,
# and reports back what the words were heard in, which is what the analysis
# cache files them under.
SUNG_IN = "en"


def make_clip(path: str) -> None:
    """A chord plus a beat — enough for every detector to have something to
    chew on, so key/bpm/structure exercise their real code paths instead of
    bailing out early on silence.
    """
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", f"sine=frequency=220:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency=277:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency=330:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"anoisesrc=duration={CLIP_SECONDS}:color=white:amplitude=0.3",
            "-filter_complex", "amix=inputs=4:duration=longest",
            "-ar", "44100", "-ac", "2",
            path,
        ],
        check=True,
        capture_output=True,
    )


def make_voice(path: str) -> None:
    """Something the pitch tracker cannot mistake for silence: four seconds
    of A3, alone, at the rate the tracker listens at.

    The mixed clip above may or may not leave anything in the vocal stem
    once demucs has been at it, so the handler's melody stage can pass the
    smoke test by never running. This clip goes to the stage directly. A
    pure tone rather than anything voice-like on purpose: the question here
    is whether pyin and the grouping run at all in this image, and the
    answer to a pure tone is known exactly.
    """
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", "sine=frequency=220:duration=4",
            "-ar", "16000", "-ac", "1",
            path,
        ],
        check=True,
        capture_output=True,
    )


def check_melody_stage(tmp: str) -> list[str]:
    """Runs `_extract_melody` on a clip with a voice in it and checks the
    answer, so an image whose pyin or note grouping is broken fails here on
    CPU, before it is published, rather than on the first real song.

    What a correct answer looks like is narrow enough to assert: one note or
    a few, all of them A3 (MIDI 57), and a range that says so.
    """
    voice = os.path.join(tmp, "voice.wav")
    make_voice(voice)
    melody = separation._extract_melody(voice)  # noqa: SLF001 - the stage under test
    if melody is None:
        return ["the pitch tracker heard nothing in a clip that is one sustained note"]
    if "error" in melody:
        return [f"the pitch tracker raised: {melody['error']}"]
    notes = melody.get("notes") or []
    low, high = melody.get("low_midi"), melody.get("high_midi")
    print(f"  pitch tracker: {len(notes)} notes, range {low}–{high}")
    failures: list[str] = []
    if not notes:
        failures.append("the pitch tracker grouped a sustained note into no notes")
    if low is None or high is None or not (55 <= low <= 59 and 55 <= high <= 59):
        failures.append(f"a sustained A3 came back as MIDI {low}–{high}, not 57")
    return failures


def check_language_mapping() -> list[str]:
    """Checks the cut from a BCP-47 tag to the code the model takes.

    The room declares a tag — 'pt-BR', 'zh-Hans' — and faster-whisper takes a
    bare code. Getting that cut wrong is not a crash: the language is quietly
    dropped and the song is transcribed by guesswork, which is the exact
    failure this whole parameter exists to remove, and nothing downstream can
    tell. So it is checked here, in the image, where the model's own list of
    languages is importable.
    """
    failures: list[str] = []
    cases = {
        "pt-BR": "pt",  # a region is not part of the answer
        "  AR  ": "ar",  # typed by hand, with a shift key and a thumb
        "zh-Hans": "zh",  # nor is a script
        "Arabic": None,  # the word is what a person reads, not a code
        "": None,
        None: None,  # nobody has said, which is most songs
        12: None,
    }
    for raw, expected in cases.items():
        got = separation._whisper_language(raw)  # noqa: SLF001 - the cut under test
        if got != expected:
            failures.append(f"language {raw!r} became {got!r}, expected {expected!r}")
    known = separation._known_languages()  # noqa: SLF001 - see above
    if known is None:
        print("  languages: faster-whisper would not name its own list (the retry covers it)")
    elif "en" not in known:
        failures.append("faster-whisper's language list does not contain 'en', which cannot be right")
    else:
        print(f"  languages: {len(known)} known to this build")
    return failures


def serve(directory: str) -> http.server.ThreadingHTTPServer:
    """The handler takes a URL, not a path — serve the clip so the test
    exercises the real download path rather than a special-cased local one.
    """
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", PORT),
        functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory),
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        clip = os.path.join(tmp, "smoke.wav")
        print(f"Generating a {CLIP_SECONDS}s clip…")
        make_clip(clip)

        server = serve(tmp)
        try:
            print("Running the separation handler (CPU)…")
            result = separation.handler(
                {
                    "input": {
                        "audio_url": f"http://127.0.0.1:{PORT}/smoke.wav",
                        "filename": "smoke.wav",
                        # On, so a broken faster-whisper cannot reach RunPod.
                        # It defaults off in production, which would otherwise
                        # mean the one path this test exists to protect is the
                        # one path it never runs.
                        "transcribe": True,
                        # And told a language, because that is the whole point
                        # of the parameter: a build whose faster-whisper will
                        # not take one, or takes it and will not say what it
                        # heard in, must fail here rather than on the first
                        # song whose room said what it is sung in.
                        "language": SUNG_IN,
                    }
                }
            )
        finally:
            server.shutdown()

        # And once with nothing declared at all, because that is still the
        # path nearly every song takes: a room that has never said what its
        # song is sung in, and every Studio idea. The handler run above now
        # always declares one, so without this the image would stop proving
        # that auto-detect works — and faster-whisper is unpinned, so it is
        # the path most likely to move under a rebuild (review, 19 September
        # 2026). Cheap: the weights are already loaded and the VAD filter
        # finds no speech in sine waves.
        detected = None
        if "error" not in result:
            print("Listening once more with no language declared…")
            detected = separation._transcribe(clip)

    if "error" in result:
        print(f"FAIL: handler returned an error: {result['error']}")
        return 1

    failures: list[str] = []

    if detected is None:
        failures.append("transcription with no language declared returned nothing")
    elif detected.get("error"):
        failures.append(
            f"transcription with no language declared raised: {detected['error']}"
        )
    else:
        # Printed, not asserted: what the model makes of fifteen seconds of
        # sine waves is its business, and on a clip the VAD empties it may
        # honestly name nothing. The failure this catches is the call itself
        # breaking.
        print(f"  with no language declared: heard {detected.get('language')!r}")

    print("Running the pitch tracker on a voice by itself…")
    with tempfile.TemporaryDirectory() as tmp:
        failures.extend(check_melody_stage(tmp))

    print("Checking what a declared language becomes…")
    failures.extend(check_language_mapping())

    # No mix_upload was supplied, so the handler must fall back to inlining
    # the mix. This is the step the ffmpeg filter change broke.
    mix_b64 = result.get("harmonic_mix_b64")
    if not mix_b64:
        failures.append("no harmonic_mix_b64 returned")
    else:
        size = len(base64.b64decode(mix_b64))
        print(f"  harmonic mix: {size} bytes")
        if size < 1000:
            failures.append(f"harmonic mix implausibly small ({size} bytes)")

    instruments = result.get("instruments") or {}
    missing = [s for s in separation.STEM_NAMES if s not in instruments]
    if missing:
        failures.append(f"instruments missing entries for {missing}")
    else:
        print(f"  instruments: {sorted(instruments)}")
        melody = result.get("melody")
        if isinstance(melody, dict) and "error" in melody:
            print(f"FAIL: melody raised: {melody['error']}")
            sys.exit(1)
        print(f"  melody: {'none' if melody is None else str(len(melody.get('notes', []))) + ' notes'}")

    # The build the image says it is. The Dockerfile sets it from the commit
    # that built the image, and in CI this test runs inside that image, so a
    # missing or different value means the label the health check relies on
    # never reached the container.
    build = result.get("worker_build")
    expected_build = os.environ.get("WORKER_BUILD") or None
    if build != expected_build:
        failures.append(f"the worker says it is build {build!r}; the image was built as {expected_build!r}")
    else:
        print(f"  worker build: {build or 'unset (not built by the publish workflow)'}")

    # Detectors are best-effort by design and legitimately return None on odd
    # input, so absence isn't a failure — but a wrong *shape* is, and that is
    # what would break the app's parsing.
    beats = result.get("beats_ms")
    downbeats = result.get("downbeats_ms")
    print(
        f"  key: {result.get('key')!r}   bpm: {result.get('bpm')!r}   "
        f"beats: {len(beats) if isinstance(beats, list) else 'n/a'}   "
        f"downbeats: {len(downbeats) if isinstance(downbeats, list) else 'n/a'}   "
        f"beats/bar: {result.get('beats_per_bar')!r}"
    )
    # Shape only, not musicality — the clip is synthesised, so how *well* the
    # tracker did on it means nothing. What this catches is the beat tracker
    # failing to import, load its checkpoint, or return the agreed shape,
    # which is exactly how a dependency change breaks production silently.
    if not isinstance(beats, list):
        failures.append('beats_ms should be a list')
    if not isinstance(downbeats, list):
        failures.append('downbeats_ms should be a list')
    if any(not isinstance(t, int) for t in (beats or [])):
        failures.append('beats_ms should contain integer milliseconds')
    # Same standard as the beat tracker above: shape, not musicality. The clip
    # is four sine waves and noise, so an empty transcript is the *correct*
    # answer — VAD should find no speech in it. What this catches is
    # faster-whisper failing to import, failing to find its baked-in weights,
    # or returning something the Edge Function could not parse.
    transcript = result.get("transcript")
    if transcript is None:
        failures.append('transcript missing entirely (transcribe was requested)')
    elif transcript.get("error"):
        failures.append(f"transcription raised: {transcript['error']}")
    else:
        words = transcript.get("words")
        if not isinstance(transcript.get("text"), str):
            failures.append('transcript.text should be a string')
        if not isinstance(words, list):
            failures.append('transcript.words should be a list')
        else:
            for word in words:
                if not isinstance(word.get("start_ms"), int) or not isinstance(word.get("end_ms"), int):
                    failures.append('transcript words need integer millisecond timings')
                    break
        # Told a language above, so this must come back as that language and
        # not as whatever the model would have guessed from four sine waves.
        # It is what analyze-chords files the transcript under: a worker that
        # quietly ignores the language, or names none, makes every song whose
        # room has answered un-cacheable and pays for the GPU again on every
        # open, with nothing on the outside to show for it.
        heard_in = transcript.get("language")
        if heard_in != SUNG_IN:
            failures.append(
                f"asked for a transcript in {SUNG_IN!r} and the worker says it heard {heard_in!r}"
            )
        print(
            f"  transcript: {len(words or [])} words, "
            f"{len(transcript.get('text') or '')} chars, heard in {heard_in!r}"
        )

    key = result.get("key")
    if key is not None and not isinstance(key, str):
        failures.append(f"key should be a string or None, got {type(key).__name__}")
    bpm = result.get("bpm")
    if bpm is not None and not isinstance(bpm, (int, float)):
        failures.append(f"bpm should be numeric or None, got {type(bpm).__name__}")
    structure = result.get("structure")
    if not isinstance(structure, list):
        failures.append("structure should be a list")
    else:
        for section in structure:
            if not {"start_ms", "end_ms", "label", "group_index"} <= set(section):
                failures.append(f"structure entry missing keys: {sorted(section)}")
                break
    if not isinstance(result.get("uploaded_stems"), list):
        failures.append("uploaded_stems should be a list")

    # The structure model gets checked apart from the handler run above,
    # because fifteen seconds of synthesised noise is shorter than any real
    # section and the model correctly declines to find a form in it — so that
    # run exercises the fallback, not the model.
    #
    # What can actually break is the model failing to import or load inside
    # this process. A dependency resolution that works at build time and not
    # at import time is exactly how the MKL/libgomp conflict took demucs down
    # once already, so loading the checkpoint here — in the same interpreter
    # that has already imported librosa, torch and demucs — is the check
    # worth having.
    print("Loading the structure model in-process…")
    try:
        from allin1_infer.models.loaders import load_pretrained_model

        load_pretrained_model("harmonix-all", device="cpu")
        print("  structure model: harmonix-all loaded")
    except Exception as error:  # noqa: BLE001 - reporting the failure is the point
        failures.append(f"structure model unavailable: {type(error).__name__}: {error}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("Smoke test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
