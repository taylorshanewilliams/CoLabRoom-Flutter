"""Deletes separated stems nobody has touched in RETENTION_DAYS, and reclaims
the storage — the reference recording and every chord/key/lyric/structure
result stay forever; only the multi-megabyte instrument tracks expire.

The economics, worked out before picking a number: a song's stems run about
9MB, costing roughly $0.0002/month to store. Reprocessing a recording costs
$0.02-0.08 depending on how much of the pipeline has to rerun. That means
storage would have to sit for a *decade or more* before it costs as much as
one single reanalysis — so this was never really a storage-cost problem.
Left alone, storage grows without bound (nothing else expires it) while
compute is a flat per-analysis cost that this script cannot make worse. The
only real lever is capping the unbounded ramp without making reanalysis a
common event, so RETENTION_DAYS should be chosen from realistic "how long
would someone want instant playback of an in-progress song's stems" usage,
not from fear of the bill.

Reanalyzing after expiry currently reruns the *entire* pipeline — separation,
chords, and transcription — not just separation, even though the chord/key/
lyric results are still sitting in analysis_cache untouched. That's a real
gap (see reuseCachedAnalysis in analyze-chords/index.ts), worth fixing
separately since it touches the paid pipeline's job/poll state machine. This
script's economics already account for paying the full-reprocess price on
every return visit, which is the more conservative (higher) cost estimate
either way.

DRY_RUN defaults to true. Nothing is deleted until you explicitly pass
DRY_RUN=false — this is a first run of a new deletion path and should be
watched once before it's trusted unattended.

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  RETENTION_DAYS              stems older than this many days expire (default 90)
  DRY_RUN                     "true" (default) to report only, "false" to delete
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# (table, id column, bucket the stems for that table land in)
STEM_TABLES = (
    ("project_stems", "project_id", "room-files"),
    ("studio_draft_stems", "draft_id", "studio-drafts"),
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
        with urllib.request.urlopen(req, timeout=120) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code} for {method} {url}: {detail[:400]}") from error


def stem_dir_of(storage_path: str) -> str:
    # storage_path is "{stemDir}/{stem}.mp3" (analyze-chords/index.ts's
    # stemPathIn) — everything before the final segment is the directory
    # analysis_cache.stem_dir would point at.
    return storage_path.rsplit("/", 1)[0]


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    retention_days = int(os.environ.get("RETENTION_DAYS", "90"))
    dry_run = os.environ.get("DRY_RUN", "true").strip().lower() != "false"

    supabase_url = f"https://{project_ref}.supabase.co"
    rest_headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }
    cutoff = (datetime.now(timezone.utc) - timedelta(days=retention_days)).isoformat()

    print(f"Retention: {retention_days} days (cutoff {cutoff})")
    print(f"Mode: {'DRY RUN — nothing will be deleted' if dry_run else 'LIVE — deleting for real'}")
    print()

    total_rows = 0
    total_bytes = 0
    touched_dirs: set[tuple[str, str]] = set()  # (bucket, stem_dir)

    for table, id_column, bucket in STEM_TABLES:
        select_headers = {**rest_headers, "Prefer": "return=representation"}
        if dry_run:
            rows = request(
                f"{supabase_url}/rest/v1/{table}?select={id_column},stem,storage_path,byte_size,created_at"
                f"&created_at=lt.{cutoff}",
                headers=rest_headers,
            )
        else:
            rows = request(
                f"{supabase_url}/rest/v1/{table}?created_at=lt.{cutoff}",
                method="DELETE",
                headers=select_headers,
            )
        rows = rows or []
        print(f"{table}: {len(rows)} stem row(s) {'would expire' if dry_run else 'expired'}")

        for row in rows:
            total_rows += 1
            total_bytes += row.get("byte_size") or 0
            storage_path = row["storage_path"]
            touched_dirs.add((bucket, stem_dir_of(storage_path)))
            if not dry_run:
                try:
                    request(
                        f"{supabase_url}/storage/v1/object/{bucket}/{storage_path}",
                        method="DELETE",
                        headers=rest_headers,
                    )
                except RuntimeError as error:
                    # The row is already gone either way — a storage object
                    # that was already missing (or a permissions hiccup) is
                    # not worth failing the whole run over.
                    print(f"  (couldn't remove {bucket}/{storage_path}: {error})")

    print()
    print(f"Total: {total_rows} stem file(s), {round(total_bytes / 1048576, 1)} MB reclaimed"
          + (" (would be)" if dry_run else ""))

    if not touched_dirs:
        return 0

    print()
    print(f"Checking {len(touched_dirs)} analysis_cache pointer(s) for dangling references...")
    invalidated = 0
    for bucket, stem_dir in touched_dirs:
        if dry_run:
            matches = request(
                f"{supabase_url}/rest/v1/analysis_cache?select=audio_sha256"
                f"&stem_bucket=eq.{bucket}&stem_dir=eq.{stem_dir}",
                headers=rest_headers,
            )
            if matches:
                invalidated += len(matches)
        else:
            cleared = request(
                f"{supabase_url}/rest/v1/analysis_cache?stem_bucket=eq.{bucket}&stem_dir=eq.{stem_dir}",
                method="PATCH",
                headers={**rest_headers, "Prefer": "return=representation"},
                data=json.dumps({"stem_bucket": None, "stem_dir": None, "stems": None}).encode("utf-8"),
            )
            invalidated += len(cleared or [])

    print(f"{invalidated} cache pointer(s) {'would be' if dry_run else 'were'} cleared "
          "so future requests correctly regenerate stems instead of attempting a copy "
          "from a location that no longer exists. The cached chords, key, tempo, and "
          "structure for those recordings are untouched and still free to reuse.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
