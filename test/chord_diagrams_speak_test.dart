import 'package:colabroom/features/workspace/guitar_chord_diagram.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chord diagram is a picture, and a picture is nothing at all to a screen
/// reader — a `CustomPaint` contributes no semantics whatsoever, so the
/// shapes sheet was six blank rectangles.
///
/// Every Musician, Same Song, 17 September 2026: schools and universities
/// have to meet WCAG 2.1 AA, and SC 1.1.1 asks every non-text thing that
/// carries meaning for a text alternative. These are the readings, and they
/// are the wording a teacher would use out loud.
void main() {
  group('the shape, string by string', () {
    test('an open G, low string to high', () {
      expect(
        chordDiagramReading(const ChordDiagramData(
          name: 'G',
          spokenName: 'G major',
          frets: <int>[3, 2, 0, 0, 0, 3],
        )),
        'G major. Low E, 3rd fret. A, 2nd fret. D, open. G, open. B, open. '
        'High E, 3rd fret.',
      );
    });

    test('a muted string is said, not skipped', () {
      // C major: the low E is not played at all, and a reading that quietly
      // left it out would have somebody strumming six strings.
      final reading = chordDiagramReading(const ChordDiagramData(
        name: 'C',
        spokenName: 'C major',
        frets: <int>[-1, 3, 2, 0, 1, 0],
      ));
      expect(reading, startsWith('C major. Low E, muted. A, 3rd fret.'));
      expect(reading, endsWith('B, 1st fret. High E, open.'));
    });

    test('a bare name is used when nobody gave a spoken one', () {
      expect(
        chordDiagramReading(const ChordDiagramData(
          name: 'Em',
          frets: <int>[0, 2, 2, 0, 0, 0],
        )),
        startsWith('Em. Low E, open. A, 2nd fret.'),
      );
    });

    test('frets are where the hand goes, not where the drawing starts', () {
      // The E shape at the 5th fret draws as 1-3-3-2-1-1 with "5fr" beside
      // it. Reading those numbers out would send somebody to the wrong end
      // of the neck.
      final reading = chordDiagramReading(const ChordDiagramData(
        name: 'A',
        spokenName: 'A major',
        frets: <int>[1, 3, 3, 2, 1, 1],
        baseFret: 5,
      ));
      expect(reading, contains('Low E, 5th fret.'));
      expect(reading, contains('A, 7th fret.'));
      expect(reading, contains('G, 6th fret.'));
      expect(reading, isNot(contains('1st fret')));
    });
  });

  group('the finger the dots cannot draw', () {
    test('an E-shape barre is said before the strings', () {
      expect(
        chordDiagramReading(const ChordDiagramData(
          name: 'A',
          spokenName: 'A major',
          frets: <int>[1, 3, 3, 2, 1, 1],
          baseFret: 5,
        )),
        startsWith('A major. Barre at the 5th fret, Low E to High E. '
            'Low E, 5th fret.'),
      );
    });

    test('an A-shape barre starts at the A string, not the low E', () {
      // Only two strings actually sound at the barre fret here, which is why
      // the rule counts the span rather than the dots.
      expect(
        chordDiagramReading(const ChordDiagramData(
          name: 'D',
          spokenName: 'D major',
          frets: <int>[-1, 1, 3, 3, 3, 1],
          baseFret: 5,
        )),
        startsWith('D major. Barre at the 5th fret, A to High E. '
            'Low E, muted.'),
      );
    });

    test('an open chord is not a barre because two frets match', () {
      // A major holds three strings at the 2nd fret and D major holds two,
      // and neither is one finger laid flat.
      for (final open in const <List<int>>[
        <int>[-1, 0, 2, 2, 2, 0],
        <int>[-1, -1, 0, 2, 3, 2],
        <int>[0, 2, 2, 2, 0, 0],
        <int>[3, 2, 0, 0, 0, 2],
      ]) {
        expect(
          chordDiagramReading(ChordDiagramData(name: 'x', frets: open)),
          isNot(contains('Barre')),
          reason: '$open',
        );
      }
    });
  });

  testWidgets('the drawn diagram carries the reading', (tester) async {
    const chord = ChordDiagramData(
      name: 'G',
      spokenName: 'G major',
      frets: <int>[3, 2, 0, 0, 0, 3],
    );
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: GuitarChordDiagram(chord: chord)),
    ));

    final semantics = tester.widget<Semantics>(
      find.ancestor(
        of: find.byType(CustomPaint),
        matching: find.byType(Semantics),
      ).first,
    );
    expect(semantics.properties.label, chordDiagramReading(chord));
    expect(semantics.properties.image, isTrue);
  });
}
