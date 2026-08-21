"""RunPod Serverless handler wrapping Demucs (htdemucs) source separation.

Input:  {"input": {"audio_b64": "<base64 mp3/wav>", "filename": "song.mp3"}}
Output: {"stems": {"vocals": "<base64 wav>", "drums": ..., "bass": ..., "other": ...}}
        or {"error": "..."} on failure.

Kept as raw stems rather than pre-mixing bass+other here — the "which
stems feed the chord model" choice belongs to the caller (currently
bass+other, see the Phase 0.5 validation notes), and returning all four
keeps that decision changeable without redeploying this service.
"""

import base64
import os
import subprocess
import tempfile

import runpod


def handler(job):
    job_input = job.get("input", {})
    audio_b64 = job_input.get("audio_b64")
    filename = job_input.get("filename", "input.mp3")
    if not audio_b64:
        return {"error": "Missing 'audio_b64' in input."}

    with tempfile.TemporaryDirectory() as tmp:
        in_path = os.path.join(tmp, filename)
        with open(in_path, "wb") as f:
            f.write(base64.b64decode(audio_b64))

        out_dir = os.path.join(tmp, "separated")
        result = subprocess.run(
            ["python", "-m", "demucs", "-n", "htdemucs", "-o", out_dir, in_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return {"error": result.stderr[-2000:]}

        name = os.path.splitext(os.path.basename(filename))[0]
        base = os.path.join(out_dir, "htdemucs", name)
        stems = {}
        for stem in ("vocals", "drums", "bass", "other"):
            stem_path = os.path.join(base, f"{stem}.wav")
            if not os.path.exists(stem_path):
                return {"error": f"Expected stem not found: {stem_path}"}
            with open(stem_path, "rb") as f:
                stems[stem] = base64.b64encode(f.read()).decode("ascii")

        return {"stems": stems}


runpod.serverless.start({"handler": handler})
