# A standard, well-documented CUDA+PyTorch base rather than guessing at
# RunPod's own base-image tag scheme — RunPod serverless runs any Docker
# image, it doesn't require one of theirs.
FROM pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir demucs runpod requests librosa

# librosa pulls in its own scipy/numpy resolution, which on this base image
# ends up linking Intel MKL — MKL's own threading layer conflicts with the
# libgomp (GNU OpenMP) that PyTorch/demucs already load in the same process,
# crashing demucs at import time ("MKL_THREADING_LAYER=INTEL is incompatible
# with libgomp.so.1"). Forcing MKL onto the GNU threading layer instead of
# its own resolves the conflict; this didn't come up before librosa was added
# since nothing pulled in an MKL-linked scipy/numpy until then.
ENV MKL_THREADING_LAYER=GNU

# Bake the separation weights into the image instead of letting the first job
# fetch them. Demucs downloads checkpoints to the torch hub cache on first
# use, so without this every cold worker pays a model download before it can
# start separating — a meaningful slice of the ~57s cold starts this endpoint
# has shown, and a network dependency at inference time for no reason.
RUN python -c "from demucs.pretrained import get_model; get_model('htdemucs_6s')"

COPY handler.py /app/handler.py

CMD ["python3", "-u", "handler.py"]
