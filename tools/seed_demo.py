"""Fills the project with seeded accounts, songs and audio, so the app can be
looked at with a crowd in it.

Almost everything built this week is invisible at four users. A feed ordered
towards people like you, a wildcard every fourth card, taste matching, a
musician list that rotates daily — none of it can be judged against 28 songs
and three other people. Neither can the failures that only appear at size: a
list that has to scroll, twelve URLs signed at once, a query with no index
behind it.

**Everything it makes is flagged and removable.** Accounts are created with
`is_demo`, which the app draws as a chip, and `purge_demo()` takes all of it
away again — including the storage objects, which are the part that would
otherwise be left behind paying rent forever. Run the purge before believing
any number about how the app is doing.

**The audio is generated, not borrowed.** ffmpeg builds a short chord
progression per clip: pitched, in a key, with a tempo, so the analysis
pipeline has something real to chew on and so a person testing the feed hears
music rather than silence. Nothing is downloaded and nothing is licensed,
which is the only version of this that is safe to run against a project that
publishes a takedown route.

Environment:
  SUPABASE_ACCESS_TOKEN      Management API token (repo secret)
  SUPABASE_PROJECT_REF       target project ref (repo secret)
  SUPABASE_SERVICE_ROLE_KEY  service role key, for auth admin and storage

Usage:
  python tools/seed_demo.py --people 60 --songs-each 3
  python tools/seed_demo.py --purge
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

# Long enough to hear it is music, short enough that a few hundred of them do
# not become a storage bill.
CLIP_SECONDS = 12
CLIP_POOL = 10

# The vocabulary the app actually filters on. Free text on one side and a
# different list here is how seeded data ends up matching nothing.
PARTS = [
    "vocal", "harmony", "lead", "rhythm", "bass", "drums", "keys", "percussion",
]

SOUNDS = [
    "singer-songwriter", "folk", "rock", "indie", "pop", "punk", "metal",
    "blues", "jazz", "soul", "r&b", "hip hop", "country", "americana",
    "bluegrass", "gospel", "worship", "electronic", "ambient", "house",
    "reggae", "afrobeats", "latin", "k-pop", "classical", "experimental",
]

CITIES = [
    "Glasgow", "Manchester", "Bristol", "Dublin", "Berlin", "Lisbon",
    "Nashville", "Austin", "Chicago", "Toronto", "Melbourne", "Auckland",
    "Cape Town", "Lagos", "Nairobi", "Mumbai", "Seoul", "Tokyo",
    "São Paulo", "Mexico City", "Stockholm", "Warsaw", "Athens", "Cairo",
]

FIRST = [
    "Mara", "Dev", "Ines", "Kofi", "Rosa", "Liam", "Noor", "Tomas", "Aiko",
    "Sana", "Ravi", "Elin", "Jonah", "Priya", "Otto", "Leila", "Marco",
    "Nina", "Cass", "Bo", "Yara", "Finn", "Zoe", "Ari", "Hana", "Luca",
]

LAST = [
    "Ellison", "Okonjo", "Варга", "Mercado", "Bennett", "Haruki", "Okafor",
    "Lindqvist", "Rossi", "Nakamura", "Duarte", "Abadi", "Kowalski",
    "Fontaine", "Silva", "Novak", "Ferreira", "Adeyemi", "Bright", "Marsh",
]

TITLES = [
    "Ladder Of Life", "Kitchen Window", "Slow Tide", "Paper Streets",
    "Blue Hour", "Nothing Rhymes", "Long Way Down", "Ordinary Weather",
    "Cold Fret", "Half A Chorus", "Every Other Sunday", "The Quiet Part",
    "Salt And Copper", "Hold The Line", "Backyard Fireworks", "Nine Of Cups",
    "Rain On The Amp", "Second Verse Problem", "Tuesday Again", "Low Ceiling",
    "Borrowed Capo", "The Last Bus", "Two Chords And Hope", "Static Bloom",
]

ASK_NOTES = [
    "Needs something simple under the chorus.",
    "Looking for a harmony on the last verse.",
    "The bridge is empty and I cannot hear what goes there.",
    "Anything that is not another guitar.",
    "It wants brushes rather than sticks, if that makes sense.",
    "",
]


def env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        print(f"FAIL: {name} is not set.")
        sys.exit(1)
    return value


def request(url: str, *, method="GET", headers=None, data=None, timeout=180):
    req = urllib.request.Request(url, data=data, method=method)
    # The Management API sits behind Cloudflare, which rejects urllib's
    # default agent outright before the request reaches Supabase.
    req.add_header("User-Agent", "colabroom-seed/1.0")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except urllib.error.URLError as error:
        return 0, str(error.reason)


def sql(project_ref: str, token: str, statement: str) -> list:
    status, body = request(
        f"https://api.supabase.com/v1/projects/{project_ref}/database/query",
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        data=json.dumps({"query": statement}).encode("utf-8"),
    )
    if status not in (200, 201):
        print(f"FAIL: SQL returned {status}\n{body[:1500]}")
        sys.exit(1)
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return []


def quote(text: str) -> str:
    """A single-quoted SQL literal. Doubling the quote is the whole escape."""
    return "'" + str(text).replace("'", "''") + "'"


def array_literal(values: list[str]) -> str:
    inner = ", ".join(quote(v) for v in values)
    return f"array[{inner}]::text[]" if values else "'{}'::text[]"


# ---------------------------------------------------------------------
# The audio
# ---------------------------------------------------------------------

def make_clip(path: Path, seed: int) -> None:
    """A short chord progression, so it sounds like music rather than a test.

    Three sine voices a third and a fifth apart, which is a triad, over a
    quiet noise bed so the analysis pipeline has some transient content to
    find a tempo in. The root moves per clip, so the pool is not ten copies
    of the same thing and a key detector has different answers to give.
    """
    root = 110.0 * (2 ** ((seed * 5 % 12) / 12.0))
    third = root * (2 ** (4 / 12.0))
    fifth = root * (2 ** (7 / 12.0))
    beat = 60.0 / (72 + (seed * 7) % 48)
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", f"sine=frequency={root:.2f}:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency={third:.2f}:duration={CLIP_SECONDS}",
            "-f", "lavfi", "-i", f"sine=frequency={fifth:.2f}:duration={CLIP_SECONDS}",
            "-f", "lavfi",
            "-i", f"anoisesrc=duration={CLIP_SECONDS}:color=pink:amplitude=0.06",
            "-filter_complex",
            # A tremolo at the tempo gives it a pulse to track.
            f"amix=inputs=4:duration=longest,tremolo=f={1/beat:.2f}:d=0.6,volume=1.6",
            "-ar", "44100", "-ac", "1", "-b:a", "64k",
            str(path),
        ],
        check=True,
        capture_output=True,
    )


def storage_key(project_ref: str, token: str, configured: str) -> str:
    """The key the Storage API will actually accept.

    Storage authenticates with a JWT and says so plainly when handed anything
    else: "Invalid Compact JWS", which is a JSON Web Signature parser
    complaining, not a permissions problem. Supabase's newer `sb_secret_…`
    keys work against the auth admin endpoint and PostgREST and are refused
    here — so this tool created seventy-five accounts and then could not
    upload a single file, twice.

    The Management API can hand over the project's legacy service_role JWT,
    and this already holds a token for it. Asking is better than requiring
    somebody to find and paste a second secret, and better than failing three
    hundred uploads to discover the first one was the wrong shape.
    """
    if configured.count(".") == 2:
        # Already a JWT: header.payload.signature.
        return configured

    status, body = request(
        f"https://api.supabase.com/v1/projects/{project_ref}/api-keys?reveal=true",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
    )
    if status == 200:
        for key in json.loads(body):
            if key.get("name") == "service_role" and key.get("api_key"):
                print("  using the project's service_role JWT for storage")
                return key["api_key"]

    print(
        "WARNING: SUPABASE_SERVICE_ROLE_KEY is not a JWT and the Management "
        "API would not reveal one.\n         Storage uploads will be refused."
    )
    return configured


def sweep(project_ref: str, service_key: str, bucket: str, prefix: str) -> int:
    """Deletes everything under a prefix, through the Storage API.

    SQL cannot do this: Supabase guards `storage.objects` with a trigger that
    raises 42501 and tells you to use the API. Two functions shipped with a
    direct delete in them and neither could ever have run.

    Listing is needed first because the delete endpoint takes names, not a
    prefix — and it pages, so a room with more than a hundred files needs
    more than one pass.
    """
    removed = 0
    headers = {
        "Authorization": f"Bearer {service_key}",
        "apikey": service_key,
        "Content-Type": "application/json",
    }
    folder = prefix.rstrip("/")
    while True:
        status, body = request(
            f"https://{project_ref}.supabase.co/storage/v1/object/list/{bucket}",
            method="POST",
            headers=headers,
            data=json.dumps({
                "prefix": folder,
                "limit": 100,
                "offset": 0,
            }).encode("utf-8"),
        )
        if status != 200:
            print(f"  list failed ({status}) for {bucket}/{folder}: {body[:200]}")
            return removed
        entries = json.loads(body)
        # The API lists one level at a time. An entry with no id is a folder,
        # so recurse into it rather than trying to delete a name that is not
        # an object.
        names, folders = [], []
        for entry in entries:
            if entry.get("id"):
                names.append(f"{folder}/{entry['name']}")
            else:
                folders.append(f"{folder}/{entry['name']}")
        for child in folders:
            removed += sweep(project_ref, service_key, bucket, child + "/")
        if not names:
            return removed
        status, body = request(
            f"https://{project_ref}.supabase.co/storage/v1/object/{bucket}",
            method="DELETE",
            headers=headers,
            data=json.dumps({"prefixes": names}).encode("utf-8"),
        )
        if status != 200:
            print(f"  delete failed ({status}) for {bucket}: {body[:200]}")
            return removed
        removed += len(names)
        if len(entries) < 100:
            return removed


def upload(project_ref: str, service_key: str, bucket: str, path: str,
           body: bytes, content_type: str) -> bool:
    status, text = request(
        f"https://{project_ref}.supabase.co/storage/v1/object/{bucket}/{path}",
        method="POST",
        headers={
            "Authorization": f"Bearer {service_key}",
            "Content-Type": content_type,
            "x-upsert": "true",
        },
        data=body,
        timeout=120,
    )
    if status not in (200, 201):
        print(f"  upload failed ({status}) for {path}: {text[:200]}")
        return False
    return True


# ---------------------------------------------------------------------
# The people
# ---------------------------------------------------------------------

def make_account(project_ref: str, service_key: str, email: str,
                 display_name: str) -> str | None:
    """Through the auth admin API rather than an insert into auth.users.

    That table has columns and defaults this script has no business knowing
    about, and they change. The admin endpoint is the supported door and
    fires the same on_auth_user_created trigger that makes the profile.
    """
    status, body = request(
        f"https://{project_ref}.supabase.co/auth/v1/admin/users",
        method="POST",
        headers={
            "Authorization": f"Bearer {service_key}",
            "apikey": service_key,
            "Content-Type": "application/json",
        },
        data=json.dumps({
            "email": email,
            "password": uuid.uuid4().hex + "aA1!",
            "email_confirm": True,
            "user_metadata": {"display_name": display_name},
        }).encode("utf-8"),
    )
    if status not in (200, 201):
        print(f"  account failed ({status}) for {email}: {body[:200]}")
        return None
    return json.loads(body)["id"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--people", type=int, default=40)
    parser.add_argument("--songs-each", type=int, default=3)
    parser.add_argument("--open-mic", type=float, default=0.6,
                        help="share of songs put on the Open Mic")
    parser.add_argument("--purge", action="store_true",
                        help="remove every seeded account and stop")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    token = env("SUPABASE_ACCESS_TOKEN")
    project_ref = env("SUPABASE_PROJECT_REF")
    admin_key = env("SUPABASE_SERVICE_ROLE_KEY")
    # Auth admin takes either shape; storage insists on a JWT. Resolved once,
    # up front, rather than discovered three hundred uploads in.
    service_key = storage_key(project_ref, token, admin_key)

    if args.purge:
        # Files first, and through the API, because SQL is not allowed to
        # delete a stored object — and because once the rooms are gone
        # nothing names the objects any more. Bytes nothing points at are
        # bytes nobody finds again, still being paid for every month.
        print("Sweeping seeded files…")
        prefixes = sql(project_ref, token,
                       "select * from public.purge_demo_paths();")
        swept = 0
        for row in prefixes:
            swept += sweep(project_ref, service_key, row["bucket"],
                           row["prefix"])
        print(f"  {swept} files")

        print("Purging every seeded account…")
        for row in sql(project_ref, token, "select * from public.purge_demo();"):
            print(f"  {row['what']:<18} {row['removed']}")
        return 0

    random.seed(args.seed)
    rng = random.Random(args.seed)

    # ---- audio pool ----
    print(f"Generating {CLIP_POOL} clips…")
    work = Path(tempfile.mkdtemp(prefix="colabroom-demo-"))
    clips: list[bytes] = []
    for index in range(CLIP_POOL):
        clip = work / f"clip{index}.m4a"
        try:
            make_clip(clip, index)
        except FileNotFoundError:
            print("FAIL: ffmpeg is not on PATH.")
            return 1
        except subprocess.CalledProcessError as error:
            print(f"FAIL: ffmpeg: {error.stderr.decode('utf-8', 'replace')[:400]}")
            return 1
        clips.append(clip.read_bytes())
    print(f"  {sum(len(c) for c in clips) // 1024} KB total")

    # ---- accounts ----
    print(f"Creating {args.people} accounts…")
    people: list[dict] = []
    run = uuid.uuid4().hex[:8]
    for index in range(args.people):
        name = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
        email = f"demo+{run}-{index}@colabroom.invalid"
        user_id = make_account(project_ref, admin_key, email, name)
        if user_id is None:
            continue
        people.append({
            "id": user_id,
            "name": name,
            "plays": rng.sample(PARTS, rng.randint(1, 3)),
            "sounds": rng.sample(SOUNDS, rng.randint(1, 4)),
            "city": rng.choice(CITIES),
        })
        if (index + 1) % 10 == 0:
            print(f"  {index + 1}/{args.people}")

    if not people:
        print("FAIL: no accounts were created.")
        return 1

    # ---- profiles, rooms, songs ----
    print("Writing profiles, rooms and songs…")
    rows = ",\n".join(
        f"({quote(p['id'])}::uuid, {quote(p['name'])}, "
        f"{array_literal(p['plays'])}, {array_literal(p['sounds'])}, "
        f"{quote(p['city'])})"
        for p in people
    )
    sql(project_ref, token, f"""
update public.profiles p
set is_demo = true,
    display_name = v.name,
    plays = v.plays,
    sounds_like = v.sounds,
    city = v.city,
    location_visibility = 'public',
    discoverable = true
from (values
{rows}
) as v(id, name, plays, sounds, city)
where p.id = v.id;
""")

    songs: list[dict] = []
    room_values, member_values, project_values = [], [], []
    for person in people:
        room_id = str(uuid.uuid4())
        room_values.append(
            f"({quote(room_id)}::uuid, {quote(person['id'])}::uuid, "
            f"{quote(person['name'].split()[0] + chr(39) + 's Room')}, "
            f"{quote(rng.choice(['🎸', '🥁', '🎹', '🎤', '♪', '🎧']))})"
        )
        member_values.append(
            f"({quote(room_id)}::uuid, {quote(person['id'])}::uuid, "
            f"{quote(person['name'])}, 'owner')"
        )
        # Distinct per person, because `projects_account_title_unique` is a
        # real constraint: nobody may have two songs with the same name. Four
        # draws from a list of twenty-four collide often enough that the first
        # run at seventy-five accounts died on it.
        picks = rng.sample(TITLES, min(args.songs_each, len(TITLES)))
        # Past the end of the list, walk it again with a number on. Picking
        # randomly here can collide with itself — a first attempt at this did,
        # and only a check that the whole list is distinct found it.
        round_number = 2
        while len(picks) < args.songs_each:
            for base in TITLES:
                if len(picks) >= args.songs_each:
                    break
                picks.append(f"{base} ({round_number})")
            round_number += 1
        for index in range(args.songs_each):
            project_id = str(uuid.uuid4())
            title = picks[index]
            project_values.append(
                f"({quote(project_id)}::uuid, {quote(room_id)}::uuid, "
                f"{quote(person['id'])}::uuid, {quote(title)})"
            )
            songs.append({
                "id": project_id,
                "room": room_id,
                "owner": person["id"],
                "title": title,
                "clip": rng.randrange(CLIP_POOL),
                "up": rng.random() < args.open_mic,
                "part": rng.choice(PARTS),
                "note": rng.choice(ASK_NOTES),
            })

    sql(project_ref, token, f"""
insert into public.rooms (id, account_id, name, icon)
values
{",".join(room_values)}
on conflict (id) do nothing;

insert into public.room_members (room_id, user_id, display_name, role)
values
{",".join(member_values)}
on conflict (room_id, user_id) do nothing;

insert into public.projects (id, room_id, account_id, created_by, title)
select v.id, v.room, v.owner, v.owner, v.title
from (values
{",".join(project_values)}
) as v(id, room, owner, title)
on conflict (id) do nothing;
""")

    # ---- audio, then the takes that point at it ----
    print(f"Uploading {len(songs)} clips…")
    layer_values = []
    failed = 0
    for index, song in enumerate(songs):
        path = f"{song['room']}/{song['id']}/layers/{uuid.uuid4()}.m4a"
        if not upload(project_ref, service_key, "room-files", path,
                      clips[song["clip"]], "audio/mp4"):
            failed += 1
            # Report a few, then stop shouting. The exit below is the part
            # that matters.
            if failed > 3:
                print(f"  … and {len(songs) - index - 1} more not attempted")
                break
            continue
        layer_values.append(
            f"({quote(song['id'])}::uuid, {quote(song['owner'])}::uuid, "
            f"{quote(path)}, 'Take 1', 'vocal', {CLIP_SECONDS * 1000}, now())"
        )
        if (index + 1) % 25 == 0:
            print(f"  {index + 1}/{len(songs)}")

    # Loudly, and before anything else is written.
    #
    # The first run of this tool uploaded nothing — every request refused —
    # and then printed "Done. 10 people, 20 songs, 11 on the Open Mic". All
    # three numbers were true and the feed was empty, because a song with no
    # audio is filtered out of it. A seeding tool that reports success while
    # producing a silent room is worse than one that fails.
    if failed:
        print(
            f"\nFAIL: {failed} uploads were refused, so those songs would "
            "have no audio and would never reach the feed."
        )
        print("Nothing further was written. Remove the partial seed with:")
        print("  python tools/seed_demo.py --purge")
        return 1

    if layer_values:
        sql(project_ref, token, f"""
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
{",".join(layer_values)};
""")

    # ---- the Open Mic ----
    up = [s for s in songs if s["up"]]
    if up:
        print(f"Putting {len(up)} songs on the Open Mic…")
        ask_values = ",".join(
            f"({quote(s['id'])}::uuid, {quote(s['owner'])}::uuid, "
            f"{quote(s['part'])}, {quote(s['note'])}, 'open')"
            for s in up
        )
        sql(project_ref, token, f"""
update public.projects
set open_mic_at = now() - (random() * interval '30 days')
where id in ({",".join(quote(s['id']) + '::uuid' for s in up)});

insert into public.project_asks
  (project_id, asked_by, part, note, status)
values
{ask_values};
""")

    counts = sql(project_ref, token, """
select
  (select count(*) from public.profiles where is_demo) as people,
  (select count(*) from public.projects p
     join public.rooms r on r.id = p.room_id
     join public.profiles pr on pr.id = r.account_id
    where pr.is_demo) as songs,
  (select count(*) from public.projects p
     join public.rooms r on r.id = p.room_id
     join public.profiles pr on pr.id = r.account_id
    where pr.is_demo and p.open_mic_at is not null) as on_open_mic;
""")
    if counts:
        row = counts[0]
        print(
            f"\nDone. {row['people']} people, {row['songs']} songs, "
            f"{row['on_open_mic']} on the Open Mic."
        )
    # The only number that proves any of it worked.
    #
    # open_mic_feed drops every song with nothing to play, so it is the one
    # query that comes back wrong when the audio did not land — which is
    # exactly how this tool went wrong the first time it ran.
    feed = sql(project_ref, token,
               "select count(*) as found from public.open_mic_feed(24, null);")
    reachable = feed[0]["found"] if feed else 0
    print(f"The feed returns {reachable} songs.")
    if reachable == 0:
        print("FAIL: the feed is empty, so nothing seeded is actually audible.")
        return 1

    print("Remove it all with:  python tools/seed_demo.py --purge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
