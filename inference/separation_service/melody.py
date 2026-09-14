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


def summarise(notes: list[dict], voiced_ratio: float) -> dict:
    """The melody as the caller wants it: the notes, the range, how much of
    the stem was sung at all.

    The range comes from notes that lasted at least 120 ms. A single frame's
    worth of a sung note is where a pitch tracker is likeliest to be an
    octave out, and an octave error on the lowest note of a song is the
    whole vocal range wrong.
    """
    steady = [note for note in notes if note["end_ms"] - note["start_ms"] >= 120] or notes
    return {
        "notes": notes,
        "low_midi": min(note["midi"] for note in steady) if steady else None,
        "high_midi": max(note["midi"] for note in steady) if steady else None,
        "voiced_ratio": round(float(voiced_ratio), 3),
    }
