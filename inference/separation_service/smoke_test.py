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
                {"input": {"audio_url": f"http://127.0.0.1:{PORT}/smoke.wav", "filename": "smoke.wav"}}
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
    key = result.get("key")
    if key is not None and not isinstance(key, str):
        failures.append(f"key should be a string or None, got {type(key).__name__}")
    bpm = result.get("bpm")
    if bpm is not None and not isinstance(bpm, (int, float)):
        failures.append(f"bpm should be numeric or None, got {type(bpm).__name__}")
    if not isinstance(result.get("structure"), list):
        failures.append("structure should be a list")
    if not isinstance(result.get("uploaded_stems"), list):
        failures.append("uploaded_stems should be a list")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("Smoke test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
