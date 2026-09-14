"""Runs on any Python, no numpy: `python inference/separation_service/test_melody.py`."""

from __future__ import annotations

import math

from melody import segment_melody, summarise

HOP = 20.0  # ms


def frames(*runs: tuple[float | None, int]) -> tuple[list, list]:
    """(pitch or None, frame count) pairs -> the two lists pyin would give."""
    midi: list = []
    voiced: list = []
    for pitch, count in runs:
        for _ in range(count):
            midi.append(pitch if pitch is not None else math.nan)
            voiced.append(pitch is not None)
    return midi, voiced


def test_two_notes_with_a_breath() -> None:
    midi, voiced = frames((60.0, 10), (None, 5), (64.1, 10))
    notes = segment_melody(midi, voiced, HOP)
    assert [n["midi"] for n in notes] == [60, 64], notes
    assert notes[0]["start_ms"] == 0 and notes[0]["end_ms"] == 200, notes[0]
    assert notes[1]["start_ms"] == 300 and notes[1]["end_ms"] == 500, notes[1]
    assert notes[1]["cents"] == 10, notes[1]


def test_vibrato_stays_one_note() -> None:
    wobble = [(60.0 + (0.3 if i % 2 else -0.3), 1) for i in range(20)]
    midi, voiced = frames(*wobble)
    notes = segment_melody(midi, voiced, HOP)
    assert len(notes) == 1, notes
    assert notes[0]["midi"] == 60


def test_a_leap_is_a_new_note() -> None:
    midi, voiced = frames((60.0, 10), (67.0, 10))
    notes = segment_melody(midi, voiced, HOP)
    assert [n["midi"] for n in notes] == [60, 67], notes


def test_a_blip_is_not_a_note() -> None:
    midi, voiced = frames((60.0, 10), (72.0, 2), (60.0, 10))
    notes = segment_melody(midi, voiced, HOP)
    assert [n["midi"] for n in notes] == [60, 60], notes


def test_range_ignores_a_flicker() -> None:
    midi, voiced = frames((48.0, 4), (60.0, 20), (64.0, 20), (72.0, 3))
    notes = segment_melody(midi, voiced, HOP)
    summary = summarise(notes, 0.9)
    # 48 and 72 lasted under 120 ms; the range is the sung part.
    assert summary["low_midi"] == 60 and summary["high_midi"] == 64, summary
    assert summary["voiced_ratio"] == 0.9


def note(midi: int, ms: int, at: int = 0) -> dict:
    return {"start_ms": at, "end_ms": at + ms, "midi": midi, "cents": 0}


def test_range_is_where_the_voice_lives() -> None:
    # A verse on C4 and E4, plus what a tracker does to a real song: a
    # breathy onset read an octave low and a consonant read an octave high,
    # each lasting long enough to be a "note" but a sliver of the sung time.
    # Min and max said C2 – C6 for exactly this shape.
    notes = [note(36, 300), note(60, 5000), note(64, 4000), note(84, 300)]
    summary = summarise(notes, 0.6)
    assert (summary["low_midi"], summary["high_midi"]) == (60, 64), summary


def test_a_note_that_is_held_counts_however_low() -> None:
    # A fifth of the song on a low note is not an error, it is the song.
    notes = [note(48, 2400), note(60, 5000), note(64, 4000)]
    summary = summarise(notes, 0.6)
    assert (summary["low_midi"], summary["high_midi"]) == (48, 64), summary


def test_one_note_is_its_own_range() -> None:
    summary = summarise([note(57, 4000)], 1.0)
    assert (summary["low_midi"], summary["high_midi"]) == (57, 57), summary


def test_silence_is_no_melody() -> None:
    midi, voiced = frames((None, 50))
    assert segment_melody(midi, voiced, HOP) == []
    assert summarise([], 0.0)["low_midi"] is None


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            test()
            print("ok", name)
