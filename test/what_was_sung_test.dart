import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pipeline heard chords, words and sections and never once a note.
/// This is the tune arriving in the app: the shape it comes in, the way a
/// singer would say it, and the two questions the sheet asks of it.
void main() {
  group('a note, said the way a singer says it', () {
    test('middle C is C4 and the octave turns over at C', () {
      expect(midiNoteLabel(60), 'C4');
      expect(midiNoteLabel(61), 'C♯4');
      expect(midiNoteLabel(59), 'B3');
      expect(midiNoteLabel(69), 'A4');
      expect(midiNoteLabel(40), 'E2');
    });
  });

  group('the melody', () {
    final json = <String, dynamic>{
      'notes': <Map<String, dynamic>>[
        <String, dynamic>{'start_ms': 1000, 'end_ms': 1400, 'midi': 64, 'cents': -12},
        <String, dynamic>{'start_ms': 1400, 'end_ms': 2100, 'midi': 67, 'cents': 5},
        <String, dynamic>{'start_ms': 2600, 'end_ms': 3000, 'midi': 52},
      ],
      'low_midi': 52,
      'high_midi': 67,
      'voiced_ratio': 0.42,
    };

    test('survives the round trip through JSON', () {
      final melody = Melody.fromJson(json);
      expect(melody.notes.length, 3);
      expect(melody.notes.first.label, 'E4');
      expect(melody.notes.first.cents, -12);
      expect(melody.notes.last.cents, 0);
      expect(melody.lowMidi, 52);
      expect(melody.highMidi, 67);
      expect(melody.voicedRatio, closeTo(0.42, 0.001));
      expect(Melody.fromJson(melody.toJson()).toJson(), melody.toJson());
    });

    test('says its range as two notes, or one', () {
      expect(Melody.fromJson(json).rangeLabel, 'E3 – G4');
      expect(const Melody(notes: <MelodyNote>[], lowMidi: 60, highMidi: 60).rangeLabel, 'C4');
      expect(const Melody(notes: <MelodyNote>[]).rangeLabel, isNull);
    });

    test('the range is where the voice lives, not the worst two frames', () {
      // A verse on C4 and E4, plus what a tracker does to a real song: a
      // breathy onset read an octave low and a consonant read an octave
      // high, each a "note" and each a sliver of the sung time. Min and max
      // said C2 – C6 for exactly this shape, on the first real song.
      MelodyNote at(int midi, int ms) => MelodyNote(startMs: 0, endMs: ms, midi: midi);
      final melody = Melody(notes: <MelodyNote>[at(36, 300), at(60, 5000), at(64, 4000), at(84, 300)]);
      expect(Melody.sungRange(melody.notes), (60, 64));
      // A fifth of the song on a low note is not an error, it is the song.
      expect(Melody.sungRange(<MelodyNote>[at(48, 2400), at(60, 5000), at(64, 4000)]), (48, 64));
      // One note is its own range; nothing is no range.
      expect(Melody.sungRange(<MelodyNote>[at(57, 4000)]), (57, 57));
      expect(Melody.sungRange(<MelodyNote>[]), isNull);
    });

    test('a worker that said min and max is overruled by its own notes', () {
      final wide = <String, dynamic>{
        'notes': <Map<String, dynamic>>[
          <String, dynamic>{'start_ms': 0, 'end_ms': 300, 'midi': 36},
          <String, dynamic>{'start_ms': 300, 'end_ms': 5300, 'midi': 60},
          <String, dynamic>{'start_ms': 5300, 'end_ms': 9300, 'midi': 64},
          <String, dynamic>{'start_ms': 9300, 'end_ms': 9600, 'midi': 84},
        ],
        'low_midi': 36,
        'high_midi': 84,
      };
      expect(Melody.fromJson(wide).rangeLabel, 'C4 – E4');
      // And with no notes to go on, the worker's word stands.
      expect(Melody.fromJson(<String, dynamic>{'low_midi': 50, 'high_midi': 62}).rangeLabel, 'D3 – D4');
    });

    test('knows which note is sounding, and when none is', () {
      final melody = Melody.fromJson(json);
      expect(melody.noteAt(900), isNull);
      expect(melody.noteAt(1000)!.label, 'E4');
      expect(melody.noteAt(1399)!.label, 'E4');
      expect(melody.noteAt(1400)!.label, 'G4');
      // The breath between the second and third notes.
      expect(melody.noteAt(2300), isNull);
      expect(melody.noteAt(2700)!.label, 'E3');
      expect(melody.noteAt(9000), isNull);
    });

    test('a reference without a melody says nothing rather than a dash', () {
      const track = ReferenceTrack(
        projectId: 'p',
        fileId: 'f',
        storagePath: 'room/p/x.m4a',
        displayName: 'x',
        state: SongAnalysisState.ready,
      );
      expect(track.melody, isNull);
      expect(track.melody?.rangeLabel, isNull);
    });
  });
}
