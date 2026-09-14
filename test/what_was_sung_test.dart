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
