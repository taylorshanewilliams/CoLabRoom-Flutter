import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/chord_names.dart';
import 'package:flutter_test/flutter_test.dart';

ChordCue _cue(String chord, int startMs, int endMs) {
  return ChordCue(startMs: startMs, endMs: endMs, chord: chord, confidence: 0.8);
}

/// 120bpm in four: a beat every 500ms, a bar every 2000ms.
List<int> _beats(int bars) =>
    List<int>.generate(bars * 4, (index) => index * 500);
List<int> _downbeats(int bars) =>
    List<int>.generate(bars, (index) => index * 2000);

void main() {
  group('chordDisplay', () {
    test('writes Harte notation the way a musician writes it', () {
      expect(chordDisplay('C:maj'), 'C');
      expect(chordDisplay('A:min'), 'Am');
      expect(chordDisplay('G:7'), 'G7');
      expect(chordDisplay('F:maj7'), 'Fmaj7');
      expect(chordDisplay('D:min7'), 'Dm7');
      expect(chordDisplay('B:hdim7'), 'Bm7♭5');
      expect(chordDisplay('E:sus4'), 'Esus4');
    });

    test('resolves an inversion to the note the bass actually plays', () {
      // /5 is a scale degree, not a note. "C/5" would be unreadable and "C"
      // would be a different chord.
      expect(chordDisplay('C:maj/5'), 'C/G');
      expect(chordDisplay('A:min/b3'), 'Am/C');
      expect(chordDisplay('G:maj/3'), 'G/B');
    });

    test('shows nothing at all where there is no chord', () {
      // ChordMini's "N". Printed literally it reads as a chord.
      expect(chordDisplay('N'), '');
      expect(chordDisplay(''), '');
    });

    test('leaves a chord somebody typed exactly as they typed it', () {
      expect(chordDisplay('Am'), 'Am');
      expect(chordDisplay('F#m7'), 'F#m7');
      expect(chordDisplay('Bb'), 'Bb');
    });

    test('keeps an unrecognised quality rather than inventing one', () {
      expect(chordDisplay('C:9(11)'), 'C9(11)');
    });
  });

  group('buildChartBars', () {
    test('puts each chord in its bar, on the beat it lands on', () {
      final bars = buildChartBars(
        cues: <ChordCue>[
          _cue('C:maj', 0, 1000),
          _cue('F:maj', 1000, 2000),
          _cue('G:maj', 2000, 4000),
        ],
        beatsMs: _beats(3),
        downbeatsMs: _downbeats(3),
      );
      expect(bars.first.number, 1);
      expect(bars.first.beatsInBar, 4);
      expect(bars.first.chords.map((c) => c.chord), <String>['C:maj', 'F:maj']);
      // Second half of a 4/4 bar is beat 3, not beat 2.
      expect(bars.first.chords.last.beat, 3);
      expect(bars[1].chords.single.chord, 'G:maj');
      expect(bars[1].chords.single.beat, 1);
    });

    test('leaves a bar empty when the chord is still ringing', () {
      // One chord held across four bars is written once. Empty bars are how a
      // chart says "keep playing".
      final bars = buildChartBars(
        cues: <ChordCue>[_cue('C:maj', 0, 8000)],
        beatsMs: _beats(4),
        downbeatsMs: _downbeats(4),
      );
      expect(bars.first.chords, hasLength(1));
      expect(bars.skip(1).every((bar) => bar.chords.isEmpty), isTrue);
    });

    test('counts the beats a bar actually got rather than assuming four', () {
      // A bar of three, which is a real thing songs do going into a chorus.
      final bars = buildChartBars(
        cues: <ChordCue>[_cue('C:maj', 0, 1500), _cue('F:maj', 1500, 3500)],
        beatsMs: <int>[0, 500, 1000, 1500, 2000, 2500],
        downbeatsMs: <int>[0, 1500],
      );
      expect(bars.first.beatsInBar, 3);
    });

    test('draws nothing without downbeats', () {
      // Bars are the one thing here that can't be estimated, and a confidently
      // wrong grid is worse than no chart.
      expect(
        buildChartBars(
          cues: <ChordCue>[_cue('C:maj', 0, 1000)],
          beatsMs: _beats(2),
          downbeatsMs: const <int>[],
        ),
        isEmpty,
      );
    });

    test('trims the silence the count runs through at either end', () {
      final bars = buildChartBars(
        cues: <ChordCue>[_cue('C:maj', 4000, 6000)],
        beatsMs: _beats(5),
        downbeatsMs: _downbeats(5),
      );
      expect(bars, hasLength(1));
      expect(bars.single.number, 3);
    });

    test('marks the bar a section starts on', () {
      final bars = buildChartBars(
        cues: <ChordCue>[_cue('C:maj', 0, 2000), _cue('F:maj', 4000, 6000)],
        beatsMs: _beats(4),
        downbeatsMs: _downbeats(4),
        sections: <StructureSection>[
          const StructureSection(startMs: 0, endMs: 4000, label: 'Verse'),
          const StructureSection(startMs: 4000, endMs: 8000, label: 'Chorus'),
        ],
      );
      expect(bars.first.sectionLabel, 'Verse');
      expect(bars[2].sectionLabel, 'Chorus');
      expect(bars[1].sectionLabel, isNull);
    });

    test('a renamed section is what appears on the chart', () {
      final bars = buildChartBars(
        cues: <ChordCue>[_cue('C:maj', 0, 2000)],
        beatsMs: _beats(2),
        downbeatsMs: _downbeats(2),
        sections: <StructureSection>[
          const StructureSection(
            startMs: 0,
            endMs: 4000,
            label: 'Chorus',
            customLabel: 'the big one',
          ),
        ],
      );
      expect(bars.first.sectionLabel, 'the big one');
    });
  });

  group('buildChartRows', () {
    test('breaks four bars to a line', () {
      final bars = buildChartBars(
        cues: <ChordCue>[for (var i = 0; i < 6; i += 1) _cue('C:maj', i * 2000, i * 2000 + 2000)],
        beatsMs: _beats(6),
        downbeatsMs: _downbeats(6),
      );
      final rows = buildChartRows(bars);
      expect(rows.map((row) => row.bars.length), <int>[4, 2]);
      expect(rows.first.firstBarNumber, 1);
      expect(rows.last.firstBarNumber, 5);
    });

    test('starts a new line at a section, even mid-row', () {
      // What makes the shape of a song visible on paper.
      final bars = buildChartBars(
        cues: <ChordCue>[for (var i = 0; i < 6; i += 1) _cue('C:maj', i * 2000, i * 2000 + 2000)],
        beatsMs: _beats(6),
        downbeatsMs: _downbeats(6),
        sections: <StructureSection>[
          const StructureSection(startMs: 0, endMs: 4000, label: 'Verse'),
          const StructureSection(startMs: 4000, endMs: 12000, label: 'Chorus'),
        ],
      );
      final rows = buildChartRows(bars);
      expect(rows.first.sectionLabel, 'Verse');
      expect(rows.first.bars.length, 2);
      expect(rows[1].sectionLabel, 'Chorus');
      expect(rows[1].firstBarNumber, 3);
    });

    test('does not repeat the section name on its continuation lines', () {
      final bars = buildChartBars(
        cues: <ChordCue>[for (var i = 0; i < 8; i += 1) _cue('C:maj', i * 2000, i * 2000 + 2000)],
        beatsMs: _beats(8),
        downbeatsMs: _downbeats(8),
        sections: <StructureSection>[
          const StructureSection(startMs: 0, endMs: 16000, label: 'Verse'),
        ],
      );
      final rows = buildChartRows(bars);
      expect(rows, hasLength(2));
      expect(rows.first.sectionLabel, 'Verse');
      expect(rows.last.sectionLabel, isNull);
    });
  });
}
