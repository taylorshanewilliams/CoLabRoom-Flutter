"""Scores every transcription path against the lyrics the writer actually wrote.

Every earlier experiment in this repo compared two machine outputs to each
other, which measures similarity and calls it accuracy. That produced one
conclusion confident enough to be written into docs/ANALYSIS_COST.md and
wrong enough to need retracting a day later. This one has a reference: the
song's own contributions, typed by the person who wrote it.

**Prints scores, never text.** The workflow log is public and these are
unreleased songs. Nothing here emits a lyric, a transcript, or an excerpt of
either — only word counts and error rates, which is all a comparison needs.

Compares three paths on the same audio:
  whisper-1          what production sends today, via OpenAI
  gpt-4o-transcribe  better text in earlier tests, but cannot emit the word
                     timings lyric sync is built on
  faster-whisper     large-v3-turbo on our own GPU, with VAD and a pinned
                     temperature; emits word timings, so it is the only
                     alternative that could actually replace production

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  OPENAI_API_KEY              already a repo secret
  RUNPOD_API_KEY              already a repo secret
  RUNPOD_ENDPOINT_ID          already a repo secret
  PROJECT_ID                  optional — one project, else every song that has
                              both written lyrics and a vocals stem
"""

from __future__ import annotations

import difflib
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PROMPT = "Song lyrics, sung vocals."
JOB_TIMEOUT_SECONDS = 900
POLL_SECONDS = 10

# Lines like "(Verse 1)" or "[Chorus]" are structure the writer typed for
# themselves, not words anybody sings. Scoring a transcript for failing to
# say "chorus" out loud would punish it for being right.
SECTION_LINE = re.compile(r"^\s*[\(\[][^)\]]*[\)\]]\s*$")


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


def words_of(text: str) -> list[str]:
    """Lowercased words, with apostrophes removed rather than split on.

    Removed, not treated as a boundary: `[a-z0-9]+` alone turns "don't" into
    two tokens, so a transcript that writes contractions scores worse than one
    that does not, purely for punctuation. Lyrics are made of contractions and
    Whisper prefers the curly apostrophe where a typed sheet has the straight
    one, so every "it's" in a song would have counted as an error against
    whichever engine wrote more of them. Caught by the unit test below, which
    is the only reason this is not silently deciding the comparison.
    """
    stripped = (text or "").lower().replace("'", "").replace("’", "")
    return re.findall(r"[a-z0-9]+", stripped)


def line_recall(reference_lines: list[list[str]], hypothesis: list[str]) -> float:
    """For each written line, how well does it appear anywhere in the transcript.

    Whole-transcript word error rate was the obvious metric and it was the
    wrong one. A lyric sheet writes each chorus once; the recording sings it
    three times, so a correct transcript is legitimately two or three times
    longer than the reference and every extra repeat counts as an insertion.
    That produced error rates above 100% on four of five songs and, worse,
    ranked the engines by how *little* they transcribed — the one that heard
    fewest words came out best, which is precisely backwards.

    Asking the question per line fixes it. A repeated chorus matches wherever
    it appears, extra material in the transcript costs nothing, and
    transcribing less earns nothing because every line still has to be found.
    A short window slides across the transcript looking for the best match,
    slightly wider than the line so a stray inserted word does not sink it.
    """
    if not reference_lines:
        return 0.0
    if not hypothesis:
        return 0.0
    scores: list[float] = []
    for line in reference_lines:
        if not line:
            continue
        width = min(len(hypothesis), len(line) + 3)
        best = 0.0
        for start in range(0, max(1, len(hypothesis) - width + 1)):
            window = hypothesis[start:start + width]
            # Matched words over line length, not SequenceMatcher.ratio().
            # ratio() divides by the combined length of both sides, so the
            # window being deliberately wider than the line caps a perfect
            # match at about 73% — which would have made every engine look
            # worse than it is, by a margin that varies with line length.
            matcher = difflib.SequenceMatcher(a=line, b=window, autojunk=False)
            matched = sum(block.size for block in matcher.get_matching_blocks())
            score = min(matched, len(line)) / len(line)
            if score > best:
                best = score
            if best >= 0.999:
                break
        scores.append(best)
    return sum(scores) / len(scores) if scores else 0.0


def openai_transcribe(api_key: str, path: str, model: str) -> str | None:
    with open(path, "rb") as f:
        audio = f.read()
    boundary = "----colabroomlyricaccuracy"
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
        print(f"      {model} failed: {error}")
        return None
    return ((result or {}).get("text") or "").strip()


def runpod_transcribe(api_key: str, endpoint: str, audio_url: str, filename: str) -> str | None:
    """Runs a real separation job with transcription switched on.

    Costs a GPU job, because the handler transcribes the vocal stem that job
    produces. Slower and dearer than the API calls above, and the only way to
    measure the path that could actually replace production.
    """
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    try:
        run = request(
            f"https://api.runpod.ai/v2/{endpoint}/run",
            method="POST",
            headers=headers,
            data=json.dumps({
                "input": {
                    "audio_url": audio_url,
                    "filename": filename,
                    "transcribe": True,
                    # Section naming runs a second separation pass and has
                    # nothing to do with lyrics.
                    "skip_structure": True,
                }
            }).encode(),
        )
    except RuntimeError as error:
        print(f"      faster-whisper submit failed: {error}")
        return None

    job_id = (run or {}).get("id")
    if not job_id:
        print("      faster-whisper: RunPod returned no job id")
        return None

    started = time.monotonic()
    while time.monotonic() - started < JOB_TIMEOUT_SECONDS:
        time.sleep(POLL_SECONDS)
        try:
            status = request(
                f"https://api.runpod.ai/v2/{endpoint}/status/{job_id}",
                headers=headers,
            ) or {}
        except RuntimeError:
            continue
        state = status.get("status")
        if state == "COMPLETED":
            output = status.get("output") or {}
            transcript = output.get("transcript")
            if not transcript:
                print("      faster-whisper: job completed but returned no transcript")
                return None
            if transcript.get("error"):
                print(f"      faster-whisper raised: {transcript['error']}")
                return None
            return (transcript.get("text") or "").strip()
        if state == "FAILED":
            print("      faster-whisper: job failed")
            return None
    print("      faster-whisper: timed out")
    return None


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    openai_key = env("OPENAI_API_KEY")
    runpod_key = env("RUNPOD_API_KEY")
    runpod_endpoint = env("RUNPOD_ENDPOINT_ID")
    wanted = (os.environ.get("PROJECT_ID") or "").strip()

    supabase_url = f"https://{project_ref}.supabase.co"
    rest = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}

    refs = request(
        f"{supabase_url}/rest/v1/project_audio_references?select=project_id,file_id",
        headers=rest,
    ) or []
    if wanted:
        refs = [r for r in refs if r["project_id"] == wanted]

    songs = []
    for ref in refs:
        pid = ref["project_id"]
        stems = request(
            f"{supabase_url}/rest/v1/project_stems?select=stem,storage_path&project_id=eq.{pid}",
            headers=rest,
        ) or []
        vocals = next((s["storage_path"] for s in stems if s["stem"] == "vocals"), None)
        lines = request(
            f"{supabase_url}/rest/v1/contributions?select=body,position&project_id=eq.{pid}"
            f"&order=position.asc",
            headers=rest,
        ) or []
        truth_lines = [
            words_of(row["body"]) for row in lines
            if row.get("body") and not SECTION_LINE.match(row["body"])
        ]
        truth_lines = [line for line in truth_lines if line]
        file_row = request(
            f"{supabase_url}/rest/v1/files?select=storage_path&id=eq.{ref['file_id']}",
            headers=rest,
        ) or []
        if vocals and truth_lines and file_row:
            songs.append((pid, vocals, file_row[0]["storage_path"], truth_lines))

    if not songs:
        print("No songs found with both written lyrics and a vocals stem.")
        return 1

    print(f"Scoring {len(songs)} song(s) against the lyrics in the workspace.")
    print("Scores only — no lyrics or transcripts are printed; this log is public.")
    print()
    print(f"  {'song':<10} {'engine':<20} {'lines':>6} {'heard':>7} {'line recall':>12}")

    totals: dict[str, list[float]] = {}
    for pid, vocal_path, reference_path, truth_lines in songs:
        with tempfile.TemporaryDirectory() as tmp:
            local = os.path.join(tmp, "vocals.mp3")
            req = urllib.request.Request(
                f"{supabase_url}/storage/v1/object/room-files/"
                f"{urllib.parse.quote(vocal_path, safe='/')}"
            )
            for key, value in rest.items():
                req.add_header(key, value)
            with urllib.request.urlopen(req, timeout=600) as response, open(local, "wb") as f:
                f.write(response.read())

            results: dict[str, str | None] = {
                "whisper-1": openai_transcribe(openai_key, local, "whisper-1"),
                "gpt-4o-transcribe": openai_transcribe(openai_key, local, "gpt-4o-transcribe"),
            }

        signed = request(
            f"{supabase_url}/storage/v1/object/sign/room-files/"
            f"{urllib.parse.quote(reference_path, safe='/')}",
            method="POST",
            headers={**rest, "Content-Type": "application/json"},
            data=json.dumps({"expiresIn": 3600}).encode(),
        ) or {}
        if signed.get("signedURL"):
            results["faster-whisper"] = runpod_transcribe(
                runpod_key,
                runpod_endpoint,
                f"{supabase_url}/storage/v1{signed['signedURL']}",
                reference_path.split("/")[-1],
            )

        for engine, text in results.items():
            if text is None:
                continue
            heard = words_of(text)
            recall = line_recall(truth_lines, heard)
            totals.setdefault(engine, []).append(recall)
            print(f"  {pid[:8]:<10} {engine:<20} {len(truth_lines):>6} {len(heard):>7} {recall:>11.1%}")
        print()

    print("  Mean line recall, higher is better:")
    for engine, scores in sorted(totals.items(), key=lambda kv: -sum(kv[1]) / len(kv[1])):
        print(f"    {engine:<20} {sum(scores) / len(scores):>7.1%}   ({len(scores)} song(s))")
    print()
    print("  Caveat: a written sheet still is not a perfect reference. It omits")
    print("  ad-libs and improvised lines, so no engine should be expected to")
    print("  reach 100%. What this does measure fairly is whether the words the")
    print("  writer actually wrote were heard, which is the question that matters.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
