"""Reads the crash-free rate, and fails loudly when it drops.

A number nobody looks at is not a metric, it is a column. This runs daily,
prints the rate per app version, and exits non-zero when it falls below the
floor — which turns a silent regression into a failed workflow, an email, and
a red mark next to the day it started.

That is deliberately the crudest possible alerting. It uses machinery this
project already has rather than adding a service, and the failure it produces
is impossible to miss without being possible to ignore either.

Also prunes old sessions. Sessions are the one table that grows with use
rather than with work — one row per launch per person, which is nothing today
and the largest table in the database within a month of any real growth.

Environment:
  SUPABASE_ACCESS_TOKEN   Supabase Management API token
  SUPABASE_PROJECT_REF    target project ref
  CRASH_FREE_FLOOR        percentage below which this fails (default 99.0)
  SESSION_KEEP_DAYS       how much session history to keep (default 90)
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def run_sql(project_ref: str, token: str, sql: str) -> tuple[bool, object]:
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{project_ref}/database/query",
        data=json.dumps({"query": sql}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "colabroom-crash-free/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return True, json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as error:
        return False, f"HTTP {error.code}: {error.read().decode('utf-8', errors='replace')}"
    except urllib.error.URLError as error:
        return False, f"Could not reach the Supabase Management API: {error.reason}"


def main() -> int:
    token = (os.environ.get("SUPABASE_ACCESS_TOKEN") or "").strip()
    project_ref = (os.environ.get("SUPABASE_PROJECT_REF") or "").strip()
    if not token or not project_ref:
        print("SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF must both be set.")
        return 1

    floor = float(os.environ.get("CRASH_FREE_FLOOR") or 99.0)
    keep_days = int(os.environ.get("SESSION_KEEP_DAYS") or 90)

    ok, rows = run_sql(project_ref, token, "select * from public.crash_free_rate(7);")
    if not ok:
        print(f"Could not read the rate: {rows}")
        return 1

    if not rows:
        # Not a failure. Before a build carrying sessions reaches a phone there
        # is genuinely nothing to measure, and failing here every day until
        # then would teach everybody to ignore this workflow — which is the
        # only way an alert can actually break.
        print("No sessions in the last 7 days. Nothing to report yet.")
        return 0

    print(f"Crash-free rate, last 7 days (floor {floor}%):\n")
    worst = 100.0
    total_sessions = 0
    for row in rows:
        version = row.get("app_version") or "unknown"
        sessions = int(row.get("sessions") or 0)
        bad = int(row.get("sessions_with_an_error") or 0)
        rate = float(row.get("crash_free_percent") or 0)
        total_sessions += sessions
        print(f"  {version:<12} {rate:>6.2f}%   {sessions} sessions, {bad} with an error")
        # Versions with almost no traffic swing wildly — one crash in three
        # launches is 66%, and gating on that would page somebody about a
        # developer's own phone. Only versions with real usage set the floor.
        if sessions >= 20:
            worst = min(worst, rate)

    pruned_ok, pruned = run_sql(
        project_ref, token, f"select public.prune_app_sessions({keep_days});"
    )
    if pruned_ok and isinstance(pruned, list) and pruned:
        removed = list(pruned[0].values())[0]
        print(f"\nPruned {removed} sessions older than {keep_days} days.")

    if total_sessions < 20:
        print(f"\nOnly {total_sessions} sessions — too few to judge. Not failing.")
        return 0

    if worst < floor:
        print(f"\n::error::Crash-free rate {worst:.2f}% is below the {floor}% floor.")
        return 1

    print(f"\nWorst version with real usage: {worst:.2f}%. Above the floor.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
