"""CoLabRoom reference-track analyzer prototype.

This module intentionally has no web-framework or provider dependency. It can be
wrapped by a Vercel/Cloud Run worker later. Harmony analysis uses permissively
licensed librosa/numpy. Lyric alignment accepts word-timestamp JSON from any
transcription provider and aligns it back to the canonical CoLabRoom lyrics.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from difflib import SequenceMatcher
import json
import math
import re
from pathlib import Path
from typing import Iterable, Sequence

import librosa
import numpy as np


@dataclass(frozen=True)
class TimedWord:
    word: str
    start: float
    end: float


@dataclass(frozen=True)
class LyricCue:
    line_index: int
    start_ms: int
    end_ms: int
    confidence: float


@dataclass(frozen=True)
class ChordCue:
    start_ms: int
    end_ms: int
    chord: str
    confidence: float
    beat_index: int


@dataclass(frozen=True)
class HarmonyAnalysis:
    duration_ms: int
    bpm: float
    chords: list[ChordCue]


_TOKEN_RE = re.compile(r"[a-z0-9']+")


def normalize_token(value: str) -> str:
    match = _TOKEN_RE.search(value.lower().replace("’", "'"))
    return match.group(0) if match else ""


def lyric_tokens(lines: Sequence[str]) -> tuple[list[str], list[int]]:
    tokens: list[str] = []
    owners: list[int] = []
    for line_index, line in enumerate(lines):
        for raw in _TOKEN_RE.findall(line.lower().replace("’", "'")):
            token = normalize_token(raw)
            if token:
                tokens.append(token)
                owners.append(line_index)
    return tokens, owners


def token_similarity(left: str, right: str) -> float:
    if left == right:
        return 1.0
    if not left or not right:
        return 0.0
    return SequenceMatcher(a=left, b=right).ratio()


def align_words_to_lyrics(
    lines: Sequence[str],
    transcript_words: Sequence[TimedWord],
) -> list[LyricCue]:
    """Needleman-Wunsch-style alignment from transcript words to canonical lyrics.

    The transcription is evidence only: canonical CoLabRoom lyrics remain the
    source of truth. Low-confidence lines are returned with lower confidence so
    the client can request review instead of silently changing words.
    """

    canonical, owner = lyric_tokens(lines)
    observed = [normalize_token(item.word) for item in transcript_words]
    observed_indices = [i for i, token in enumerate(observed) if token]
    observed = [observed[i] for i in observed_indices]
    words = [transcript_words[i] for i in observed_indices]
    n, m = len(canonical), len(observed)
    if n == 0 or m == 0:
        return []

    gap = -0.75
    score = np.zeros((n + 1, m + 1), dtype=np.float32)
    trace = np.zeros((n + 1, m + 1), dtype=np.uint8)
    for i in range(1, n + 1):
        score[i, 0] = i * gap
        trace[i, 0] = 1
    for j in range(1, m + 1):
        score[0, j] = j * gap
        trace[0, j] = 2

    for i in range(1, n + 1):
        for j in range(1, m + 1):
            similarity = token_similarity(canonical[i - 1], observed[j - 1])
            match_score = 1.4 * similarity - (0.7 if similarity < 0.55 else 0.0)
            diagonal = score[i - 1, j - 1] + match_score
            up = score[i - 1, j] + gap
            left = score[i, j - 1] + gap
            if diagonal >= up and diagonal >= left:
                score[i, j] = diagonal
                trace[i, j] = 0
            elif up >= left:
                score[i, j] = up
                trace[i, j] = 1
            else:
                score[i, j] = left
                trace[i, j] = 2

    matches: list[tuple[int, int, float]] = []
    i, j = n, m
    while i > 0 or j > 0:
        direction = trace[i, j]
        if i > 0 and j > 0 and direction == 0:
            similarity = token_similarity(canonical[i - 1], observed[j - 1])
            if similarity >= 0.55:
                matches.append((i - 1, j - 1, similarity))
            i -= 1
            j -= 1
        elif i > 0 and (j == 0 or direction == 1):
            i -= 1
        else:
            j -= 1
    matches.reverse()

    by_line: dict[int, list[tuple[TimedWord, float]]] = {}
    token_count: dict[int, int] = {}
    for line_index in owner:
        token_count[line_index] = token_count.get(line_index, 0) + 1
    for canonical_index, observed_index, similarity in matches:
        line_index = owner[canonical_index]
        by_line.setdefault(line_index, []).append((words[observed_index], similarity))

    cues: list[LyricCue] = []
    for line_index, evidence in sorted(by_line.items()):
        first = min(item.start for item, _ in evidence)
        last = max(item.end for item, _ in evidence)
        coverage = len(evidence) / max(1, token_count.get(line_index, len(evidence)))
        lexical = sum(similarity for _, similarity in evidence) / len(evidence)
        confidence = max(0.0, min(1.0, 0.62 * coverage + 0.38 * lexical))
        cues.append(
            LyricCue(
                line_index=line_index,
                start_ms=max(0, round(first * 1000)),
                end_ms=max(0, round(last * 1000)),
                confidence=round(confidence, 4),
            )
        )
    return cues


def _chord_templates() -> tuple[list[str], np.ndarray]:
    labels: list[str] = []
    templates: list[np.ndarray] = []
    pitch_names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    for root in range(12):
        for suffix, intervals in (("", (0, 4, 7)), ("m", (0, 3, 7))):
            vector = np.full(12, 0.08, dtype=np.float32)
            vector[list((root + interval) % 12 for interval in intervals)] = (1.0, 0.82, 0.9)
            vector /= np.linalg.norm(vector) + 1e-9
            labels.append(pitch_names[root] + suffix)
            templates.append(vector)
    return labels, np.stack(templates)


def _classify_chroma(chroma: np.ndarray) -> tuple[str, float]:
    labels, templates = _chord_templates()
    vector = np.maximum(chroma.astype(np.float32), 0)
    norm = np.linalg.norm(vector)
    if norm < 1e-6:
        return "N", 0.0
    vector /= norm
    scores = templates @ vector
    best = int(np.argmax(scores))
    sorted_scores = np.sort(scores)
    margin = float(sorted_scores[-1] - sorted_scores[-2]) if len(scores) > 1 else float(scores[best])
    confidence = max(0.0, min(1.0, 0.72 * float(scores[best]) + 1.8 * margin - 0.18))
    return labels[best], confidence


def _smooth_labels(labels: Sequence[str], confidences: Sequence[float]) -> list[str]:
    if len(labels) < 3:
        return list(labels)
    result = list(labels)
    for index in range(1, len(labels) - 1):
        left, current, right = labels[index - 1], labels[index], labels[index + 1]
        if left == right and current != left and confidences[index] < 0.72:
            result[index] = left
    return result


def analyze_harmony(audio_path: str | Path) -> HarmonyAnalysis:
    path = str(audio_path)
    y, sr = librosa.load(path, sr=22050, mono=True)
    duration = float(librosa.get_duration(y=y, sr=sr))
    if len(y) == 0:
        return HarmonyAnalysis(duration_ms=0, bpm=0.0, chords=[])

    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr, units="frames")
    bpm = float(np.asarray(tempo).reshape(-1)[0]) if np.asarray(tempo).size else 0.0
    beat_frames = np.asarray(beat_frames, dtype=int)

    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    if beat_frames.size < 2:
        # Fall back to approximately half-second harmonic windows.
        hop_seconds = 0.5
        total_frames = chroma.shape[1]
        frames_per_window = max(1, round(hop_seconds * sr / 512))
        beat_frames = np.arange(0, total_frames + frames_per_window, frames_per_window, dtype=int)
        beat_frames = np.clip(beat_frames, 0, total_frames)
        beat_frames = np.unique(beat_frames)

    frame_times = librosa.frames_to_time(np.arange(chroma.shape[1] + 1), sr=sr)
    raw_labels: list[str] = []
    confidences: list[float] = []
    windows: list[tuple[float, float]] = []

    for index in range(max(0, len(beat_frames) - 1)):
        start_frame = int(np.clip(beat_frames[index], 0, chroma.shape[1] - 1))
        end_frame = int(np.clip(beat_frames[index + 1], start_frame + 1, chroma.shape[1]))
        segment = np.median(chroma[:, start_frame:end_frame], axis=1)
        label, confidence = _classify_chroma(segment)
        raw_labels.append(label)
        confidences.append(confidence)
        start_time = float(frame_times[min(start_frame, len(frame_times) - 1)])
        end_time = float(frame_times[min(end_frame, len(frame_times) - 1)])
        windows.append((start_time, min(duration, max(start_time, end_time))))

    labels = _smooth_labels(raw_labels, confidences)
    cues: list[ChordCue] = []
    for index, (label, confidence, window) in enumerate(zip(labels, confidences, windows)):
        start, end = window
        if cues and cues[-1].chord == label:
            previous = cues[-1]
            weighted = (previous.confidence + confidence) / 2
            cues[-1] = ChordCue(
                start_ms=previous.start_ms,
                end_ms=round(end * 1000),
                chord=label,
                confidence=round(weighted, 4),
                beat_index=previous.beat_index,
            )
        else:
            cues.append(
                ChordCue(
                    start_ms=round(start * 1000),
                    end_ms=round(end * 1000),
                    chord=label,
                    confidence=round(confidence, 4),
                    beat_index=index,
                )
            )

    return HarmonyAnalysis(
        duration_ms=round(duration * 1000),
        bpm=round(bpm, 3),
        chords=cues,
    )


def analysis_json(
    audio_path: str | Path,
    lyric_lines: Sequence[str] | None = None,
    transcript_words: Sequence[TimedWord] | None = None,
) -> str:
    harmony = analyze_harmony(audio_path)
    payload = {
        "duration_ms": harmony.duration_ms,
        "bpm": harmony.bpm,
        "chords": [asdict(cue) for cue in harmony.chords],
        "lyrics": [],
    }
    if lyric_lines is not None and transcript_words is not None:
        payload["lyrics"] = [asdict(cue) for cue in align_words_to_lyrics(lyric_lines, transcript_words)]
    return json.dumps(payload, indent=2)
