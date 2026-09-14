import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pipeline has known when every word starts since the first sheet was
/// made, and the screen lit whole lines. Now the word being sung is gold,
/// the ones already sung stay white, and the ones to come wait.
void main() {
  group('which word is being sung', () {
    const starts = <int>[1000, 1600, 2300];

    test('is the last one that has started', () {
      expect(wordAt(starts, 999, 3), isNull);
      expect(wordAt(starts, 1000, 3), 0);
      expect(wordAt(starts, 1599, 3), 0);
      expect(wordAt(starts, 1600, 3), 1);
      expect(wordAt(starts, 9000, 3), 2);
    });

    test('refuses when the timing does not fit the words, or is missing', () {
      // The same refusal chordPlacementsForLine makes: a highlight on the
      // wrong word is worse than none.
      expect(wordAt(starts, 2000, 4), isNull);
      expect(wordAt(null, 2000, 3), isNull);
      expect(wordAt(starts, null, 3), isNull);
      expect(wordAt(const <int>[], 2000, 0), isNull);
    });
  });

  testWidgets('on the active line the words are coloured by the moment',
      (tester) async {
    const line = MusicianSheetLine(
      contributionId: null,
      body: 'turning in the wind',
      section: false,
      startMs: 1000,
      endMs: 3000,
      chords: <ChordCue>[],
      approximateTiming: false,
      wordStartsMs: <int>[1000, 1500, 1800, 2200],
    );

    // Nearest first: Material wraps the whole body in one of these too.
    Color colorOf(String word) => tester
        .widget<AnimatedDefaultTextStyle>(find
            .ancestor(
              of: find.text(word),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .first)
        .style
        .color!;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MusicianChordLyricLine(
          line: line,
          transpose: 0,
          fontScale: 1.5,
          showChords: false,
          liveMode: true,
          active: true,
          elapsedMs: 1900,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 1900ms: "the" (1800) has started, "wind" (2200) has not.
    expect(colorOf('the'), AppColors.gold);
    expect(colorOf('turning'), Colors.white);
    expect(colorOf('in'), Colors.white);
    expect(colorOf('wind').a, lessThan(0.6));
  });

  testWidgets('a line without word timing is lit as a whole', (tester) async {
    const guessed = MusicianSheetLine(
      contributionId: 'line-1',
      body: 'turning in the wind',
      section: false,
      startMs: 1000,
      endMs: 3000,
      chords: <ChordCue>[],
      approximateTiming: true,
    );

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MusicianChordLyricLine(
          line: guessed,
          transpose: 0,
          fontScale: 1.5,
          showChords: false,
          liveMode: true,
          active: true,
          elapsedMs: 1900,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    for (final word in <String>['turning', 'in', 'the', 'wind']) {
      final style = tester
          .widget<AnimatedDefaultTextStyle>(find
              .ancestor(
                of: find.text(word),
                matching: find.byType(AnimatedDefaultTextStyle),
              )
              .first)
          .style;
      expect(style.color, Colors.white);
    }
  });
}
