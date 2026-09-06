"""Points the database at the deployed push sender, from the deploy itself.

private.push_config holds two values: where to send a notification, and the
secret that proves the request came from us. Both were originally set by hand
in the SQL editor, with the secret copied out of GitHub — and a secret that a
person has to paste into two places is a secret that ends up matching in
neither. That failed three times in a row before this file existed: once with
the placeholder text, and twice with the text of the command that was supposed
to generate the value.

So neither value is typed anywhere now. The URL is derived from the project
ref the deploy is already using, and the secret is the same environment
variable the Edge Function was just given. There is exactly one source of
truth for it — the repository secret — and nothing downstream can disagree
with it, because nothing downstream is asked to repeat it.

Environment:
  SUPABASE_ACCESS_TOKEN   Supabase Management API token
  SUPABASE_PROJECT_REF    target project ref
  PUSH_HOOK_SECRET        the shared secret, byte-for-byte as the function has it
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
            # Cloudflare rejects urllib's default agent outright, before the
            # request reaches Supabase. Same note as apply_migration.py.
            "User-Agent": "colabroom-push-config/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return True, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return False, f"HTTP {error.code}: {error.read().decode('utf-8', errors='replace')}"
    except urllib.error.URLError as error:
        return False, f"Could not reach the Supabase Management API: {error.reason}"


def main() -> int:
    token = (os.environ.get("SUPABASE_ACCESS_TOKEN") or "").strip()
    project_ref = (os.environ.get("SUPABASE_PROJECT_REF") or "").strip()
    # Not stripped. Whatever the function was given is what has to be stored,
    # trailing whitespace and all — trimming one side of a comparison and not
    # the other is precisely how a secret comes to "match" everywhere a human
    # looks and fail every time a machine checks.
    secret = os.environ.get("PUSH_HOOK_SECRET") or ""

    if not token or not project_ref:
        print("SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF must both be set.")
        return 1
    if not secret:
        print("PUSH_HOOK_SECRET is empty; refusing to store a blank secret.")
        return 1

    function_url = f"https://{project_ref}.supabase.co/functions/v1/send-push"

    # Doubling single quotes is the whole of SQL string escaping here, and the
    # Management API takes a statement rather than parameters, so there is no
    # placeholder to bind to. The generated secret is alphanumeric, but a
    # future one pasted by hand might not be.
    escaped = secret.replace("'", "''")

    sql = (
        "insert into private.push_config (id, function_url, hook_secret)\n"
        f"values (true, '{function_url}', '{escaped}')\n"
        "on conflict (id) do update\n"
        "set function_url = excluded.function_url,\n"
        "    hook_secret = excluded.hook_secret;"
    )

    print(f"Pointing the database at {function_url}")
    print(f"Storing a {len(secret)}-character shared secret.")

    ok, body = run_sql(project_ref, token, sql)
    if ok:
        print("✓ push_config is set. Notifications will now be delivered.")
        return 0

    # Deliberately not printing the statement on failure: it carries the
    # secret, and a workflow log is the last place that should end up.
    print("✗ push_config was NOT set.")
    print(body[:2000])
    return 1


if __name__ == "__main__":
    sys.exit(main())
