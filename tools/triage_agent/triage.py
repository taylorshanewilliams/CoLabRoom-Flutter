"""Diagnoses new analysis-pipeline failures and files them as GitHub issues.

Reads `analysis_error_signatures` (see migration 0020), finds signatures that
have not been triaged yet, hands each one to Claude along with the relevant
source files and recent commits, and opens an issue with the diagnosis.

Deliberately scoped to diagnosis. It does not commit, push, or deploy
anything — the whole point is that a human reads the diagnosis and decides.
See the system prompt below for why that boundary matters here specifically.

Environment:
  SUPABASE_URL                 project URL — optional, derived from
                               SUPABASE_PROJECT_REF when unset
  SUPABASE_PROJECT_REF         project ref (already used by the deploy workflow)
  SUPABASE_SERVICE_ROLE_KEY    service role key (reads errors, writes triage)
  ANTHROPIC_API_KEY            for the diagnosis call
  GITHUB_TOKEN                 to open issues
  GITHUB_REPOSITORY            "owner/repo", provided by Actions
  TRIAGE_DRY_RUN               when "1", print instead of filing or recording
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import anthropic
import requests

MODEL = "claude-opus-5"


def _env(name: str) -> str:
    """Treats blank as absent — Actions supplies "" for an unset secret, and
    an empty string produces a far more confusing failure downstream than a
    missing one does.
    """
    return (os.environ.get(name) or "").strip()


# Derived from the project ref when not given outright, so the workflow can
# reuse the SUPABASE_PROJECT_REF secret the deploy workflow already has
# rather than requiring the same project be configured twice.
SUPABASE_URL = _env("SUPABASE_URL").rstrip("/")
if not SUPABASE_URL and _env("SUPABASE_PROJECT_REF"):
    SUPABASE_URL = f"https://{_env('SUPABASE_PROJECT_REF')}.supabase.co"

SERVICE_KEY = _env("SUPABASE_SERVICE_ROLE_KEY")
GITHUB_TOKEN = _env("GITHUB_TOKEN")
GITHUB_REPOSITORY = _env("GITHUB_REPOSITORY")
DRY_RUN = _env("TRIAGE_DRY_RUN") == "1"

REPO_ROOT = Path(__file__).resolve().parents[2]

# Per-file cap. Generous enough for whole services, small enough that a
# handful of files plus history stays well inside the context window.
MAX_FILE_CHARS = 40_000

# Which sources are worth putting in front of the model for a given failure
# stage. A wrong guess here costs some tokens; a missing entry costs a
# diagnosis, so the fallback is deliberately broad.
STAGE_SOURCES: dict[str, list[str]] = {
    "separation": [
        "inference/separation_service/handler.py",
        "inference/separation_service/Dockerfile",
        "supabase/functions/analyze-chords/index.ts",
    ],
    "chords": [
        "inference/chord_service/app.py",
        "supabase/functions/analyze-chords/index.ts",
        "lib/services/song_analysis_service.dart",
    ],
    "lyrics": [
        "supabase/functions/transcribe-audio/index.ts",
        "lib/services/song_analysis_service.dart",
    ],
}
DEFAULT_SOURCES = [
    "lib/services/song_analysis_service.dart",
    "supabase/functions/analyze-chords/index.ts",
]

SYSTEM_PROMPT = """\
You are triaging production failures in CoLabRoom, a Flutter + Supabase app \
for musicians. Its analysis pipeline separates a recording into instrument \
stems (Demucs on RunPod Serverless), detects chords (ChordMini on Cloud Run), \
and transcribes lyrics (Whisper via an OpenAI call from a Supabase Edge \
Function). A Supabase Edge Function orchestrates the three.

You produce a diagnosis for a human to act on. You are not applying the fix.

Hold to these, they are what make the output worth reading:

- Distinguish the change that makes the error stop appearing from the change \
that makes the problem stop existing. In this codebase those diverge often, \
and the second one is what is wanted. A real example: an ffmpeg filter \
failed, and simply deleting the offending option would have silenced the \
error while leaving the audio mix at a quarter of its intended level — \
quietly degrading chord detection with nothing left to alert on. Call out \
that trap whenever a candidate fix has that shape.

- Severity here is not about whether the app crashed. This pipeline catches \
its own failures and falls back to a much less accurate on-device chord \
heuristic, so a "warning" can mean every user silently got worse results \
while every dashboard stayed green. Weigh degradation as heavily as crashes.

- Say plainly when you do not know. A confident wrong diagnosis costs more \
than an honest "not enough information", because someone will act on it. If \
the evidence is thin, say what additional logging or reproduction would \
settle it.

- Prefer the boring explanation. Version skew, a missing environment \
variable, a changed API contract, and a wrong assumption about a third-party \
service are all likelier than a subtle logic bug.

Respond with a fenced ```json block, and nothing after it, of the shape:

{
  "title": "one line, under 80 chars, names the actual fault",
  "confidence": "high" | "medium" | "low",
  "severity": "critical" | "degraded" | "minor",
  "body": "GitHub-flavored markdown"
}

The body should cover: what is failing and where, the most likely root cause, \
the evidence for it, a proposed fix (with the code change if you are \
confident enough to write it), and anything that would falsify your \
diagnosis. Keep it tight — someone reads this at speed."""


def supabase_get(path: str, params: dict[str, str]) -> list[dict]:
    response = requests.get(
        f"{SUPABASE_URL}/rest/v1/{path}",
        params=params,
        headers={
            "apikey": SERVICE_KEY,
            "Authorization": f"Bearer {SERVICE_KEY}",
        },
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def supabase_insert(path: str, row: dict) -> None:
    response = requests.post(
        f"{SUPABASE_URL}/rest/v1/{path}",
        json=row,
        headers={
            "apikey": SERVICE_KEY,
            "Authorization": f"Bearer {SERVICE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates",
        },
        timeout=30,
    )
    response.raise_for_status()


def untriaged_signatures() -> list[dict]:
    """Signatures with no triage row yet, worst-looking first.

    Ordered by affected users rather than raw occurrences: one user retrying
    a broken analysis ten times is less urgent than ten users hitting it once.
    """
    signatures = supabase_get("analysis_error_signatures", {"select": "*"})
    triaged = {row["signature"] for row in supabase_get("error_triage", {"select": "signature"})}
    fresh = [s for s in signatures if s["signature"] not in triaged]
    fresh.sort(key=lambda s: (s.get("affected_users") or 0, s.get("occurrences") or 0), reverse=True)
    return fresh


def read_source(relative: str) -> str | None:
    path = REPO_ROOT / relative
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    if len(text) > MAX_FILE_CHARS:
        text = text[:MAX_FILE_CHARS] + "\n… (truncated)"
    return text


def recent_commits() -> str:
    try:
        return subprocess.run(
            ["git", "log", "--oneline", "-25"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "(unavailable)"


def build_prompt(signature: dict) -> str:
    message = signature.get("latest_message") or ""
    sources: list[str] = []
    for stage in signature.get("stages") or []:
        sources.extend(STAGE_SOURCES.get(stage, []))
    # Belt and braces: an error reported without a stage still usually names
    # the failing step somewhere in its text.
    for stage, paths in STAGE_SOURCES.items():
        if stage in message.lower():
            sources.extend(paths)
    if not sources:
        sources = list(DEFAULT_SOURCES)

    seen: set[str] = set()
    ordered = [s for s in sources if not (s in seen or seen.add(s))]

    parts = [
        "## Failure signature",
        f"- Occurrences: {signature.get('occurrences')}",
        f"- Affected users: {signature.get('affected_users')}",
        f"- Severities: {signature.get('severities')}",
        f"- Reported by: {signature.get('services')}",
        f"- Failing stage: {signature.get('stages')}",
        f"- First seen: {signature.get('first_seen')}",
        f"- Last seen: {signature.get('last_seen')}",
        f"- App version: {signature.get('latest_app_version')}",
        "",
        "### Normalized signature",
        "```",
        signature.get("signature", ""),
        "```",
        "",
        "### Most recent full message",
        "```",
        message[:20_000],
        "```",
        "",
        "## Recent commits",
        "```",
        recent_commits(),
        "```",
        "",
        "## Relevant sources",
    ]
    for relative in ordered:
        content = read_source(relative)
        if content is None:
            continue
        parts += ["", f"### {relative}", "```", content, "```"]
    return "\n".join(parts)


def diagnose(client: anthropic.Anthropic, signature: dict) -> dict:
    response = client.beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        # Adaptive thinking: root-causing a stack trace against several
        # services benefits from the model actually reasoning before it
        # commits to an answer.
        thinking={"type": "adaptive"},
        output_config={"effort": "high"},
        # Recommended default for Opus 5 — on a policy decline the API
        # retries the same request on a fallback model rather than the run
        # simply producing nothing.
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": build_prompt(signature)}],
    )

    if response.stop_reason == "refusal":
        raise RuntimeError(f"Diagnosis refused: {response.stop_details}")

    text = "".join(block.text for block in response.content if block.type == "text")
    return parse_diagnosis(text)


def parse_diagnosis(text: str) -> dict:
    """Pulls the JSON block out of the reply, degrading rather than failing.

    A malformed reply should still reach a human — filing the raw text under
    low confidence is far better than dropping a real production failure
    because the wrapper didn't parse.
    """
    # Decoded from the first brace rather than pulled out of a fence.
    #
    # This used to match ```json ... ``` non-greedily, which fails on exactly
    # the replies worth reading: `body` is markdown, useful markdown contains
    # fenced code blocks, and a non-greedy match therefore ends at the first
    # *inner* fence and truncates the JSON mid-string. Every issue this agent
    # has filed was filed as "unstructured diagnosis" with a perfectly good
    # diagnosis pasted underneath it. The failure was in the wrapper, and it
    # read as a failure of the model.
    #
    # raw_decode reads exactly one complete JSON value and ignores whatever
    # follows it, so a closing fence, a trailing sentence, or nested fences
    # all cost nothing. Each opening brace is tried in turn, so prose before
    # the JSON is survivable too.
    decoder = json.JSONDecoder()
    start = text.find("{")
    while start != -1:
        try:
            parsed, _ = decoder.raw_decode(text, start)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict) and parsed.get("body"):
            return {
                "title": str(parsed.get("title") or "Untitled analysis failure")[:80],
                "confidence": str(parsed.get("confidence") or "low"),
                "severity": str(parsed.get("severity") or "minor"),
                "body": str(parsed["body"]),
            }
        start = text.find("{", start + 1)
    return {
        "title": "Analysis failure (unstructured diagnosis)",
        "confidence": "low",
        "severity": "minor",
        "body": f"The triage model did not return parseable JSON. Raw reply:\n\n{text}",
    }


def open_issue(signature: dict, diagnosis: dict) -> tuple[int | None, str | None]:
    body = (
        f"{diagnosis['body']}\n\n"
        "---\n"
        f"**Confidence:** {diagnosis['confidence']} · "
        f"**Severity:** {diagnosis['severity']} · "
        f"**Occurrences:** {signature.get('occurrences')} across "
        f"{signature.get('affected_users')} user(s)\n\n"
        "<details><summary>Normalized signature</summary>\n\n"
        f"```\n{signature.get('signature', '')}\n```\n\n</details>\n\n"
        "_Filed automatically by the triage agent. The diagnosis is a "
        "starting point, not a verified fix._"
    )
    response = requests.post(
        f"https://api.github.com/repos/{GITHUB_REPOSITORY}/issues",
        json={
            "title": f"[triage] {diagnosis['title']}",
            "body": body,
            "labels": ["triage", f"severity:{diagnosis['severity']}"],
        },
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
        },
        timeout=30,
    )
    if response.status_code >= 300:
        print(f"  ! could not open issue ({response.status_code}): {response.text[:400]}")
        return None, None
    created = response.json()
    return created.get("number"), created.get("html_url")


def missing_configuration() -> list[str]:
    missing = []
    if not SUPABASE_URL:
        missing.append("SUPABASE_URL (or SUPABASE_PROJECT_REF)")
    if not SERVICE_KEY:
        missing.append("SUPABASE_SERVICE_ROLE_KEY")
    if not _env("ANTHROPIC_API_KEY"):
        missing.append("ANTHROPIC_API_KEY")
    if not DRY_RUN and not GITHUB_TOKEN:
        missing.append("GITHUB_TOKEN")
    return missing


def main() -> int:
    missing = missing_configuration()
    if missing:
        # Exits clean rather than red. This runs hourly, and a permanently
        # failing scheduled workflow is one people mute — at which point it
        # stops being a monitor. The message has to carry the signal instead.
        print("Triage agent is not configured yet; skipping this run.")
        print("Add these repository secrets to enable it:")
        for name in missing:
            print(f"  - {name}")
        return 0

    fresh = untriaged_signatures()
    if not fresh:
        print("No new error signatures.")
        return 0

    print(f"{len(fresh)} new signature(s) to triage.")
    client = anthropic.Anthropic()

    for signature in fresh:
        label = signature["signature"][:90].replace("\n", " ")
        print(f"\n▸ {label}")
        try:
            diagnosis = diagnose(client, signature)
        except Exception as error:  # noqa: BLE001 - one bad signature shouldn't stop the run
            print(f"  ! diagnosis failed: {error}")
            continue

        print(f"  {diagnosis['severity']} / {diagnosis['confidence']} — {diagnosis['title']}")
        if DRY_RUN:
            print(diagnosis["body"][:2000])
            continue

        number, url = open_issue(signature, diagnosis)
        if url:
            print(f"  → {url}")
        supabase_insert(
            "error_triage",
            {
                "signature": signature["signature"],
                "issue_number": number,
                "issue_url": url,
                "confidence": diagnosis["confidence"],
                "diagnosis": diagnosis["title"],
                "occurrences_at_triage": signature.get("occurrences"),
            },
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
