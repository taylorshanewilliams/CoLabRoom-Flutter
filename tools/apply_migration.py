"""Applies one migration file to the Supabase project, in a transaction.

Deliberately not `supabase db push`. That command applies everything the
`supabase_migrations.schema_migrations` table doesn't list as applied — and
this project's migrations have been run by hand through the dashboard SQL
editor, so that table doesn't reflect reality. Pointing `db push` at it would
try to replay the schema from 0001 and fail on the first object that already
exists. Naming one file explicitly matches how this project is actually
migrated, minus the copy-paste.

The whole file runs inside a single transaction: it either applies completely
or changes nothing. There is no half-applied outcome to clean up.

Environment:
  SUPABASE_ACCESS_TOKEN   Supabase Management API token (already a repo secret)
  SUPABASE_PROJECT_REF    target project ref (already a repo secret)
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / "supabase" / "migrations"


def run_sql(project_ref: str, token: str, sql: str) -> tuple[bool, str]:
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{project_ref}/database/query",
        data=json.dumps({"query": sql}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return True, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return False, f"HTTP {error.code}: {error.read().decode('utf-8', errors='replace')}"
    except urllib.error.URLError as error:
        return False, f"Could not reach the Supabase Management API: {error.reason}"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply_migration.py <migration-filename>")
        return 2

    name = sys.argv[1].strip()
    path = MIGRATIONS_DIR / name
    if not path.is_file():
        print(f"No such migration: {name}")
        print("Available:")
        for candidate in sorted(MIGRATIONS_DIR.glob("*.sql")):
            print(f"  {candidate.name}")
        return 1

    token = (os.environ.get("SUPABASE_ACCESS_TOKEN") or "").strip()
    project_ref = (os.environ.get("SUPABASE_PROJECT_REF") or "").strip()
    if not token or not project_ref:
        print("SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF must both be set.")
        return 1

    sql = path.read_text(encoding="utf-8")
    print(f"Applying {name} to project {project_ref} ({len(sql)} chars), in a transaction…")

    ok, body = run_sql(project_ref, token, f"begin;\n{sql}\ncommit;")
    if ok:
        print(f"✓ {name} applied.")
        if body.strip() and body.strip() != "[]":
            print(body[:2000])
        return 0

    print(f"✗ {name} was NOT applied. The transaction rolled back; nothing changed.")
    print(body[:4000])
    # "already exists" is the expected shape when a migration was applied by
    # hand earlier — worth naming so it doesn't read as a real failure.
    if "already exists" in body:
        print(
            "\nThis looks like it was already applied. Nothing to do — "
            "verify in the dashboard's Table Editor and move on."
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
