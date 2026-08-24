"""Runs one read-only SQL query against the Supabase project and prints it.

The gap this closes: there has been no way to ask production a question. Every
bug that only reproduces against real data — an invite that says the invitee
has no account when he plainly does — has had to be reasoned about from the
source alone, which is how you end up fixing the wrong thing confidently.

Read-only is enforced by Postgres, not by inspecting the query text. The
statement runs inside a transaction that has been marked READ ONLY, so any
write — including one hidden inside a SECURITY DEFINER function — fails and
rolls the whole thing back. Keyword blocklists are theatre by comparison.

Results land in the workflow log, so queries should return facts rather than
personal data: counts, booleans, masked identifiers. See the invite
diagnostics in .github/workflows/run-query.yml for the shape.

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


def run_sql(project_ref: str, token: str, sql: str) -> tuple[bool, str]:
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{project_ref}/database/query",
        data=json.dumps({"query": sql}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            # Cloudflare rejects urllib's default agent outright with a 403
            # before the request reaches Supabase — see apply_migration.py.
            "User-Agent": "colabroom-query-runner/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return True, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return False, f"HTTP {error.code}: {error.read().decode('utf-8', errors='replace')}"
    except urllib.error.URLError as error:
        return False, f"Could not reach the Supabase Management API: {error.reason}"


def main() -> int:
    query = (sys.stdin.read() if len(sys.argv) < 2 else sys.argv[1]).strip()
    if not query:
        print("usage: run_query.py '<sql>'   (or pipe the SQL on stdin)")
        return 2

    token = (os.environ.get("SUPABASE_ACCESS_TOKEN") or "").strip()
    project_ref = (os.environ.get("SUPABASE_PROJECT_REF") or "").strip()
    if not token or not project_ref:
        print("SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF must both be set.")
        return 1

    # A hand-typed query rarely ends in a semicolon, and without one the
    # trailing commit lands on the same statement — so Postgres rejects the
    # whole thing with a syntax error pointing at the wrapper rather than at
    # anything the caller wrote.
    statement = query if query.endswith(";") else query + ";"
    wrapped = f"begin;\nset transaction read only;\n{statement}\ncommit;"
    ok, body = run_sql(project_ref, token, wrapped)
    if not ok:
        print("Query failed (nothing was changed — the transaction rolled back).")
        print(body[:4000])
        return 1

    try:
        rows = json.loads(body)
    except json.JSONDecodeError:
        print(body[:4000])
        return 0

    if not isinstance(rows, list) or not rows:
        print("(no rows)")
        return 0

    for index, row in enumerate(rows, start=1):
        print(f"--- row {index} ---")
        if isinstance(row, dict):
            width = max((len(str(key)) for key in row), default=0)
            for key, value in row.items():
                print(f"  {str(key).ljust(width)}  {value}")
        else:
            print(f"  {row}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
