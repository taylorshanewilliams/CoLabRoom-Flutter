import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/chord_beat_grid.dart';
import 'package:flutter_test/flutter_test.dart';

ChordCue _cue(
  String chord,
  int startMs,
  int endMs, {
  double confidence = 0.8,
  String source = 'automatic',
}) {
  return ChordCue(
    startMs: startMs,
    endMs: endMs,
    chord: chord,
    confidence: confidence,
    source: source,
  );
}

/// 120bpm: a beat every 500ms, a bar every four.
List<int> _beats(int count, {int startMs = 0, int intervalMs = 500}) {
  return List<int>.generate(count, (index) => startMs + index * intervalMs);
}

void main() {
  group('snapChordsToBeatGrid', () {
    test('pulls a change that landed just off the beat onto it', () {
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[_cue('A', 0, 1953), _cue('D', 1953, 4012)],
        _beats(16),
      );
      expect(snapped.map((cue) => cue.startMs), <int>[0, 2000]);
      expect(snapped.map((cue) => cue.endMs), <int>[2000, 4000]);
    });

    test('leaves a change that is genuinely off the grid where it is', () {
      // 1750ms is exactly between two beats — as far from either as it can
      // get. A push ahead of the bar is a real thing to play, and moving it
      // would be inventing a performance.
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[_cue('A', 0, 1750), _cue('D', 1750, 4000)],
        _beats(16),
      );
      expect(snapped.first.endMs, 1750);
      expect(snapped.last.startMs, 1750);
    });

    test('keeps the chord map contiguous across a snapped boundary', () {
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[_cue('A', 0, 2040), _cue('D', 2040, 4030), _cue('E', 4030, 6000)],
        _beats(16),
      );
      for (var index = 1; index < snapped.length; index += 1) {
        expect(snapped[index].startMs, snapped[index - 1].endMs);
      }
    });

    test('merges two cues the model split into one chord it doubted', () {
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[
          _cue('A', 0, 1980, confidence: 0.6),
          _cue('A', 1980, 4020, confidence: 0.9),
          _cue('D', 4020, 6000),
        ],
        _beats(16),
      );
      expect(snapped.length, 2);
      expect(snapped.first.chord, 'A');
      expect(snapped.first.startMs, 0);
      expect(snapped.first.endMs, 4000);
      // The merged cue keeps the better of the two confidences rather than
      // inheriting whichever happened to come first.
      expect(snapped.first.confidence, 0.9);
    });

    test('drops a chord that collapsed onto a single beat, leaving no gap', () {
      // 60ms of "F" between two beats: shorter than the grid can express.
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[_cue('A', 0, 2000), _cue('F', 2000, 2060), _cue('D', 2060, 4000)],
        _beats(16),
      );
      expect(snapped.map((cue) => cue.chord), <String>['A', 'D']);
      expect(snapped.first.endMs, snapped.last.startMs);
    });

    test('returns the chords untouched when there is no usable grid', () {
      final cues = <ChordCue>[_cue('A', 0, 1953), _cue('D', 1953, 4012)];
      expect(snapChordsToBeatGrid(cues, const <int>[]), same(cues));
      expect(snapChordsToBeatGrid(cues, <int>[0, 500, 1000]), same(cues));
    });

    test('never moves a chord a person placed', () {
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[_cue('A', 0, 1953, source: 'manual')],
        _beats(16),
      );
      expect(snapped.single.startMs, 0);
      expect(snapped.single.endMs, 1953);
    });

    test('survives a beat the tracker dropped', () {
      // One missing beat at 2000ms leaves a gap of two beats. The median
      // interval still reads 500ms, so the tolerance stays honest instead of
      // widening enough to swallow real changes.
      final beats = <int>[0, 500, 1000, 1500, 2500, 3000, 3500, 4000];
      expect(medianBeatIntervalMs(beats), 500);
      final snapped = snapChordsToBeatGrid(
        <ChordCue>[_cue('A', 0, 1520), _cue('D', 1520, 4000)],
        beats,
      );
      expect(snapped.first.endMs, 1500);
    });
  });

  group('barNumberAt', () {
    final downbeats = <int>[1000, 3000, 5000, 7000];

    test('counts bars from the first downbeat', () {
      expect(barNumberAt(1000, downbeats), 1);
      expect(barNumberAt(2999, downbeats), 1);
      expect(barNumberAt(3000, downbeats), 2);
      expect(barNumberAt(7400, downbeats), 4);
      expect(barNumberAt(999999, downbeats), 4);
    });

    test('refuses to name a bar for a pickup', () {
      // Before bar 1 there is no bar. Calling it bar 1 would tell a band to
      // come in a bar late.
      expect(barNumberAt(400, downbeats), isNull);
      expect(barNumberAt(0, const <int>[]), isNull);
    });
  });

  group('groupChordsIntoBars', () {
    final downbeats = <int>[0, 2000, 4000, 6000];

    test('puts each chord in the bar it starts in', () {
      final bars = groupChordsIntoBars(
        <ChordCue>[
          _cue('A', 0, 1000),
          _cue('D', 1000, 2000),
          _cue('E', 2000, 4000),
          _cue('A', 4000, 6000),
        ],
        downbeats,
      );
      expect(bars.map((bar) => bar.number), <int>[1, 2, 3]);
      expect(bars.first.chords.map((cue) => cue.chord), <String>['A', 'D']);
      expect(bars[1].chords.single.chord, 'E');
    });

    test('skips bars nothing happens in rather than padding them out', () {
      final bars = groupChordsIntoBars(
        <ChordCue>[_cue('A', 0, 1000), _cue('D', 6000, 8000)],
        downbeats,
      );
      expect(bars.map((bar) => bar.number), <int>[1, 4]);
    });

    test('keeps a chord that starts before the count does', () {
      final bars = groupChordsIntoBars(
        <ChordCue>[_cue('A', 0, 900)],
        <int>[1000, 3000],
      );
      expect(bars.single.number, 1);
      expect(bars.single.chords.single.chord, 'A');
    });

    test('has nothing to group without downbeats', () {
      expect(groupChordsIntoBars(<ChordCue>[_cue('A', 0, 1000)], const <int>[]), isEmpty);
    });
  });
}
