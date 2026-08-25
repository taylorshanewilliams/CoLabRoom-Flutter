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
                    }
                }
            )
        finally:
            server.shutdown()

    if "error" in result:
        print(f"FAIL: handler returned an error: {result['error']}")
        return 1

    failures: list[str] = []

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
        print(f"  transcript: {len(words or [])} words, {len(transcript.get('text') or '')} chars")

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
