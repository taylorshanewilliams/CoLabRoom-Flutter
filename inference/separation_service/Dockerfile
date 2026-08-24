# A standard, well-documented CUDA+PyTorch base rather than guessing at
# RunPod's own base-image tag scheme — RunPod serverless runs any Docker
# image, it doesn't require one of theirs.
FROM pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir demucs runpod requests librosa

# The base image ships a conda-built torchaudio 2.3.0 whose native extension
# will not load in this container ("Could not load this library:
# libtorchaudio.so"). Nothing imported it before — demucs decodes through
# ffmpeg — so it stayed broken and unnoticed until beat_this, which does.
#
# Force-reinstalling the official cu121 wheel over the top replaces the bad
# native library. --no-deps so it can't drag torch itself along with it,
# which would be a far bigger change than the one intended.
RUN pip install --no-cache-dir --force-reinstall --no-deps \
    torchaudio==2.3.0 --index-url https://download.pytorch.org/whl/cu121 \
    && python -c "import torchaudio; print('torchaudio', torchaudio.__version__, 'loads')"

RUN pip install --no-cache-dir https://github.com/CPJKU/beat_this/archive/main.zip

# Functional song structure — Intro/Verse/Chorus rather than A/B/C.
#
# The openmirlab fork rather than the original `allin1`: the original needs
# NATTEN compiled against an exact torch+CUDA pair, and madmom installed from
# a git branch because the released one doesn't build against modern numpy.
# That's two fragile build-time dependencies for a feature nothing can verify
# until a real song goes through it. This fork uses pure-PyTorch neighborhood
# attention and madmom-infer, so it installs from PyPI with no compilation.
#
# It brings its own `demucs_infer` for its own separation pass. Deliberately a
# distinct module from the `demucs` installed above rather than a replacement
# for it — this image needs both, since htdemucs_6s is what gives us guitar
# and piano as separate stems, and the structure model wants the four-stem
# demix it was trained on.
#
# Constrained to the torch already in this image. Unconstrained, pip resolves
# all-in-one-infer's `torch>=2.0` to the newest release and downloads a
# complete second PyTorch and CUDA stack next to the one the base image
# ships — torch 2.13 (527MB) plus cudnn (366MB), cublas (423MB), nccl
# (206MB), cusparselt (170MB) and the rest. Around 2.7GB of duplicate,
# unused CUDA, which is why a *cached* image took four and a half minutes to
# load on a cold worker and why every first analysis of the day paid for it.
#
# It also quietly replaced the torchaudio wheel pinned above, undoing a fix
# that exists because the base image's own copy will not load. The constraint
# protects that too.
RUN printf 'torch==2.3.0\ntorchaudio==2.3.0\n' > /tmp/torch-constraints.txt \
    && pip install --no-cache-dir -c /tmp/torch-constraints.txt all-in-one-infer \
    && python -c "import allin1_infer; print('allin1_infer imports')" \
    && python -c "import torch, torchaudio; print('torch', torch.__version__, 'torchaudio', torchaudio.__version__)" \
    && python -c "import torch; assert torch.__version__.startswith('2.3.'), torch.__version__"

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

# And for the structure model, which is an eight-fold ensemble — eight
# checkpoints a cold worker would otherwise fetch before it could name a
# single section. Downloaded without running inference, so a build failure
# here means the package moved its loader rather than that a synthetic test
# clip confused a beat tracker.
RUN python -c "from allin1_infer.models.loaders import load_pretrained_model; load_pretrained_model('harmonix-all', device='cpu'); print('harmonix-all cached')"

# The structure model's own separation pass uses demucs_infer's htdemucs,
# which is a different checkpoint from the htdemucs_6s baked in above.
RUN python -c "from demucs_infer.pretrained import get_model; get_model('htdemucs')"

COPY handler.py /app/handler.py
# Shipped in the image so CI can run the real handler inside the real
# container before the image is published — the environment differences
# (ffmpeg build, installed codecs) are exactly what has broken in the past.
COPY smoke_test.py /app/smoke_test.py

CMD ["python3", "-u", "handler.py"]
