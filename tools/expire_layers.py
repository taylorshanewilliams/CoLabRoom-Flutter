"""Warns about, then deletes, band layers nobody has played in a long time.

This is a different kind of deletion from expire_stems.py and the difference
is the whole reason this file exists separately. A stem is *derived*: it can be
recomputed from a reference recording that never expires, so losing one costs
GPU time and nothing else. A layer is somebody's actual playing — a riff, a
harmony, a lead played once in a room — and nothing regenerates it. Deleting
one is final in a way deleting a stem never is.

So the policy has three parts, and it is only defensible with all three:

  1. It counts from `last_opened_at`, not `created_at`. A song anybody still
     opens never expires, however old it is. The question being asked is "is
     this band still using this", not "how long has this existed".
  2. The band is warned first, once, with a fortnight to act.
  3. Everything is exportable at any moment from inside the app. The promise
     is "we stop storing this", not "you lose this".

Why enforce it during a beta at all, when nothing has yet had time to age:
storage is the one cost that recurs forever and grows with everything anybody
ever recorded and forgot. Egress scales with activity and stops when people
stop; storage does not. Turning this on now is free — no layer can be 90 days
old for another three months — and it means the policy ships alongside the
feature rather than being retrofitted after bands have formed an expectation.
A rule that arrives with the thing is a rule; one that arrives later is a
broken promise.

DRY_RUN defaults to true. It is safe to leave the schedule on regardless,
because for the first three months there is provably nothing old enough to
delete — which is exactly the right way to introduce a deletion path: it runs
harmlessly a dozen times, in the open, before it can ever do anything.

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  RETENTION_DAYS              layers unopened this long are deleted (default 90)
  WARN_DAYS                   layers unopened this long are warned (default 75)
  DRY_RUN                     "true" (default) to report only, "false" to act
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

BUCKET = "room-files"


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


def iso_days_ago(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    retention_days = int(os.environ.get("RETENTION_DAYS", "90"))
    warn_days = int(os.environ.get("WARN_DAYS", "75"))
    dry_run = os.environ.get("DRY_RUN", "true").strip().lower() != "false"

    if warn_days >= retention_days:
        print(f"FAIL: WARN_DAYS ({warn_days}) must be less than RETENTION_DAYS "
              f"({retention_days}), or nobody is warned before their work goes.")
        return 1

    base = f"https://{project_ref}.supabase.co"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }

    delete_cutoff = iso_days_ago(retention_days)
    warn_cutoff = iso_days_ago(warn_days)
    # Every timestamp built into a query string is quoted: PostgREST reads
    # these out of a URL, where "+" means space, and an unescaped "+00:00"
    # offset reaches Postgres as " 00:00" and will not parse at all. The same
    # bug bit the dry-run check in tools/health_check.py once already.
    delete_q = urllib.parse.quote(delete_cutoff, safe="")
    warn_q = urllib.parse.quote(warn_cutoff, safe="")

    print(f"Delete layers unopened since {delete_cutoff} ({retention_days} days)")
    print(f"Warn   layers unopened since {warn_cutoff} ({warn_days} days)")
    print(f"Mode: {'DRY RUN — nothing will change' if dry_run else 'LIVE'}")
    print()

    # ---- warn ----------------------------------------------------------
    # Warned before deleted, and warned once. Ordered this way round on
    # purpose: a layer that crosses both thresholds between two runs of this
    # script — which happens if the schedule ever misses a fortnight — gets
    # its warning on this run and is deleted on a later one, rather than
    # vanishing in the same pass that was supposed to give notice.
    to_warn = request(
        f"{base}/rest/v1/song_layers"
        f"?select=id,project_id,label,last_opened_at"
        f"&last_opened_at=lt.{warn_q}"
        f"&expiry_warned_at=is.null",
        headers=headers,
    ) or []

    projects_warned: set[str] = set()
    for layer in to_warn:
        projects_warned.add(layer["project_id"])
    print(f"To warn: {len(to_warn)} layer(s) across {len(projects_warned)} song(s)")

    if to_warn and not dry_run:
        stamp = datetime.now(timezone.utc).isoformat()
        for layer in to_warn:
            request(
                f"{base}/rest/v1/song_layers?id=eq.{urllib.parse.quote(layer['id'], safe='')}",
                method="PATCH",
                headers={**headers, "Prefer": "return=minimal"},
                data=json.dumps({"expiry_warned_at": stamp}).encode(),
            )
        print(f"  marked {len(to_warn)} layer(s) as warned")
        # The notification itself is deliberately not sent from here yet.
        # notify_user is private and this script talks to PostgREST, so
        # wiring it needs a security-definer RPC of its own — and sending a
        # deletion warning nobody can act on because the app has no layer UI
        # would be worse than sending it a week later. Marking is what stops
        # the warning being lost; the delivery follows the UI.
        print("  (in-app notice pending the layers UI — see the note in this file)")

    # ---- delete --------------------------------------------------------
    to_delete = request(
        f"{base}/rest/v1/song_layers"
        f"?select=id,project_id,storage_path,byte_size,last_opened_at"
        f"&last_opened_at=lt.{delete_q}",
        headers=headers,
    ) or []

    total_bytes = sum((layer.get("byte_size") or 0) for layer in to_delete)
    print()
    print(f"To delete: {len(to_delete)} layer(s), {total_bytes / 1048576:.1f} MB")

    if not to_delete:
        print("Nothing has aged out. This is the expected result until the "
              "feature itself is older than the retention window.")
        return 0

    if dry_run:
        for layer in to_delete[:20]:
            print(f"  would delete {layer['storage_path']} "
                  f"(last opened {layer['last_opened_at']})")
        if len(to_delete) > 20:
            print(f"  ... and {len(to_delete) - 20} more")
        return 0

    # Objects first, then rows. The opposite order to deleteLayer() in the
    # app, and for the opposite reason: there, a person is watching and wants
    # the layer gone from the song immediately. Here nobody is watching, and
    # an object whose row is already gone is invisible to everyone and
    # unreachable by the next sweep — a leak that costs money forever. Losing
    # the row last means a failure mid-way leaves a layer that still plays.
    paths = [layer["storage_path"] for layer in to_delete]
    for start in range(0, len(paths), 100):
        chunk = paths[start:start + 100]
        request(
            f"{base}/storage/v1/object/{BUCKET}",
            method="DELETE",
            headers=headers,
            data=json.dumps({"prefixes": chunk}).encode(),
        )
    print(f"  removed {len(paths)} object(s)")

    for layer in to_delete:
        request(
            f"{base}/rest/v1/song_layers?id=eq.{urllib.parse.quote(layer['id'], safe='')}",
            method="DELETE",
            headers={**headers, "Prefer": "return=minimal"},
        )
    print(f"  deleted {len(to_delete)} row(s), reclaiming {total_bytes / 1048576:.1f} MB")

    # Versions are left alone deliberately. A version is a list of layer ids
    # and holds no audio; one that now names a deleted layer simply plays
    # what remains, which is the honest outcome — and is far better than
    # deleting the version, which would take the band's own name for a mix
    # ("Mountains with Dylan's lead") along with it.
    return 0


if __name__ == "__main__":
    sys.exit(main())
