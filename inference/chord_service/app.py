"""HTTP wrapper around ChordMini's ChordNet inference, for Cloud Run.

POST /analyze with an audio file (multipart/form-data, field name "file")
returns {"chords": [{"start": float, "end": float, "chord": str}, ...]}.

This deliberately shells out to ChordMini's own src/evaluation/test.py
rather than re-implementing its inference loop — that script is the
project's own maintained entry point (handles model loading, the
overlap/gaussian/smoothing options this pipeline already validated in
Phase 0), so wrapping it is less to keep in sync than reimplementing it.
"""

import os
import subprocess
import tempfile

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse

app = FastAPI()

CHORDMINI_DIR = "/app/ChordMini"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
    with tempfile.TemporaryDirectory() as tmp:
        audio_path = os.path.join(tmp, file.filename or "input.mp3")
        with open(audio_path, "wb") as f:
            f.write(await file.read())

        save_dir = os.path.join(tmp, "out")
        os.makedirs(save_dir, exist_ok=True)

        result = subprocess.run(
            [
                "python",
                "src/evaluation/test.py",
                "--model_type",
                "ChordNet",
                "--checkpoint",
                "checkpoints/2e1d_model_best.pth",
                "--config",
                "config/ChordMini.yaml",
                "--audio_dir",
                audio_path,
                "--save_dir",
                save_dir,
                "--use_overlap",
                "--use_gaussian",
                "--kernel_size",
                "9",
                "--vote_aggregation",
                "logit",
                "--min_segment_duration",
                "0.5",
                "--smooth_predictions",
            ],
            cwd=CHORDMINI_DIR,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=result.stderr[-2000:])

        lab_name = os.path.splitext(os.path.basename(audio_path))[0] + ".lab"
        lab_path = os.path.join(save_dir, lab_name)
        if not os.path.exists(lab_path):
            raise HTTPException(
                status_code=500,
                detail=f"Expected output not found at {lab_path}. stdout: {result.stdout[-1000:]}",
            )

        chords = []
        with open(lab_path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3:
                    chords.append(
                        {"start": float(parts[0]), "end": float(parts[1]), "chord": parts[2]}
                    )

        return JSONResponse({"chords": chords})
