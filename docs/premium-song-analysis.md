# CoLabRoom Premium Song Analysis

## Product goal

One uploaded reference recording should unlock three connected capabilities:

1. **Lyric Sync** — time every lyric line against the recording so Live mode moves with the actual song structure instead of a constant scroll speed.
2. **Chord Map** — detect a beat-aligned chord progression and render chord symbols above the correct lyric positions.
3. **Live Follow** — listen to a rehearsal/performance and continuously estimate the band's position against the reference recording, including instrumental passages.

The three features should share one reference-audio analysis result instead of separately processing the same song.

## UX

### Song workspace

Add an `Analyze` action near `Live`.

The analysis sheet contains:

- Reference track: Upload / Replace / Remove
- `Sync lyrics` — Premium
- `Detect chords` — Premium
- `Analyze both` — Premium, default recommendation
- Analysis status and confidence
- `Review` when results are ready

Do not place raw technical controls in the normal songwriting view.

### Review result

Chord symbols and lyric timing are suggestions until accepted.

- Tap a chord to correct it.
- Drag a lyric cue boundary if automatic timing is wrong.
- `Accept all` keeps the workflow fast when confidence is high.
- Original analyzer output stays in history so corrections are reversible.

### Live mode

Modes should converge on:

- Manual
- Scroll
- Song Time
- **Follow** (Premium)

When a reference recording has accepted lyric cues, Song Time should use the cue map instead of distributing scrolling linearly across the track.

## Analyzer pipeline

### 1. Normalize and inspect audio

Input: WAV, MP3, M4A, FLAC, OGG where supported.

Extract:

- duration
- sample rate / channels
- waveform envelope
- tempo / beat positions
- chroma/CQT features
- optional vocal transcription

Processing should happen server-side for the premium product. This avoids draining phone battery, keeps paid model/API credentials off the client, and makes analyzer versions reproducible.

### 2. Lyric Sync

The project already contains the canonical lyrics. We should not blindly replace them with a transcript.

Pipeline:

1. Transcribe the uploaded recording with word timestamps.
2. Normalize both recognized words and CoLabRoom lyric tokens (case, punctuation, repeated ad-libs).
3. Use sequence alignment / dynamic programming to match recognized words to the canonical lyric text.
4. Convert matched word timestamps into per-line `start_ms`, `end_ms`, and confidence.
5. Interpolate conservatively around words the transcription misses.
6. Keep long instrumental gaps as actual time gaps; do not spread lyrics evenly through them.

A low-confidence section should be marked for review rather than silently guessed.

### 3. Chord Map

Recommended commercially-friendly first implementation:

1. Decode audio to mono PCM.
2. Estimate beat positions.
3. Compute chroma/CQT pitch-class energy.
4. Aggregate chroma between adjacent beats.
5. Compare each beat/window to major/minor chord templates.
6. Apply temporal smoothing so one noisy frame does not create a one-beat false chord.
7. Merge repeated adjacent chord labels.
8. Store chord, start/end time, strength/confidence, and beat index.

A later model can add sevenths, slash chords, suspended chords, inversions, capo/transposition suggestions, and Nashville numbers.

`librosa` is a good permissive building block for the server implementation (ISC license). Essentia has excellent beat/chord algorithms, including beat-aligned chord detection, but its AGPL/commercial licensing needs to be resolved before using it inside a closed commercial premium service.

### 4. Live Follow

Do **not** base Follow mode on speech recognition alone. It would lose position during intros, solos, instrumental bridges, crowd noise, or when the singer changes words.

Instead:

1. Precompute chroma/CQT features for the reference recording and store a compact fingerprint timeline.
2. During Live mode, compute the same features from short microphone windows.
3. Use online DTW / constrained sequence alignment to estimate current reference position.
4. Fuse optional phonetic/vocal evidence when vocals are present.
5. Track confidence.
6. When confidence drops, hold/slow the display instead of jumping.
7. When confidence returns, ease toward the detected position.
8. Keep a one-gesture `We're here` rescue action for unusual live skips/restarts.

This architecture can naturally handle tempo drift because display position is driven by detected reference position rather than elapsed wall-clock time.

## Data contract

### Reference analysis

```json
{
  "project_id": "uuid",
  "reference_file_id": "uuid",
  "state": "uploaded|queued|processing|ready|failed",
  "duration_ms": 214320,
  "bpm": 118.4,
  "musical_key": "D major",
  "analyzer_version": "song-analysis-v1",
  "lyric_confidence": 0.92,
  "chord_confidence": 0.84
}
```

### Lyric cues

```json
[
  {"contribution_id":"uuid","start_ms":12640,"end_ms":16820,"confidence":0.96}
]
```

### Chord cues

```json
[
  {"start_ms":12100,"end_ms":14120,"chord":"D","confidence":0.89,"beat_index":24},
  {"start_ms":14120,"end_ms":16130,"chord":"G","confidence":0.82,"beat_index":28}
]
```

## Premium boundary

Free:

- normal songwriting/editing
- manual Live mode
- Slow / Medium / Fast
- Song Time
- voice notes

Premium candidate:

- reference-track storage above a reasonable allowance
- automatic lyric synchronization
- automatic chord map
- Live Follow
- advanced chord vocabulary / transposition / Nashville numbers

Do not gate the user's own lyrics or basic collaboration behind Premium.

## Implementation order

1. Finish 0.3.4 editor/voice stability.
2. Add reference-track upload + analysis schema.
3. Add server analyzer V1: lyric timestamps + basic major/minor chord map.
4. Add review/correction UI.
5. Drive Live mode from accepted lyric cue timestamps.
6. Prototype microphone-to-reference online alignment.
7. Add subscription enforcement only after the feature is reliable enough to charge for.

## Technical references

- OpenAI Audio Transcriptions API supports audio transcription and timestamp granularities suitable for building a canonical-lyrics alignment layer: https://platform.openai.com/docs/api-reference/audio
- Librosa is an ISC-licensed Python library for music/audio analysis: https://github.com/librosa/librosa
- Essentia ChordsDetection / ChordsDetectionBeats and RhythmExtractor2013 document chord and beat extraction approaches: https://essentia.upf.edu/
- Research on real-time lyrics alignment combines chroma and phonetic features: https://arxiv.org/abs/2401.09200
- Musical score following/audio alignment literature uses CQT/chroma and DTW-style alignment: https://arxiv.org/abs/2205.03247
