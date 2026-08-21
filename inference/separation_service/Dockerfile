# A standard, well-documented CUDA+PyTorch base rather than guessing at
# RunPod's own base-image tag scheme — RunPod serverless runs any Docker
# image, it doesn't require one of theirs.
FROM pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir demucs runpod requests librosa

COPY handler.py /app/handler.py

CMD ["python3", "-u", "handler.py"]
