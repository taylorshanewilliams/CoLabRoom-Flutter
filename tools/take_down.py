"""Removes a reported image, completely.

`take_down_image()` does the half SQL is allowed to do: it clears the column
the app reads and closes the report. It cannot delete the stored object —
Supabase guards `storage.objects` with a trigger that raises 42501 and says
to use the Storage API — so it hands back the bucket and path instead.

**That half is not a takedown.** Clearing `avatar_path` stops the app drawing
the picture, but `avatars_read_authenticated` lets any signed-in account read
any path in that bucket, so somebody holding the old path could still fetch
it. The object has to actually go, and only the API can do that. This is the
script that finishes the job.

Usage:
  python tools/take_down.py <report-id> ["a note for the record"]

Environment:
  SUPABASE_ACCESS_TOKEN      Management API token
  SUPABASE_PROJECT_REF       target project ref
  SUPABASE_SERVICE_ROLE_KEY  service role key, for the Storage API
"""

from __future__ import annotations

import json
import sys

from seed_demo import env, quote, request, sql


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    report_id = sys.argv[1].strip()
    note = sys.argv[2] if len(sys.argv) > 2 else ""

    token = env("SUPABASE_ACCESS_TOKEN")
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")

    rows = sql(project_ref, token,
               f"select * from public.take_down_image({quote(report_id)}::uuid, "
               f"{quote(note)});")
    if not rows:
        print("FAIL: the takedown returned nothing.")
        return 1

    row = rows[0]
    print(f"Cleared the {row['what']} and closed the report.")

    path = row.get("cleared_path")
    if not path:
        print("There was no image on it. Nothing to delete.")
        return 0

    bucket = row["bucket"]
    print(f"Deleting {bucket}/{path} …")
    status, body = request(
        f"https://{project_ref}.supabase.co/storage/v1/object/{bucket}",
        method="DELETE",
        headers={
            "Authorization": f"Bearer {service_key}",
            "apikey": service_key,
            "Content-Type": "application/json",
        },
        data=json.dumps({"prefixes": [path]}).encode("utf-8"),
    )
    if status != 200:
        print(f"FAIL: storage returned {status}: {body[:400]}")
        print("The app no longer shows it, but the object is still fetchable")
        print("by anybody who knows the path. Delete it from the dashboard.")
        return 1

    print("Gone.")
    # Said out loud because it is the difference between a takedown and a
    # legal obligation met: the object is unreachable through the API from
    # this moment, and the bytes behind it are Supabase's to reclaim.
    print(
        "\nIf this was reported as illegal content rather than merely "
        "unwanted,\npreserve what you must and file with NCMEC before "
        "closing the matter."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
