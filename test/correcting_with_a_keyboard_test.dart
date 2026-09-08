import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Correcting a sheet with a keyboard.
///
/// Everything the analysis produces is a guess — which chord, which word it
/// sits over, where the beat is. The phone is good at catching a song and
/// fine at reading one, and bad at correcting one, because correcting is
/// aiming and a fingertip is blunt. So the touch path is a modal with a
/// chord picker in it, and that stays.
///
/// The correction people actually make most often is not "this is the wrong
/// chord", it is "this chord is over the wrong word" — one keystroke's worth
/// of intent that currently costs a modal. [chordsInReadingOrder] is what
/// lets the arrow keys ask a question about the whole page rather than one
/// line, and it is the part with logic in it worth pinning down.
MusicianSheetLine _line(
  String body, {
  required int startMs,
  required int endMs,
  List<ChordCue> chords = const <ChordCue>[],
  bool section = false,
}) {
  return MusicianSheetLine(
    contributionId: body,
    body: body,
    section: section,
    startMs: startMs,
    endMs: endMs,
    chords: chords,
    approximateTiming: false,
  );
}

ChordCue _cue(String chord, int startMs) => ChordCue(
      startMs: startMs,
      endMs: startMs + 500,
      chord: chord,
      confidence: 0.9,
    );

void main() {
  test('reading order walks the page, not the line', () {
    final lines = <MusicianSheetLine>[
      _line('Verse', startMs: 0, endMs: 1, section: true),
      _line('one two three four',
          startMs: 0,
          endMs: 4000,
          chords: <ChordCue>[_cue('C', 0), _cue('G', 2000)]),
      _line('five six seven eight',
          startMs: 4000,
          endMs: 8000,
          chords: <ChordCue>[_cue('Am', 4000)]),
    ];

    final order = chordsInReadingOrder(lines);

    expect(order.map((e) => e.chord.chord).toList(), <String>['C', 'G', 'Am'],
        reason: 'down-arrow has to cross a line boundary, so the order is a '
            'property of the page');
    expect(order.first.wordIndex, 0);
    expect(order.last.line.body, 'five six seven eight');
  });

  test('a section heading holds no chords and is skipped', () {
    final lines = <MusicianSheetLine>[
      _line('Chorus', startMs: 0, endMs: 1, section: true),
      _line('', startMs: 0, endMs: 1),
      _line('a b', startMs: 0, endMs: 2000, chords: <ChordCue>[_cue('D', 0)]),
    ];

    final order = chordsInReadingOrder(lines);

    expect(order.length, 1,
        reason: 'stepping onto a heading would be a selection nobody can '
            'move, which reads as the keys being broken');
    expect(order.single.chord.chord, 'D');
  });

  test('a line with no chords contributes nothing to step through', () {
    final lines = <MusicianSheetLine>[
      _line('humming here', startMs: 0, endMs: 2000),
      _line('words now', startMs: 2000, endMs: 4000,
          chords: <ChordCue>[_cue('F', 2000)]),
    ];

    expect(chordsInReadingOrder(lines).length, 1);
  });

  testWidgets('a held chord is visible, and an unheld one is not',
      (tester) async {
    final cue = _cue('C', 0);
    final line = _line('one two', startMs: 0, endMs: 2000,
        chords: <ChordCue>[cue]);

    Future<void> pump(int? selected) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MusicianChordLyricLine(
            line: line,
            transpose: 0,
            fontScale: 1,
            showChords: true,
            editable: true,
            selectedChordStartMs: selected,
          ),
        ),
      ));
      await tester.pump();
    }

    // The selection is keyed on startMs rather than id, because ChordCue.id
    // is nullable and a start is not — and startMs is what the save call
    // already uses to find the row.
    await pump(null);
    final unheld = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => (c.decoration as BoxDecoration?)?.border != null)
        .length;

    await pump(cue.startMs);
    final held = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => (c.decoration as BoxDecoration?)?.border != null)
        .length;

    expect(unheld, 0);
    expect(held, 1,
        reason: 'arrow keys moving something invisible is worse than not '
            'having arrow keys');
  });
}
