import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The note under each word of the line being sung.
///
/// The pipeline hears the tune now (#227); this is the first place a
/// singer sees it while singing. The rules that keep it honest: a word's
/// note is the one that fills most of the word, not the one at its first
/// instant (that is a consonant); a word the tracker heard nothing in gets
/// a blank, not a guess; a line that cannot be lit word by word carries no
/// notes at all; and only the line being sung has them.
MelodyNote _note(int startMs, int endMs, int midi) =>
    MelodyNote(startMs: startMs, endMs: endMs, midi: midi);

void main() {
  // "turning in the wind", sung G4 A4 A4 B4, with the consonant at the start
  // of each word unvoiced and a breath before the last one.
  final melody = Melody(notes: <MelodyNote>[
    _note(1060, 1480, 67), // tur-ning
    _note(1540, 1780, 69), // in
    _note(1840, 2150, 69), // the
    _note(2260, 2900, 71), // wind
  ]);
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

  group('which note a word is sung on', () {
    test('is the note that fills most of the word, not its first instant', () {
      // 1000 ms is the "t" of "turning": nothing voiced. The word is G4.
      expect(melody.noteAt(1000), isNull);
      expect(melody.noteWithin(1000, 1500)!.label, 'G4');
      expect(melody.noteWithin(2200, 3000)!.label, 'B4');
    });

    test('is nothing where nothing was sung', () {
      expect(melody.noteWithin(1480, 1540), isNull);
      expect(melody.noteWithin(5000, 6000), isNull);
    });

    test('the line gets one per word, the last word running to the line end', () {
      expect(
        notesForWords(melody, line.wordStartsMs, line.endMs, 4),
        <String?>['G4', 'A4', 'A4', 'B4'],
      );
    });

    test('a word with no voice in it is a blank among notes', () {
      final gappy = Melody(notes: <MelodyNote>[_note(1060, 1480, 67), _note(2260, 2900, 71)]);
      expect(
        notesForWords(gappy, line.wordStartsMs, line.endMs, 4),
        <String?>['G4', null, null, 'B4'],
      );
    });

    test('no melody, no word timing, or a mismatch means no notes at all', () {
      expect(notesForWords(null, line.wordStartsMs, line.endMs, 4), isEmpty);
      expect(notesForWords(melody, null, line.endMs, 4), isEmpty);
      expect(notesForWords(melody, const <int>[1000, 1500], line.endMs, 4), isEmpty);
      expect(notesForWords(const Melody(notes: <MelodyNote>[]), line.wordStartsMs, line.endMs, 4), isEmpty);
    });
  });

  Future<void> pumpLine(WidgetTester tester, {required bool active, Melody? tune, int? elapsedMs}) async {
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: MusicianChordLyricLine(
          line: line,
          transpose: 0,
          fontScale: 1.5,
          showChords: false,
          liveMode: true,
          active: active,
          elapsedMs: elapsedMs,
          melody: tune,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Color noteColor(WidgetTester tester, String note) => tester
      .widget<AnimatedDefaultTextStyle>(
        find.ancestor(of: find.text(note), matching: find.byType(AnimatedDefaultTextStyle)).first,
      )
      .style
      .color!;

  testWidgets('the line being sung carries its notes, the sung one in gold', (tester) async {
    await pumpLine(tester, active: true, tune: melody, elapsedMs: 1900);
    expect(tester.takeException(), isNull);
    // Two A4s (in, the) and one each of the others: four notes, one per word.
    expect(find.text('G4'), findsOneWidget);
    expect(find.text('A4'), findsNWidgets(2));
    expect(find.text('B4'), findsOneWidget);
    // 1900 ms is "the", the third word: its note is the lit one.
    expect(noteColor(tester, 'G4'), isNot(AppColors.gold));
    expect(noteColor(tester, 'B4'), isNot(AppColors.gold));
    final lit = find.text('A4').evaluate().map((element) {
      final styled = element.findAncestorWidgetOfExactType<AnimatedDefaultTextStyle>();
      return styled!.style.color;
    });
    expect(lit, contains(AppColors.gold));
  });

  testWidgets('a line that is not being sung carries no notes', (tester) async {
    await pumpLine(tester, active: false, tune: melody);
    expect(find.text('G4'), findsNothing);
    expect(find.text('A4'), findsNothing);
  });

  testWidgets('without a tune the words are exactly as they were', (tester) async {
    await pumpLine(tester, active: true, elapsedMs: 1900);
    expect(find.text('G4'), findsNothing);
    expect(find.text('the'), findsOneWidget);
  });
}
