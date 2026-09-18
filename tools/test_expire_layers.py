"""The retention sweep keeps what the plan says it keeps.

Run by CI (verify.yml, python-services) with unittest and nothing else.
There is no Postgres here, so these test the deciding, not the fetching:
expire_layers.decide is the one place the two passes are chosen, and the
exemptions are plain functions over rows.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone

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
) -> dict:
    """A song_layers row as PostgREST hands it back, with the fields the sweep reads."""
    return {
        "id": layer_id,
        "project_id": song,
        "recorded_by": who,
        "part": part,
        "created_at": created,
        "shared_at": shared,
        "last_opened_at": "2026-03-02T00:00:00+00:00",
        "label": layer_id,
        "storage_path": f"room/{song}/layers/{layer_id}.m4a",
        "byte_size": 1000,
    }


def ids(layers) -> list[str]:
    return [one["id"] for one in layers]


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


if __name__ == "__main__":
    unittest.main()
