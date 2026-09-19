import 'package:colabroom/services/music_reference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chordReference', () {
    test('reads Harte and written spellings as the same chord', () {
      final harte = chordReference('A:min7')!;
      final written = chordReference('Am7')!;
      expect(harte.display, 'Am7');
      expect(written.display, 'Am7');
      expect(
        harte.tones.map((tone) => tone.note),
        written.tones.map((tone) => tone.note),
      );
    });

    test('spells a minor 7th chord out', () {
      final reference = chordReference('Am7')!;
      expect(reference.qualityName, 'Minor 7th');
      expect(
        reference.tones.map((tone) => tone.note).toList(),
        <String>['A', 'C', 'E', 'G'],
      );
    });

    test('a flat root is spelled in flats, not sharps', () {
      final reference = chordReference('Eb')!;
      expect(
        reference.tones.map((tone) => tone.note).toList(),
        <String>['Eb', 'G', 'Bb'],
      );
    });

    test('offers the open shape first when there is one', () {
      final reference = chordReference('G')!;
      expect(reference.shapes.first.baseFret, 1);
      expect(reference.shapes.first.frets, <int>[3, 2, 0, 0, 0, 3]);
      expect(reference.shapes.first.hint, 'Open position');
    });

    test('a chord with no open shape gets a barre, lowest fret first', () {
      final reference = chordReference('F')!;
      expect(reference.shapes, isNotEmpty);
      // F is one fret above E, so the E-shape barre sits at fret 1 — the A
      // shape would be at 8, and offering that first would be nonsense.
      expect(reference.shapes.first.baseFret, 1);
      expect(reference.shapes.first.hint, contains('sixth string'));
    });

    test('root-fifth is the actual fifth of this chord', () {
      final reference = chordReference('D')!;
      expect(reference.bassMoves.first.$1, 'Root–fifth');
      expect(reference.bassMoves.first.$2, 'D  A');
      // And the chord's own fifth on a chord whose fifth is not a perfect
      // one, the same rule the bass neck above these follows.
      expect(chordReference('D°')!.bassMoves.first.$2, 'D  G#');
      expect(chordReference('D+')!.bassMoves.first.$2, 'D  A#');
    });

    test('nothing under the chord is a line somebody was told to play', () {
      // A "Walking" row used to sit here with a composed four-note line in
      // it, and the line went outside the chord on the way: the 4th over a
      // minor chord, the 6th over a major one. Chord tones describe, a line
      // composes (Every Musician, Same Song, 17 September 2026), so the row
      // is gone and what is left is the root and the chord's own fifth.
      expect(
        chordReference('Am')!.bassMoves,
        <(String, String)>[('Root–fifth', 'A  E'), ('Root–octave', 'A  A')],
      );
      expect(
        chordReference('A')!.bassMoves,
        <(String, String)>[('Root–fifth', 'A  E'), ('Root–octave', 'A  A')],
      );
    });

    test('no bass reading is ever a note the chord has not got', () {
      for (final root in const <String>[
        'C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B',
      ]) {
        for (final quality in const <String>[
          '', 'm', '7', 'm7', 'maj7', 'm7b5', '°', '°7', '+', 'sus2', 'sus4',
          '7sus4', '5', '6', 'm6', '9', 'm9', 'maj9', 'add9', '11', '13',
        ]) {
          final label = '$root$quality';
          final reference = chordReference(label)!;
          final tones = reference.tones
              .map((tone) => pitchOf(tone.note)! % 12)
              .toSet();
          expect(reference.bassMoves, isNotEmpty, reason: label);
          for (final (name, notes) in reference.bassMoves) {
            for (final note in notes.split('  ')) {
              expect(tones, contains(pitchOf(note)! % 12),
                  reason: '$label $name $note');
            }
          }
        }
      }
    });

    test('the notes that work over it follow the third', () {
      // A minor chord takes the minor pentatonic, a major one the major.
      expect(chordReference('Am')!.pentatonic, <String>['A', 'C', 'D', 'E', 'G']);
      expect(chordReference('A')!.pentatonic,
          <String>['A', 'B', 'C#', 'E', 'F#']);
      // A dominant 7th is still a major chord to play over.
      expect(chordReference('A7')!.pentatonic,
          <String>['A', 'B', 'C#', 'E', 'F#']);
      // No third to go on — the safer guess rather than a coin toss.
      expect(chordReference('Asus4')!.pentatonic,
          <String>['A', 'B', 'C#', 'E', 'F#']);
    });

    test('an inversion keeps the bass note', () {
      final reference = chordReference('C:maj/G')!;
      expect(reference.bassNote, 'G');
      expect(reference.display, 'C/G');
    });

    test('a quality it cannot spell says so instead of guessing', () {
      final reference = chordReference('C:min7(b13)')!;
      expect(reference.recognised, isFalse);
      expect(reference.tones, isEmpty);
      expect(reference.shapes, isEmpty);
      expect(reference.pentatonic, isEmpty);
    });

    test('no chord opens no sheet', () {
      expect(chordReference('N'), isNull);
      expect(chordReference(''), isNull);
      expect(chordReference('   '), isNull);
    });
  });

  group('keyReference', () {
    test('builds the major scale and its chords', () {
      final reference = keyReference('C major')!;
      expect(reference.minor, isFalse);
      expect(
        reference.scale,
        <String>['C', 'D', 'E', 'F', 'G', 'A', 'B'],
      );
      expect(
        reference.diatonic,
        <String>['C', 'Dm', 'Em', 'F', 'G', 'Am', 'Bdim'],
      );
      expect(reference.relative, 'A minor');
    });

    test('builds the natural minor scale and its chords', () {
      final reference = keyReference('A minor')!;
      expect(reference.minor, isTrue);
      expect(
        reference.scale,
        <String>['A', 'B', 'C', 'D', 'E', 'F', 'G'],
      );
      expect(
        reference.diatonic,
        <String>['Am', 'Bdim', 'C', 'Dm', 'Em', 'F', 'G'],
      );
      expect(reference.relative, 'C major');
    });

    test('a bare root — the fallback detector — is read as major', () {
      final reference = keyReference('G')!;
      expect(reference.minor, isFalse);
      expect(reference.display, 'G major');
    });

    test('capo options land on the key, and stay inside seven frets', () {
      final reference = keyReference('F major')!;
      // F is five frets above C and one above E: both are playable, and the
      // shorter reach is offered first.
      expect(reference.capo.first, (1, 'E'));
      expect(reference.capo.map((option) => option.$1), everyElement(lessThanOrEqualTo(7)));
      expect(reference.capo.map((option) => option.$1), everyElement(greaterThanOrEqualTo(1)));
    });

    test('a key that is already an open shape asks for no capo', () {
      expect(keyReference('C major')!.capo.any((option) => option.$2 == 'C'), isFalse);
      expect(keyReference('A minor')!.capo.any((option) => option.$2 == 'Am'), isFalse);
    });

    test('the pentatonic is five notes of the same scale', () {
      final reference = keyReference('E minor')!;
      expect(reference.pentatonic, <String>['E', 'G', 'A', 'B', 'D']);
    });

    test('a key it cannot read opens no sheet', () {
      expect(keyReference(''), isNull);
      expect(keyReference('unknown'), isNull);
    });
  });
}
