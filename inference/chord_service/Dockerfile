FROM python:3.10-slim

WORKDIR /app

# ffmpeg/libsndfile1: audio decoding for librosa/soundfile, which
# ChordMini's own requirements.txt depends on.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# Pinned by commit would be more reproducible than --depth 1 off main, but
# ChordMini has no release tags to pin to yet — revisit if upstream moves
# in a way that breaks this.
RUN git clone --depth 1 https://github.com/ptnghia-j/ChordMini.git

RUN pip install --no-cache-dir -r ChordMini/requirements.txt \
    && pip install --no-cache-dir fastapi "uvicorn[standard]" python-multipart

COPY app.py /app/app.py

ENV PORT=8080
EXPOSE 8080

# Cloud Run injects PORT; shell form so ${PORT} actually expands.
CMD uvicorn app:app --host 0.0.0.0 --port ${PORT}
