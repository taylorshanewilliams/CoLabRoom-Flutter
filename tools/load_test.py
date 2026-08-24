"""Fires several analyses at the live pipeline at once and reports what happens.

Everything so far has been one person analysing one song. Twenty at once is a
different system: RunPod cold-starts stack, Cloud Run's chord service has its
own concurrency ceiling, and a four-minute job can become twelve. Nobody knows
where this breaks, because nobody has asked it.

Deliberately manual. It spends real GPU money every run, so it is not on a
schedule and not in CI — you run it when you want the answer, with a number
you chose.

The measurement that matters is not the average. It is the *last* job to
finish, because that is the person having the worst experience, and the spread
between first and last, because that is what tells you whether the queue is
serving people or holding them.

Environment: the same secrets as the health check.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

CLIP_SECONDS = 40
BUCKET = "room-files"
JOB_TIMEOUT_SECONDS = 1200
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


def make_clip(path: str, seed: int) -> None:
    """A different clip per job, on purpose.

    Identical audio would hit the analysis cache and every job after the first
    would return instantly — measuring the cache rather than the pipeline. The
    frequency shifts per job so each one is genuinely new work.
    """
    base = 180 + seed * 17
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", f"sine=frequency={base}:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency={base * 3 // 2}:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"anoisesrc=duration={CLIP_SECONDS}:color=white:amplitude=0.25",
            "-filter_complex", "amix=inputs=3:duration=longest,volume=2",
            "-ar", "44100", "-ac", "2",
            path,
        ],
        check=True,
        capture_output=True,
    )


def main() -> int:
    concurrency = int(os.environ.get("LOAD_TEST_JOBS", "5"))
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    runpod_key = env("RUNPOD_API_KEY")
    endpoint_id = env("RUNPOD_ENDPOINT_ID")

    supabase_url = f"https://{project_ref}.supabase.co"
    storage_headers = {"Authorization": f"Bearer {service_key}", "apikey": service_key}

    print(f"Submitting {concurrency} analyses at once.\n")

    with tempfile.TemporaryDirectory() as tmp:
        jobs: list[dict] = []
        for index in range(concurrency):
            clip = os.path.join(tmp, f"load-{index}.wav")
            make_clip(clip, index)
            with open(clip, "rb") as f:
                clip_bytes = f.read()
            path = f"_health/load-{index}.wav"
            request(
                f"{supabase_url}/storage/v1/object/{BUCKET}/{path}",
                method="POST",
                headers={**storage_headers, "Content-Type": "audio/wav", "x-upsert": "true"},
                data=clip_bytes,
            )
            signed = json.loads(
                request(
                    f"{supabase_url}/storage/v1/object/sign/{BUCKET}/{path}",
                    method="POST",
                    headers={**storage_headers, "Content-Type": "application/json"},
                    data=json.dumps({"expiresIn": 7200}).encode(),
                )
            )
            jobs.append({"index": index, "path": path, "url": f"{supabase_url}/storage/v1{signed['signedURL']}"})

        # Submitted as fast as they can go, which is the point — a staggered
        # submission measures a queue that was never actually contended.
        started = time.monotonic()
        for job in jobs:
            run = json.loads(
                request(
                    f"https://api.runpod.ai/v2/{endpoint_id}/run",
                    method="POST",
                    headers={
                        "Authorization": f"Bearer {runpod_key}",
                        "Content-Type": "application/json",
                    },
                    data=json.dumps(
                        {"input": {"audio_url": job["url"], "filename": f"load-{job['index']}.wav"}}
                    ).encode(),
                )
            )
            job["id"] = run.get("id")
            job["done_at"] = None
            job["state"] = "SUBMITTED"

        pending = [job for job in jobs if job["id"]]
        if len(pending) != len(jobs):
            print(f"WARNING: {len(jobs) - len(pending)} job(s) were refused outright.")

        while pending and time.monotonic() - started < JOB_TIMEOUT_SECONDS:
            time.sleep(POLL_SECONDS)
            still_waiting = []
            for job in pending:
                status = json.loads(
                    request(
                        f"https://api.runpod.ai/v2/{endpoint_id}/status/{job['id']}",
                        headers={"Authorization": f"Bearer {runpod_key}"},
                    )
                )
                job["state"] = status.get("status")
                if job["state"] in ("COMPLETED", "FAILED"):
                    job["done_at"] = time.monotonic() - started
                    job["gpu_ms"] = status.get("executionTime")
                    job["delay_ms"] = status.get("delayTime")
                    mark = "ok" if job["state"] == "COMPLETED" else "FAILED"
                    print(f"  job {job['index']}: {mark} after {round(job['done_at'])}s")
                else:
                    still_waiting.append(job)
            pending = still_waiting
            if pending:
                print(f"  … {len(pending)} still going at {round(time.monotonic() - started)}s")

        for job in jobs:
            try:
                request(
                    f"{supabase_url}/storage/v1/object/{BUCKET}/{job['path']}",
                    method="DELETE",
                    headers=storage_headers,
                )
            except Exception:
                pass

    finished = [job for job in jobs if job.get("done_at") is not None]
    failed = [job for job in finished if job["state"] == "FAILED"]
    stuck = [job for job in jobs if job.get("done_at") is None]

    print()
    print(f"Submitted:   {len(jobs)}")
    print(f"Completed:   {len(finished) - len(failed)}")
    print(f"Failed:      {len(failed)}")
    print(f"Never done:  {len(stuck)}")
    if finished:
        times = sorted(job["done_at"] for job in finished)
        # First and last, not the mean. The last one is the person having the
        # worst experience, and the gap is what says whether the queue is
        # serving people or holding them.
        print(f"First done:  {round(times[0])}s")
        print(f"Last done:   {round(times[-1])}s")
        print(f"Spread:      {round(times[-1] - times[0])}s")
        gpu = [job["gpu_ms"] for job in finished if job.get("gpu_ms")]
        queue = [job["delay_ms"] for job in finished if job.get("delay_ms")]
        if gpu:
            print(f"GPU time:    {round(sum(gpu) / len(gpu) / 1000, 1)}s average")
        if queue:
            # The number that separates "we need more workers" from "the work
            # itself is slow" — they call for completely different fixes.
            print(f"Queued for:  {round(sum(queue) / len(queue) / 1000, 1)}s average")

    return 1 if failed or stuck else 0


if __name__ == "__main__":
    sys.exit(main())
