"""Turning a pitch track into notes.

pyin hands back one frequency per frame, twenty milliseconds apart, with a
flag saying whether anything was being sung. That is a curve, and a musician
does not sing curves: they sing notes, and a note is a stretch of the curve
that stays near one pitch. This is the grouping, and nothing else -- pure
Python on plain lists, so it can be run and tested on a laptop that has no
librosa and no GPU.

The rules:

  * a note ends when the voice stops, or when the pitch moves more than
    three quarters of a semitone from the running middle of the note. Three
    quarters, not a half: vibrato and scoops live inside a semitone, and
    splitting every wobble into a new note is the mistake that makes an
    automatic melody unreadable.
  * a note shorter than sixty milliseconds is not a note; it is the pitch
    tracker changing its mind between two real ones.
  * the pitch of a note is the median of its frames, said as the nearest
    MIDI number plus the cents it sat from it. Median, because the first
    and last frames of a sung note are the least trustworthy.
"""

from __future__ import annotations

import math

NEW_NOTE_SEMITONES = 0.75
MIN_NOTE_MS = 60
MAX_NOTES = 4000


def _median(values: list[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def segment_melody(midi_by_frame: list, voiced: list, hop_ms: float) -> list[dict]:
    """Notes from a frame-wise pitch track.

    ``midi_by_frame`` holds a MIDI number (float) per frame, or None / NaN
    where nothing was sung; ``voiced`` is the tracker's own yes/no per frame.
    Returns ``[{start_ms, end_ms, midi, cents}, ...]`` in time order.
    """
    notes: list[dict] = []
    start: int | None = None
    values: list[float] = []

    def flush(end_index: int) -> None:
        if start is None or not values:
            return
        duration_ms = (end_index - start) * hop_ms
        if duration_ms < MIN_NOTE_MS:
            return
        middle = _median(values)
        midi = int(round(middle))
        notes.append(
            {
                "start_ms": int(round(start * hop_ms)),
                "end_ms": int(round(end_index * hop_ms)),
                "midi": midi,
                "cents": int(round((middle - midi) * 100)),
            }
        )

    for index, (pitch, is_voiced) in enumerate(zip(midi_by_frame, voiced)):
        usable = bool(is_voiced) and pitch is not None and not (
            isinstance(pitch, float) and math.isnan(pitch)
        )
        if not usable:
            flush(index)
            start, values = None, []
            continue
        pitch = float(pitch)
        if start is None:
            start, values = index, [pitch]
            continue
        if abs(pitch - _median(values)) > NEW_NOTE_SEMITONES:
            flush(index)
            start, values = index, [pitch]
        else:
            values.append(pitch)
    flush(len(midi_by_frame))
    return notes[:MAX_NOTES]


STEADY_NOTE_MS = 120
RANGE_TRIM = 0.05


def sung_range(notes: list[dict]) -> tuple[int | None, int | None]:
    """The lowest and highest notes that were actually sung, as the singer
    would give them.

    Not the minimum and maximum. The first real song through this came back
    as C2 – C6 -- four octaves, which nobody sings -- because a pitch
    tracker over a separated vocal is wrong somewhere in every song: an
    octave low on a breathy onset, an octave high on a consonant, a guitar
    bleed that lasted long enough to count. Each of those is a sliver of the
    sung time, and a range is a claim about where the voice *lives*, so the
    range is where the sung time lives: the notes are sorted by pitch and
    the lowest 5 % and highest 5 % of sung milliseconds are left out. A note
    held for a fifth of the song stays in, however low; a flicker never
    widens anything. Notes shorter than 120 ms are dropped first, for the
    same reason as before -- a single frame is where the tracker is
    likeliest to be an octave out.
    """
    steady = [n for n in notes if n["end_ms"] - n["start_ms"] >= STEADY_NOTE_MS] or notes
    if not steady:
        return None, None
    ordered = sorted(steady, key=lambda n: n["midi"])
    total = sum(n["end_ms"] - n["start_ms"] for n in ordered)
    if total <= 0:
        return ordered[0]["midi"], ordered[-1]["midi"]
    low = high = None
    seen = 0
    for note in ordered:
        seen += note["end_ms"] - note["start_ms"]
        if low is None and seen >= total * RANGE_TRIM:
            low = note["midi"]
        if seen >= total * (1 - RANGE_TRIM):
            high = note["midi"]
            break
    return low, high if high is not None else ordered[-1]["midi"]


def summarise(notes: list[dict], voiced_ratio: float) -> dict:
    """The melody as the caller wants it: the notes, the range, how much of
    the stem was sung at all. See sung_range for what "range" means here."""
    low, high = sung_range(notes)
    return {
        "notes": notes,
        "low_midi": low,
        "high_midi": high,
        "voiced_ratio": round(float(voiced_ratio), 3),
    }
