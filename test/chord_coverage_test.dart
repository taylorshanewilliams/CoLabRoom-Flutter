import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

ChordCue _cue(String chord, int startMs, int endMs) {
  return ChordCue(startMs: startMs, endMs: endMs, chord: chord, confidence: 0.8);
}

void main() {
  test('measures the share of the recording that has a named chord', () {
    final coverage = chordCoverage(
      <ChordCue>[_cue('A', 0, 30000), _cue('D', 30000, 60000)],
      120000,
    );
    expect(coverage, closeTo(0.5, 1e-9));
  });

  test('does not count stretches ChordMini marked as no-chord', () {
    // "N" is ChordMini's label for a stretch it found no chord in — silence,
    // an intro, an unpitched break. Counting it would make coverage read
    // high on exactly the recordings that went worst.
    final coverage = chordCoverage(
      <ChordCue>[_cue('A', 0, 30000), _cue('N', 30000, 90000)],
      120000,
    );
    expect(coverage, closeTo(0.25, 1e-9));
  });

  test('clamps cues that overrun the recording', () {
    final coverage = chordCoverage(<ChordCue>[_cue('A', 0, 200000)], 100000);
    expect(coverage, 1.0);
  });

  test('is zero when there is nothing to measure', () {
    expect(chordCoverage(const <ChordCue>[], 120000), 0);
    expect(chordCoverage(<ChordCue>[_cue('A', 0, 1000)], 0), 0);
  });

  test('a fully covered recording reads as fully covered', () {
    final coverage = chordCoverage(
      <ChordCue>[_cue('A', 0, 60000), _cue('E', 60000, 120000)],
      120000,
    );
    expect(coverage, 1.0);
  });
}
