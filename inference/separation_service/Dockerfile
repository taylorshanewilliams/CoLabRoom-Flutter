# A standard, well-documented CUDA+PyTorch base rather than guessing at
# RunPod's own base-image tag scheme — RunPod serverless runs any Docker
# image, it doesn't require one of theirs.
FROM pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir demucs runpod requests librosa

# torchaudio pinned to match this image's torch 2.3.0, from PyTorch's own
# cu121 index. beat_this depends on torchaudio, and letting pip resolve it
# freely installs a build compiled against a newer torch — whose native
# extension then refuses to load ("Could not load this library:
# libtorchaudio.so"), taking the whole import down with it.
RUN pip install --no-cache-dir torchaudio==2.3.0 --index-url https://download.pytorch.org/whl/cu121

RUN pip install --no-cache-dir https://github.com/CPJKU/beat_this/archive/main.zip

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

# Same reasoning for the beat tracker's checkpoint — fetched at build time so
# no cold worker pays a model download mid-job.
RUN python -c "from beat_this.inference import File2Beats; File2Beats(checkpoint_path='final0', device='cpu', dbn=False)"

COPY handler.py /app/handler.py
# Shipped in the image so CI can run the real handler inside the real
# container before the image is published — the environment differences
# (ffmpeg build, installed codecs) are exactly what has broken in the past.
COPY smoke_test.py /app/smoke_test.py

CMD ["python3", "-u", "handler.py"]
