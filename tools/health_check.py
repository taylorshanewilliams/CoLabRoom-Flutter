"""Runs one real song through the live pipeline and checks the answer.

The gap this closes: when RunPod is down or a deployed image is broken, every
analysis quietly falls back to the on-device chord detector and still reports
success. Worse chords, no stems, no structure, no error — and the first person
to notice is a customer, days later. The image build's smoke test cannot catch
this, because it runs before publishing and on CPU; this runs against the
endpoint real users hit, on the GPU they hit it with.

Deliberately not routed through the Edge Function. That path needs a signed-in
user, and the failures worth catching here are in the two services behind it —
which is also where both production outages so far have been. The function
itself is type-checked by CI and its errors already surface in telemetry.

Costs one GPU job per run. That is the point: a health check that hits the
cache instead of the hardware tests the cache.

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  RUNPOD_API_KEY              (already a repo secret)
  RUNPOD_ENDPOINT_ID          (already a repo secret)
  CHORD_SERVICE_URL           the Cloud Run base URL
  CHORD_SERVICE_API_KEY       (already a repo secret)
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Long enough for the structure model to have something to segment — it
# declines to find a form in anything shorter — and short enough that a daily
# check costs pennies.
CLIP_SECONDS = 40
STORAGE_PATH = "_health/health-check.wav"
BUCKET = "room-files"

# A cold worker pulling a multi-gigabyte image is a normal slow case, not a
# failure. Past this it is a real one.
JOB_TIMEOUT_SECONDS = 900
POLL_SECONDS = 10


def env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        print(f"FAIL: {name} is not set.")
        sys.exit(1)
    return value


def request(url: str, *, method: str = "GET", headers: dict | None = None, data: bytes | None = None):
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=180) as response:
        return response.read()


def make_clip(path: str) -> None:
    """A chord, a beat, and a change partway through.

    Not musical, but it gives every detector something real to do: three tones
    for the chord model, a click for the beat tracker, and a shift at the
    halfway point so the structure model has a boundary to find.
    """
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", f"sine=frequency=220:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency=330:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"anoisesrc=duration={CLIP_SECONDS}:color=white:amplitude=0.25",
            "-filter_complex", "amix=inputs=4:duration=longest,volume=2",
            "-ar", "44100", "-ac", "2",
            path,
        ],
        check=True,
        capture_output=True,
    )


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    runpod_key = env("RUNPOD_API_KEY")
    endpoint_id = env("RUNPOD_ENDPOINT_ID")
    chord_url = env("CHORD_SERVICE_URL").rstrip("/")
    chord_key = env("CHORD_SERVICE_API_KEY")

    supabase_url = f"https://{project_ref}.supabase.co"
    storage_headers = {
        "Authorization": f"Bearer {service_key}",
        "apikey": service_key,
    }
    failures: list[str] = []
    timings: dict[str, float] = {}

    with tempfile.TemporaryDirectory() as tmp:
        clip = os.path.join(tmp, "health-check.wav")
        print(f"Generating a {CLIP_SECONDS}s clip…")
        make_clip(clip)
        with open(clip, "rb") as f:
            clip_bytes = f.read()

        print("Uploading it…")
        try:
            request(
                f"{supabase_url}/storage/v1/object/{BUCKET}/{STORAGE_PATH}",
                method="POST",
                headers={**storage_headers, "Content-Type": "audio/wav", "x-upsert": "true"},
                data=clip_bytes,
            )
        except urllib.error.HTTPError as error:
            print(f"FAIL: could not upload the clip: HTTP {error.code} {error.read()[:400]}")
            return 1

        signed = json.loads(
            request(
                f"{supabase_url}/storage/v1/object/sign/{BUCKET}/{STORAGE_PATH}",
                method="POST",
                headers={**storage_headers, "Content-Type": "application/json"},
                data=json.dumps({"expiresIn": 3600}).encode(),
            )
        )
        audio_url = f"{supabase_url}/storage/v1{signed['signedURL']}"

        print("Submitting a separation job to the live endpoint…")
        started = time.monotonic()
        try:
            run = json.loads(
                request(
                    f"https://api.runpod.ai/v2/{endpoint_id}/run",
                    method="POST",
                    headers={
                        "Authorization": f"Bearer {runpod_key}",
                        "Content-Type": "application/json",
                    },
                    # No mix_upload, so the worker inlines the mix. For forty
                    # seconds of audio that is small, and it keeps this check
                    # to the models rather than the upload plumbing that every
                    # real analysis already exercises.
                    data=json.dumps(
                        {"input": {"audio_url": audio_url, "filename": "health-check.wav"}}
                    ).encode(),
                )
            )
        except urllib.error.HTTPError as error:
            print(f"FAIL: RunPod refused the job: HTTP {error.code} {error.read()[:400]}")
            return 1

        job_id = run.get("id")
        if not job_id:
            print(f"FAIL: RunPod accepted the request but returned no job id: {run}")
            return 1

        output = None
        while time.monotonic() - started < JOB_TIMEOUT_SECONDS:
            time.sleep(POLL_SECONDS)
            status = json.loads(
                request(
                    f"https://api.runpod.ai/v2/{endpoint_id}/status/{job_id}",
                    headers={"Authorization": f"Bearer {runpod_key}"},
                )
            )
            state = status.get("status")
            if state == "FAILED":
                print(f"FAIL: the separation job failed: {str(status.get('error'))[:600]}")
                return 1
            if state == "COMPLETED":
                output = status.get("output") or {}
                timings["gpu_seconds"] = (status.get("executionTime") or 0) / 1000.0
                break
            print(f"  {state}… {round(time.monotonic() - started)}s")

        timings["total_seconds"] = time.monotonic() - started
        if output is None:
            print(f"FAIL: the job did not finish within {JOB_TIMEOUT_SECONDS}s.")
            # A job stuck IN_QUEUE never got a worker, which is a completely
            # different problem from a job that ran and produced nothing — and
            # the endpoint's own health says which. Worth printing here rather
            # than making somebody go and ask RunPod by hand.
            try:
                health = json.loads(
                    request(
                        f"https://api.runpod.ai/v2/{endpoint_id}/health",
                        headers={"Authorization": f"Bearer {runpod_key}"},
                    )
                )
                print(f"  endpoint health: {json.dumps(health)}")
            except Exception as error:
                print(f"  (could not read endpoint health: {error})")
            return 1

        if output.get("error"):
            print(f"FAIL: the worker returned an error: {str(output['error'])[:600]}")
            return 1

        # Each of these is a model that has broken in production before, and
        # each fails silently — the analysis still "succeeds" without it.
        mix_b64 = output.get("harmonic_mix_b64")
        if not mix_b64:
            failures.append("no harmonic mix came back")
        beats = output.get("beats_ms")
        if not isinstance(beats, list) or len(beats) < 4:
            failures.append(f"beat tracking returned {beats if beats is None else len(beats)} beats")
        if output.get("bpm") is None:
            failures.append("no BPM")
        if output.get("key") is None:
            failures.append("no key")
        instruments = output.get("instruments") or {}
        if not instruments:
            failures.append("no instrument presence")
        # The structure model is the one component whose dependencies fight
        # the pinned torch, and a crash inside it used to be indistinguishable
        # from a song that simply has no form. This is that distinction.
        if output.get("structure_error"):
            failures.append(f"the structure model raised: {output['structure_error']}")
        print(f"  structure: {len(output.get('structure') or [])} sections")

        if mix_b64:
            print("Sending the mix to the chord service…")
            mix = base64.b64decode(mix_b64)
            boundary = "----colabroomhealthcheck"
            body = (
                f"--{boundary}\r\n"
                'Content-Disposition: form-data; name="file"; filename="harmonic_mix.mp3"\r\n'
                "Content-Type: audio/mpeg\r\n\r\n"
            ).encode() + mix + f"\r\n--{boundary}--\r\n".encode()
            chords_started = time.monotonic()
            try:
                chords = json.loads(
                    request(
                        f"{chord_url}/analyze",
                        method="POST",
                        headers={
                            "X-API-Key": chord_key,
                            "Content-Type": f"multipart/form-data; boundary={boundary}",
                        },
                        data=body,
                    )
                ).get("chords", [])
                timings["chord_seconds"] = time.monotonic() - chords_started
                if not chords:
                    failures.append("the chord service named no chords at all")
                else:
                    print(f"  chords: {len(chords)}")
            except urllib.error.HTTPError as error:
                failures.append(f"chord service HTTP {error.code}: {error.read()[:300]}")

        try:
            request(
                f"{supabase_url}/storage/v1/object/{BUCKET}/{STORAGE_PATH}",
                method="DELETE",
                headers=storage_headers,
            )
        except Exception:
            pass

    print()
    print("Timings:")
    for name, value in timings.items():
        print(f"  {name}: {round(value, 1)}")

    if failures:
        print()
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print()
    print("Pipeline healthy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
