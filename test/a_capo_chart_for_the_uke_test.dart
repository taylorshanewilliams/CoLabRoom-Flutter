import 'package:colabroom/services/music_reference.dart';
import 'package:colabroom/services/shape_reading.dart';
import 'package:flutter_test/flutter_test.dart';

/// The capo chart on the key sheet is the instrument's own.
///
/// Every Musician, Same Song, 17 September 2026. #405 scored the "makes these
/// open shapes" row against the ukulele's own grips, but the chart the row
/// stands in was still the guitar's five majors and three minors. Nothing on
/// it was false for a ukulele — all eight of those ring open on a uke as
/// well — but it was short: a uke has an open F, and a uke player in B♭ was
/// never shown the row that would matter most to them.
void main() {
  group('the capo chart is the instrument in your hands', () {
    test('a ukulele in B♭ is shown the fret that puts it on F shapes', () {
      expect(
        capoChart(keyReference('Bb major')!, reading: ShapeReading.ukulele),
        <(int, String)>[(1, 'A'), (3, 'G'), (5, 'F')],
      );
      // The row nobody could reach before: F is five frets under B♭, and it
      // is the chord a uke player has when the band is in the key they dread.
      expect(
        capoChart(keyReference('Bb major')!, reading: ShapeReading.guitar)
            .any((row) => row.$2 == 'F'),
        isFalse,
      );
    });

    /// The rows are derived now rather than written down, so the guitar's are
    /// pinned here to the note: the derivation has to land on exactly the
    /// five majors and three minors the chart has printed since the Toolbox
    /// shipped, or a guitarist has had their sheet changed under them.
    test("a guitarist's chart is the chart it has always been", () {
      expect(
        capoChart(keyReference('Bb major')!, reading: ShapeReading.guitar),
        <(int, String)>[(1, 'A'), (3, 'G'), (6, 'E')],
      );
      expect(
        capoChart(keyReference('C major')!, reading: ShapeReading.guitar),
        <(int, String)>[(3, 'A'), (5, 'G')],
      );
      expect(
        capoChart(keyReference('F major')!, reading: ShapeReading.guitar),
        <(int, String)>[(1, 'E'), (3, 'D'), (5, 'C')],
      );
      expect(
        capoChart(keyReference('A minor')!, reading: ShapeReading.guitar),
        <(int, String)>[(5, 'Em'), (7, 'Dm')],
      );
      expect(
        capoChart(keyReference('C minor')!, reading: ShapeReading.guitar),
        <(int, String)>[(3, 'Am')],
      );
      // And across all twelve keys it names those eight and nothing else.
      expect(
        _shapesNamed(ShapeReading.guitar, minor: false),
        <String>{'C', 'D', 'E', 'G', 'A'},
      );
      expect(
        _shapesNamed(ShapeReading.guitar, minor: true),
        <String>{'Dm', 'Em', 'Am'},
      );
    });

    /// What the derivation produced for the shorter instrument: a key is on
    /// the chart when its own tonic chord is an open grip on that instrument.
    test('a ukulele is offered the ukulele\'s own keys', () {
      expect(
        _shapesNamed(ShapeReading.ukulele, minor: false),
        <String>{'C', 'D', 'E', 'F', 'G', 'A'},
      );
      expect(
        _shapesNamed(ShapeReading.ukulele, minor: true),
        <String>{'Cm', 'C#m', 'Dm', 'Em', 'Fm', 'F#m', 'Gm', 'Am'},
      );
    });

    /// The names are spelled by the house rule rather than by whichever key
    /// the uke table happens to be filed under, which is the same fix #405
    /// made to the row above the chart: the open minor grip on pitch 1 is
    /// stored as D♭m and every chart in the world calls that chord C♯m.
    test('a ukulele row is spelled the way the sheet spells chords', () {
      expect(
        capoChart(keyReference('D minor')!, reading: ShapeReading.ukulele),
        contains((1, 'C#m')),
      );
      expect(
        capoChart(keyReference('B minor')!, reading: ShapeReading.ukulele),
        contains((5, 'F#m')),
      );
    });

    test('every key a ukulele row names rings open on a ukulele', () {
      for (final minor in <bool>[false, true]) {
        for (final shape in _shapesNamed(ShapeReading.ukulele, minor: minor)) {
          final grips = ukuleleShapesFor(shape);
          expect(grips, isNotEmpty, reason: '$shape has no ukulele grip');
          expect(
            grips.first.frets,
            contains(0),
            reason: '$shape is fretted on every string',
          );
          expect(
            grips.first.hint,
            'Open position',
            reason: '$shape is not drawn as an open shape',
          );
        }
      }
    });

    /// A capo high on a short neck is a different proposition. The chart is
    /// not advice — it is arithmetic somebody picks from — so it reaches one
    /// fret past the fret #405 stopped the offer at, far enough to put B♭ on
    /// F shapes and no further.
    test('no ukulele row is past the 5th fret, nor a guitar row past the 7th',
        () {
      for (final key in _theTwentyFour) {
        final reference = keyReference(key)!;
        for (final (fret, _)
            in capoChart(reference, reading: ShapeReading.ukulele)) {
          expect(fret, inInclusiveRange(1, 5), reason: key);
        }
        for (final (fret, _)
            in capoChart(reference, reading: ShapeReading.guitar)) {
          expect(fret, inInclusiveRange(1, 7), reason: key);
        }
      }
    });

    test('a piano and a bass are shown no chart at all', () {
      for (final key in _theTwentyFour) {
        final reference = keyReference(key)!;
        expect(capoChart(reference, reading: ShapeReading.piano), isEmpty);
        expect(capoChart(reference, reading: ShapeReading.bass), isEmpty);
      }
    });

    test('a key that already sits on an open shape gets no row for itself', () {
      expect(
        capoChart(keyReference('F major')!, reading: ShapeReading.ukulele)
            .any((row) => row.$2 == 'F'),
        isFalse,
      );
      expect(
        capoChart(keyReference('G minor')!, reading: ShapeReading.ukulele)
            .any((row) => row.$2 == 'Gm'),
        isFalse,
      );
    });
  });
}

/// Every shape key the chart can name for an instrument, gathered over all
/// twelve keys of a mode — which is the derivation's own answer, read back.
Set<String> _shapesNamed(ShapeReading reading, {required bool minor}) {
  final named = <String>{};
  for (var pitch = 0; pitch < 12; pitch += 1) {
    final key = '${noteName(pitch, flats: false)} ${minor ? 'minor' : 'major'}';
    for (final (_, shape) in capoChart(keyReference(key)!, reading: reading)) {
      named.add(shape);
    }
  }
  return named;
}

const List<String> _theTwentyFour = <String>[
  'C major', 'C# major', 'D major', 'D# major', 'E major', 'F major',
  'F# major', 'G major', 'G# major', 'A major', 'A# major', 'B major',
  'C minor', 'C# minor', 'D minor', 'D# minor', 'E minor', 'F minor',
  'F# minor', 'G minor', 'G# minor', 'A minor', 'A# minor', 'B minor',
];
