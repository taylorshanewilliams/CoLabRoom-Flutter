"""RunPod Serverless handler wrapping Demucs (htdemucs) source separation.

Input:  {"input": {"audio_url": "<signed URL>", "filename": "song.mp3"}}
Output: {"harmonic_mix_b64": "<base64 mp3>"} or {"error": "..."} on failure.

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
"""

import base64
import os
import subprocess
import tempfile

import requests
import runpod


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
        bass_path = os.path.join(base, "bass.wav")
        other_path = os.path.join(base, "other.wav")
        if not os.path.exists(bass_path) or not os.path.exists(other_path):
            return {"error": f"Expected stems not found under {base}"}

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

        return {"harmonic_mix_b64": harmonic_mix_b64}


runpod.serverless.start({"handler": handler})
