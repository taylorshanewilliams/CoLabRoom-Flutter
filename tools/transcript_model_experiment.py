"""Is a newer transcription model better at the failures we actually have?

Measured on four real songs, the shipping path (vocal stem -> whisper-1)
produced a flawed transcript on three of them: a hallucinated opener ("This
is a song about the"), a duplicated first line, and an entire missing verse.
Lyric accuracy is the thing CoLabRoom says it competes on, so that is the
weakest link in the pipeline and worth attacking directly.

**Text only, deliberately.** gpt-4o-transcribe does not support
`timestamp_granularities` — word-level timings are whisper-1's alone, and
lyric sync (per-line timing, Live mode's synced scroll) is built on them. So
this cannot answer "should we swap the model", because swapping would break
sync outright. It answers the question underneath: does a better model fix
these specific failures? If it does, that justifies the real fix — either a
hybrid (better text aligned onto whisper's timings) or self-hosting
faster-whisper large-v3, which does produce word timestamps and ships a VAD
filter aimed squarely at hallucination over non-speech.

Scores the failure modes actually observed rather than a generic WER against
a reference that is itself flawed — that mistake made the last experiment's
headline numbers say the opposite of what its transcripts said.

Costs one call per model per song, a few cents.

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  OPENAI_API_KEY              same key transcribe-audio uses
  PROJECT_ID                  optional — one project, else every song with
                              a vocals stem
"""

from __future__ import annotations

import difflib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

# whisper-1 first: it is what production runs, so it is the baseline the
# others are being judged against rather than just another entry.
MODELS = ("whisper-1", "gpt-4o-transcribe")
PROMPT = "Song lyrics, sung vocals."

# Openers Whisper is known to invent when it is unsure, rather than return
# nothing. Matched at the very start only — a song may legitimately contain
# these words later.
HALLUCINATED_OPENERS = (
    "this is a song about",
    "thanks for watching",
    "subscribe to",
    "please subscribe",
    "thank you for watching",
)


def env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        print(f"FAIL: {name} is not set.")
        sys.exit(1)
    return value


def request(url: str, *, method: str = "GET", headers: dict, data: bytes | None = None):
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=600) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code}: {detail[:300]}") from error


def download(url: str, headers: dict, path: str) -> None:
    req = urllib.request.Request(url)
    for key, value in headers.items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=600) as response, open(path, "wb") as f:
        f.write(response.read())


def transcribe(api_key: str, path: str, model: str) -> str | None:
    with open(path, "rb") as f:
        audio = f.read()
    boundary = "----colabroommodelexperiment"
    parts = []
    for field, value in (("model", model), ("prompt", PROMPT), ("response_format", "json")):
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{field}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="vocals.mp3"\r\n'
        "Content-Type: audio/mpeg\r\n\r\n".encode() + audio + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    try:
        result = request(
            "https://api.openai.com/v1/audio/transcriptions",
            method="POST",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
            },
            data=b"".join(parts),
        )
    except RuntimeError as error:
        # A model this account can't reach shouldn't kill the whole run —
        # report it and let the others still be compared.
        print(f"    {model}: request failed — {error}")
        return None
    return ((result or {}).get("text") or "").strip()


def tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def name_from_transcript(text: str) -> str | None:
    """Port of nameFromTranscript() — what Studio would title the idea."""
    cleaned = re.sub(r"\s+", " ", text or "").strip()
    if len(cleaned) < 3:
        return None
    words = [w for w in cleaned.split(" ") if w]
    title = " ".join(words[:6])
    if len(title) > 48:
        title = title[:48].rstrip()
    return re.sub(r"[,;:.\-—]+$", "", title).strip() or None


def hallucinated_opener(text: str) -> str | None:
    head = re.sub(r"\s+", " ", (text or "").lower()).strip()
    for phrase in HALLUCINATED_OPENERS:
        if head.startswith(phrase):
            return phrase
    return None


def repeated_runs(text: str, window: int = 6) -> int:
    """Consecutive identical word-windows — the shape of a stuck transcript.

    Catches both the duplicated opening line and the long "oh, oh, oh…" runs
    seen in the earlier experiment, without needing line breaks the API
    doesn't reliably give.
    """
    words = tokens(text)
    if len(words) < window * 2:
        return 0
    repeats = 0
    i = 0
    while i + window * 2 <= len(words):
        if words[i:i + window] == words[i + window:i + window * 2]:
            repeats += 1
            i += window
        else:
            i += 1
    return repeats


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    openai_key = env("OPENAI_API_KEY")
    wanted = (os.environ.get("PROJECT_ID") or "").strip()

    supabase_url = f"https://{project_ref}.supabase.co"
    rest_headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}

    refs = request(
        f"{supabase_url}/rest/v1/project_audio_references?select=project_id,duration_ms",
        headers=rest_headers,
    ) or []
    if wanted:
        refs = [r for r in refs if r["project_id"] == wanted]

    songs = []
    for ref in refs:
        stems = request(
            f"{supabase_url}/rest/v1/project_stems"
            f"?select=stem,storage_path&project_id=eq.{ref['project_id']}",
            headers=rest_headers,
        ) or []
        vocals = next((s["storage_path"] for s in stems if s["stem"] == "vocals"), None)
        if vocals:
            songs.append((ref["project_id"], vocals))

    if not songs:
        print("No songs with a vocals stem found.")
        return 1

    print(f"Comparing {' vs '.join(MODELS)} on {len(songs)} song(s), vocal stem only.")
    print("Text quality only — gpt-4o-transcribe cannot produce the word timings")
    print("lyric sync is built on, so this is not a swap decision.")
    print()

    for project_id, vocal_path in songs:
        print(f"── {project_id[:8]} " + "─" * 50)
        with tempfile.TemporaryDirectory() as tmp:
            local = os.path.join(tmp, "vocals.mp3")
            download(
                f"{supabase_url}/storage/v1/object/room-files/"
                f"{urllib.parse.quote(vocal_path, safe='/')}",
                rest_headers,
                local,
            )
            texts: dict[str, str] = {}
            for model in MODELS:
                text = transcribe(openai_key, local, model)
                if text is None:
                    continue
                texts[model] = text
                opener = hallucinated_opener(text)
                repeats = repeated_runs(text)
                print(f"  {model}")
                print(f"    words:            {len(tokens(text))}")
                print(f"    hallucinated open: {opener or 'no'}")
                print(f"    repeated runs:     {repeats}")
                print(f"    Studio would name: {name_from_transcript(text) or '(nothing usable)'}")
                print(f"    opening:           {text[:160]}")

            if len(texts) == 2:
                a, b = (tokens(texts[m]) for m in MODELS)
                ratio = difflib.SequenceMatcher(a=a, b=b, autojunk=False).ratio()
                print(f"  agreement between the two: {100.0 * ratio:.1f}%")
        print()

    print("Reading this: fewer hallucinated openers and fewer repeated runs is the")
    print("result that matters — those are the failures actually observed in")
    print("production transcripts. Raw agreement between two models says only that")
    print("they heard the same song, not that either heard it correctly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
