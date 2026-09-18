"""The retention sweep keeps what the plan says it keeps.

Run by CI (verify.yml, python-services) with unittest and nothing else.
There is no Postgres here, so these test the deciding, not the fetching:
expire_layers.decide is the one place the two passes are chosen, and the
exemptions are plain functions over rows.
"""

from __future__ import annotations

import unittest
import urllib.parse
from datetime import datetime, timedelta, timezone
from unittest import mock

import expire_layers as sweep

MARCH = "2026-03-01T10:00:00+00:00"
APRIL = "2026-04-01T10:00:00+00:00"
MAY = "2026-05-01T10:00:00+00:00"


def layer(
    layer_id: str,
    *,
    song: str = "song-1",
    who: str = "jess",
    part: str | None = "lead",
    created: str = MARCH,
    shared: str | None = None,
    sealed_until: str | None = None,
) -> dict:
    """A song_layers row as PostgREST hands it back, with the fields the sweep reads."""
    return {
        "id": layer_id,
        "project_id": song,
        "recorded_by": who,
        "part": part,
        "created_at": created,
        "shared_at": shared,
        "sealed_until": sealed_until,
        "last_opened_at": "2026-03-02T00:00:00+00:00",
        "label": layer_id,
        "storage_path": f"room/{song}/layers/{layer_id}.m4a",
        "byte_size": 1000,
    }


def ids(layers) -> list[str]:
    return [one["id"] for one in layers]


class CappedPostgrest:
    """A stand-in for request() that answers song_layers reads the way
    PostgREST does with max-rows set: never more than [cap] rows, however
    many were asked for, and nothing to say that it stopped short.

    Understands the parts of the query the sweep writes: project_id=in.(...),
    id=gt.<cursor>, order=id.asc and limit=. Counts the requests, so a test
    can tell that paging happened at all.
    """

    def __init__(self, table: list[dict], *, cap: int):
        self.table = table
        self.cap = cap
        self.requests: list[str] = []

    def __call__(self, url: str, *, method: str = "GET", headers: dict, data=None):
        self.requests.append(url)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        rows = list(self.table)
        songs = query.get("project_id", [""])[0]
        if songs.startswith("in.("):
            wanted = set(songs[len("in.("):-1].split(","))
            rows = [row for row in rows if row["project_id"] in wanted]
        cursor = query.get("id", [""])[0]
        if cursor.startswith("gt."):
            after = cursor[len("gt."):]
            rows = [row for row in rows if row["id"] > after]
        if query.get("order") == ["id.asc"]:
            rows.sort(key=lambda row: row["id"])
        asked = int(query.get("limit", [str(self.cap)])[0])
        return rows[: min(asked, self.cap)]


class TheFirstTakeOfAPart(unittest.TestCase):
    def test_the_earliest_take_of_each_part_by_each_person_on_each_song(self):
        rows = [
            layer("jess-lead-2", created=APRIL),
            layer("jess-lead-1", created=MARCH),
            layer("jess-lead-3", created=MAY),
            layer("marcus-lead", who="marcus", created=APRIL),
            layer("jess-vocal", part="vocal", created=MAY),
            layer("jess-lead-elsewhere", song="song-2", created=MAY),
        ]
        self.assertEqual(
            sweep.first_take_ids(rows),
            {"jess-lead-1", "marcus-lead", "jess-vocal", "jess-lead-elsewhere"},
        )

    def test_two_takes_in_the_same_instant_pick_the_same_one_every_run(self):
        rows = [layer("z", created=MARCH), layer("y", created=MARCH)]
        self.assertEqual(sweep.first_take_ids(rows), {"y"})
        self.assertEqual(sweep.first_take_ids(list(reversed(rows))), {"y"})

    def test_a_part_nobody_marked_still_has_a_first(self):
        # The takes screen pairs an unmarked part the same way, so a beginner
        # who never picked one still has a "then".
        rows = [layer("first", part=None, created=MARCH), layer("later", part="other", created=MAY)]
        self.assertEqual(sweep.first_take_ids(rows), {"first"})

    def test_a_take_whose_time_cannot_be_read_is_kept_rather_than_guessed_past(self):
        rows = [layer("unreadable", created="not a time"), layer("dated", created=MARCH)]
        self.assertEqual(sweep.first_take_ids(rows), {"unreadable"})


class ReadingEveryTake(unittest.TestCase):
    """first_takes reads through the server's cap, or the exemption is a lie.

    A response cut at max-rows loses whichever takes sort past the cut, and
    a first take that is not in first_ids is warned and then deleted while
    the log says first takes are kept. So the read is paged, and these prove
    it finds the first take of every part when no single response could.
    """

    def test_finds_every_first_take_when_the_server_caps_a_page_below_what_was_asked(self):
        # Seven takes across three songs, and a server that will hand back
        # three rows at a time however many are asked for. One request would
        # have lost song-3 entirely and half of song-2.
        table = [
            layer("song-1-lead-1", song="song-1", created=MARCH),
            layer("song-1-lead-2", song="song-1", created=APRIL),
            layer("song-2-lead-1", song="song-2", created=MARCH),
            layer("song-2-lead-2", song="song-2", created=MAY),
            layer("song-2-vocal-1", song="song-2", part="vocal", created=APRIL),
            layer("song-3-bass-1", song="song-3", who="marcus", part="bass", created=MARCH),
            layer("song-3-bass-2", song="song-3", who="marcus", part="bass", created=APRIL),
        ]
        server = CappedPostgrest(table, cap=3)
        with mock.patch.object(sweep, "request", server):
            found = sweep.first_takes("https://x.supabase.co", {}, {"song-1", "song-2", "song-3"})
        self.assertEqual(found, sweep.first_take_ids(table))
        self.assertEqual(
            found,
            {"song-1-lead-1", "song-2-lead-1", "song-2-vocal-1", "song-3-bass-1"},
        )
        # Three full pages and the empty one that says there are no more.
        self.assertEqual(len(server.requests), 4)
        self.assertTrue(all("order=id.asc" in url for url in server.requests))

    def test_reads_to_the_end_when_every_page_comes_back_exactly_full(self):
        # A cap equal to the page size: the last real page is full, and only
        # the empty page after it says the read is over. Stopping at a short
        # page would have been wrong here, and stopping at a full one always is.
        table = [layer(f"take-{n}", created=MARCH) for n in range(6)]
        server = CappedPostgrest(table, cap=2)
        with mock.patch.object(sweep, "request", server):
            rows = list(sweep.every_row("https://x.supabase.co/rest/v1/song_layers?select=id", {}, page=2))
        self.assertEqual(ids(rows), [f"take-{n}" for n in range(6)])
        self.assertEqual(len(server.requests), 4)
        # Each page starts after the last id of the one before it.
        self.assertIn("id=gt.take-1", server.requests[1])
        self.assertIn("id=gt.take-3", server.requests[2])
        self.assertIn("id=gt.take-5", server.requests[3])

    def test_a_song_with_no_takes_is_one_empty_request(self):
        server = CappedPostgrest([], cap=1000)
        with mock.patch.object(sweep, "request", server):
            found = sweep.first_takes("https://x.supabase.co", {}, {"song-1"})
        self.assertEqual(found, set())
        self.assertEqual(len(server.requests), 1)

    def test_a_read_that_fails_stops_the_run_rather_than_deleting_on_a_partial_view(self):
        def broken(url, *, method="GET", headers, data=None):
            raise RuntimeError("HTTP 503")

        with mock.patch.object(sweep, "request", broken):
            with self.assertRaises(RuntimeError):
                sweep.first_takes("https://x.supabase.co", {}, {"song-1"})


class TheSweep(unittest.TestCase):
    def test_keeps_a_first_take_and_still_takes_the_rest(self):
        first = layer("first", created=MARCH)
        later = layer("later", created=MAY)
        first_ids = sweep.first_take_ids([first, later])

        def keep(one: dict) -> bool:
            return sweep.kept_as_the_first(one, first_ids)

        # Both have gone unopened long enough for either pass.
        to_warn, to_delete, kept = sweep.decide([first, later], [first, later], keep)
        self.assertEqual(kept, {"first"})
        self.assertNotIn("first", ids(to_warn))
        self.assertNotIn("first", ids(to_delete))
        # The later take is warned on this run and, like everything else, not
        # deleted on the same one.
        self.assertEqual(ids(to_warn), ["later"])
        self.assertEqual(ids(to_delete), [])

        # A later run, after the warning has been marked.
        to_warn, to_delete, kept = sweep.decide([], [first, later], keep)
        self.assertEqual(ids(to_warn), [])
        self.assertEqual(ids(to_delete), ["later"])
        self.assertEqual(kept, {"first"})

    def test_a_first_take_is_kept_however_long_it_goes_unopened(self):
        # No date in the rule at all: it is a "then" for as long as the song exists.
        first = layer("first", created="2020-01-01T00:00:00+00:00")
        first["last_opened_at"] = "2020-01-02T00:00:00+00:00"
        first_ids = sweep.first_take_ids([first])
        _, to_delete, kept = sweep.decide([], [first], lambda one: sweep.kept_as_the_first(one, first_ids))
        self.assertEqual(ids(to_delete), [])
        self.assertEqual(kept, {"first"})

    def test_the_term_and_the_first_take_are_kept_together(self):
        keep_after = datetime.now(timezone.utc) - timedelta(days=180)
        handed_in = layer("handed-in", song="lesson-song", created=MAY,
                          shared=(datetime.now(timezone.utc) - timedelta(days=30)).isoformat())
        first = layer("first", song="lesson-song", created=MARCH)
        neither = layer("neither", song="lesson-song", created=APRIL)
        first_ids = sweep.first_take_ids([handed_in, first, neither])
        lesson_songs = {"lesson-song"}

        def keep(one: dict) -> bool:
            return (
                sweep.kept_for_the_term(one, lesson_songs, keep_after)
                or sweep.kept_as_the_first(one, first_ids)
            )

        to_warn, to_delete, kept = sweep.decide([handed_in, first, neither], [], keep)
        self.assertEqual(kept, {"handed-in", "first"})
        self.assertEqual(ids(to_warn), ["neither"])
        self.assertEqual(ids(to_delete), [])

    def test_a_song_with_nothing_kept_is_swept_as_before(self):
        old = layer("old", created=MARCH)
        _, to_delete, kept = sweep.decide([], [old], lambda one: False)
        self.assertEqual(ids(to_delete), ["old"])
        self.assertEqual(kept, set())


class ASealedTake(unittest.TestCase):
    """A take put away until a day of somebody's choosing (0158).

    Every Musician, Same Song, 17 September 2026. It has gone unopened for as
    long as it has been sealed, which is the whole idea, so rule 1 alone
    would delete it months before the day it was kept for.
    """

    NOW = datetime(2026, 9, 18, 4, 20, tzinfo=timezone.utc)
    # The deletion cutoff on that morning, as main() works it out.
    OPENED_AFTER = NOW - timedelta(days=90)

    def sealed(self, layer_id: str, until: datetime) -> dict:
        return layer(layer_id, sealed_until=until.isoformat())

    def keep(self, one: dict) -> bool:
        return sweep.kept_while_sealed(one, self.OPENED_AFTER)

    def test_held_out_of_both_passes_until_its_day(self):
        put_away = self.sealed("put-away", self.NOW + timedelta(days=200))
        ordinary = layer("ordinary")
        to_warn, to_delete, kept = sweep.decide(
            [put_away, ordinary], [put_away, ordinary], self.keep)
        self.assertEqual(kept, {"put-away"})
        self.assertEqual(ids(to_warn), ["ordinary"])
        self.assertEqual(ids(to_delete), [])

    def test_and_for_the_ordinary_window_after_it(self):
        # The day came a month ago and nobody has answered the card. It has
        # still been "unopened" for over a year, and it is still kept: the
        # window counts from the day the take came back.
        came_back = self.sealed("came-back", self.NOW - timedelta(days=30))
        _, to_delete, kept = sweep.decide([came_back], [came_back], self.keep)
        self.assertEqual(kept, {"came-back"})
        self.assertEqual(ids(to_delete), [])

    def test_nobody_came_back_for_it_so_it_is_warned_and_then_deleted(self):
        # Not kept for ever. Past the window it is an old take like any
        # other, and gets the same notice: warned on this run, deleted on a
        # later one.
        left = self.sealed("left", self.NOW - timedelta(days=120))
        to_warn, to_delete, kept = sweep.decide([left], [left], self.keep)
        self.assertEqual(kept, set())
        self.assertEqual(ids(to_warn), ["left"])
        self.assertEqual(ids(to_delete), [])

        to_warn, to_delete, _ = sweep.decide([], [left], self.keep)
        self.assertEqual(ids(to_warn), [])
        self.assertEqual(ids(to_delete), ["left"])

    def test_a_take_whose_seal_has_ended_is_an_ordinary_take(self):
        # unseal_take clears the day, so there is nothing on the row to keep
        # it by. What keeps it then is last_opened_at, which the same call
        # set to now -- so it is not a candidate at all until a quarter on.
        self.assertFalse(sweep.kept_while_sealed(layer("answered"), self.OPENED_AFTER))

    def test_a_day_that_cannot_be_read_keeps_the_take(self):
        unreadable = layer("unreadable", sealed_until="not a time")
        self.assertTrue(sweep.kept_while_sealed(unreadable, self.OPENED_AFTER))

    def test_the_sweep_asks_for_the_day_in_both_passes(self):
        # The exemption is decided from the row, so a select that left the
        # column out would keep nothing and say nothing.
        asked: list[str] = []

        def answer(url, *, method="GET", headers, data=None):
            asked.append(url)
            return []

        env = {
            "SUPABASE_PROJECT_REF": "ref",
            "SUPABASE_SERVICE_ROLE_KEY": "key",
            "DRY_RUN": "true",
        }
        with mock.patch.object(sweep, "request", answer), \
                mock.patch.dict("os.environ", env, clear=False), \
                mock.patch("builtins.print"):
            self.assertEqual(sweep.main(), 0)
        passes = [url for url in asked if "last_opened_at=lt." in url]
        self.assertEqual(len(passes), 2)
        for url in passes:
            self.assertIn("sealed_until", url)


if __name__ == "__main__":
    unittest.main()
