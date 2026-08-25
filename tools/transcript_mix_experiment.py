"""Does Whisper need the isolated vocal, or is the original recording enough?

The remaining unknown behind making Studio skip separation entirely. Chords
were already shown not to need it (tools/chord_mix_experiment.py, ~93%
agreement over four songs). Lyrics are the one consumer that plausibly still
does — Whisper currently gets the isolated vocal stem, and a dense mix
burying the vocal is exactly the case separation was supposed to fix.

It matters more than the raw cost, because Studio's two best features depend
on the transcript rather than merely displaying it: ideas are auto-named from
the first words actually sung, and the library is searchable by them. A
transcript that degrades quietly makes both worse in ways nobody reports —
they just conclude the feature doesn't work.

Deliberately tested on full productions rather than sparse idea captures,
because that is the *worst* case. A solo vocal or acoustic recording is
already almost entirely vocal, so separation has little to remove; if the raw
file holds up on a dense mix it certainly holds up on a sparse one. A bad
result here would only prove the dense case needs separation, which is the
case that belongs in Analyze Song anyway.

Compares against the vocal stem as the reference, since that is what
production does today — so "error rate" here means "how far the raw file
drifts from current behaviour", not from ground truth. Neither is ground
truth; only a human transcribing the song would be.

Costs two Whisper calls (a few cents) and no GPU — the stems are already in
Storage.

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  OPENAI_API_KEY              from platform.openai.com — the same key the
                              transcribe-audio Edge Function uses
  PROJECT_ID                  optional — which project's song to test
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

# Matched to transcribe-audio/index.ts so this measures the same call
# production makes, not a differently-configured one.
WHISPER_MODEL = "whisper-1"
WHISPER_PROMPT = "Song lyrics, sung vocals."


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
        raise RuntimeError(f"HTTP {error.code} for {method} {url}: {detail[:400]}") from error


def download(url: str, headers: dict, path: str) -> None:
    req = urllib.request.Request(url)
    for key, value in headers.items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=600) as response, open(path, "wb") as f:
        f.write(response.read())


def transcribe(api_key: str, path: str, label: str) -> str:
    with open(path, "rb") as f:
        audio = f.read()
    boundary = "----colabroomtranscriptexperiment"
    parts = []
    for field, value in (("model", WHISPER_MODEL), ("prompt", WHISPER_PROMPT),
                         ("response_format", "json")):
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{field}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{label}.mp3"\r\n'
        "Content-Type: audio/mpeg\r\n\r\n".encode() + audio + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    result = request(
        "https://api.openai.com/v1/audio/transcriptions",
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        data=b"".join(parts),
    )
    return ((result or {}).get("text") or "").strip()


def tokens(text: str) -> list[str]:
    """Words, lowercased and stripped of punctuation.

    Comparing raw strings would count "you're" vs "youre" and a missing comma
    as errors, which says nothing about whether the words were heard.
    """
    return re.findall(r"[a-z0-9']+", text.lower())


def name_from_transcript(text: str, max_words: int = 6, max_chars: int = 48) -> str | None:
    """Faithful port of nameFromTranscript() in studio_draft_service.dart.

    Compared directly because this, not the transcript itself, is what a
    Studio user actually sees — an idea named after what they sang.
    """
    cleaned = re.sub(r"\s+", " ", text or "").strip()
    if len(cleaned) < 3:
        return None
    words = [w for w in cleaned.split(" ") if w]
    if not words:
        return None
    title = " ".join(words[:max_words])
    if len(title) > max_chars:
        title = title[:max_chars].rstrip()
    title = re.sub(r"[,;:.\-—]+$", "", title).strip()
    return title or None


def compare(raw_text: str, vocal_text: str) -> None:
    raw = tokens(raw_text)
    vocal = tokens(vocal_text)

    print()
    print(f"  Words heard — vocal stem (reference): {len(vocal)}")
    print(f"  Words heard — raw recording:          {len(raw)}")

    if not vocal:
        print()
        print("  The vocal stem produced no words at all — nothing to compare against.")
        print("  (Either an instrumental, or Whisper found no speech.)")
        return

    matcher = difflib.SequenceMatcher(a=vocal, b=raw, autojunk=False)
    similarity = matcher.ratio()

    substitutions = deletions = insertions = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "replace":
            substitutions += max(i2 - i1, j2 - j1)
        elif tag == "delete":
            deletions += i2 - i1
        elif tag == "insert":
            insertions += j2 - j1
    wer = (substitutions + deletions + insertions) / len(vocal)

    print()
    print(f"  Word sequence similarity:  {100.0 * similarity:.1f}%")
    print(f"  Word error rate vs stem:   {100.0 * wer:.1f}%  "
          f"({substitutions} sub, {deletions} del, {insertions} ins)")
    print()
    print("  What Studio would name the idea:")
    print(f"    from vocal stem:    {name_from_transcript(vocal_text) or '(nothing usable)'}")
    print(f"    from raw recording: {name_from_transcript(raw_text) or '(nothing usable)'}")
    print()
    print("  First 200 characters of each:")
    print(f"    vocal stem: {(vocal_text or '(empty)')[:200]}")
    print(f"    raw:        {(raw_text or '(empty)')[:200]}")


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    openai_key = env("OPENAI_API_KEY")
    wanted_project = (os.environ.get("PROJECT_ID") or "").strip()

    supabase_url = f"https://{project_ref}.supabase.co"
    rest_headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }
    storage_headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}

    refs = request(
        f"{supabase_url}/rest/v1/project_audio_references"
        f"?select=project_id,file_id,duration_ms&file_id=not.is.null",
        headers=rest_headers,
    ) or []
    if wanted_project:
        refs = [r for r in refs if r["project_id"] == wanted_project]
    if not refs:
        print("No analysed songs with a reference recording found.")
        return 1

    chosen = None
    for ref in refs:
        stems = request(
            f"{supabase_url}/rest/v1/project_stems"
            f"?select=stem,storage_path&project_id=eq.{ref['project_id']}",
            headers=rest_headers,
        ) or []
        vocals = next((s["storage_path"] for s in stems if s["stem"] == "vocals"), None)
        if not vocals:
            continue
        file_row = request(
            f"{supabase_url}/rest/v1/files?select=storage_path&id=eq.{ref['file_id']}",
            headers=rest_headers,
        ) or []
        if file_row:
            chosen = (ref, vocals, file_row[0]["storage_path"])
            break

    if not chosen:
        print("No song found with both a reference recording and a vocals stem.")
        return 1

    ref, vocal_path, reference_path = chosen
    print(f"Testing project {ref['project_id'][:8]}… "
          f"({round((ref.get('duration_ms') or 0) / 1000)}s of audio)")
    print()

    with tempfile.TemporaryDirectory() as tmp:
        raw_local = os.path.join(tmp, "raw" + os.path.splitext(reference_path)[1])
        vocal_local = os.path.join(tmp, "vocals.mp3")

        print("Downloading the original recording and the vocal stem…")
        for remote, local in ((reference_path, raw_local), (vocal_path, vocal_local)):
            download(
                f"{supabase_url}/storage/v1/object/room-files/"
                f"{urllib.parse.quote(remote, safe='/')}",
                storage_headers,
                local,
            )

        print("Transcribing the VOCAL STEM (what production does today)…")
        vocal_text = transcribe(openai_key, vocal_local, "vocals")
        print(f"  {len(tokens(vocal_text))} words")

        print("Transcribing the RAW RECORDING (what Studio would do)…")
        raw_text = transcribe(openai_key, raw_local, "raw")
        print(f"  {len(tokens(raw_text))} words")

        compare(raw_text, vocal_text)

    print()
    print("Reading this: a low error rate means Studio can transcribe the raw")
    print("file and skip separation entirely. A high one means the vocal stem is")
    print("doing real work — and since this was run on a dense mix, that would")
    print("argue for keeping separation on the Analyze Song path, not that")
    print("Studio's sparse captures need it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
