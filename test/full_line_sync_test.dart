import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('musician section labels are not treated as lyric lines', () {
    final now = DateTime(2026, 8, 16);
    final verse = _line(now, 'section-1', 'Verse 1:', 1);
    final solo = _line(now, 'section-2', 'Guitar Solo', 2);

    expect(isSheetSection(verse), isTrue);
    expect(isSheetSection(solo), isTrue);
    expect(cleanSheetSection('Verse 1:'), 'Verse 1');
  });

  test('Tap Sync preserves an intro and a long instrumental gap', () {
    final now = DateTime(2026, 8, 16);
    final lyrics = <Contribution>[
      _line(now, 'line-1', 'First sung line', 1),
      _line(now, 'line-2', 'Second sung line', 2),
      _line(now, 'line-3', 'Back after the solo', 3),
    ];

    final cues = buildManualLyricCuesFromStarts(
      lyrics: lyrics,
      startsMs: const <int>[10000, 15000, 45000],
      durationMs: 60000,
    );

    expect(cues.first.startMs, 10000);
    expect(cues[1].endMs, 44960);
    expect(cues.last.startMs, 45000);
    expect(cues.every((cue) => cue.isManual), isTrue);
  });

  testWidgets('a complete sung phrase stays on one visual row', (tester) async {
    const line = MusicianSheetLine(
      contributionId: 'line-1',
      body: "You don't always get",
      section: false,
      startMs: 1000,
      endMs: 5000,
      chords: <ChordCue>[
        ChordCue(
          startMs: 1000,
          endMs: 2500,
          chord: 'D',
          confidence: 0.8,
        ),
        ChordCue(
          startMs: 3000,
          endMs: 5000,
          chord: 'G',
          confidence: 0.8,
        ),
      ],
      approximateTiming: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: MusicianChordLyricLine(
              line: line,
              transpose: 0,
              fontScale: 1,
              showChords: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final positions = <Offset>[
      tester.getTopLeft(find.text('You')),
      tester.getTopLeft(find.text("don't")),
      tester.getTopLeft(find.text('always')),
      tester.getTopLeft(find.text('get')),
    ];
    expect(positions.map((position) => position.dy).toSet(), hasLength(1));
    expect(positions[0].dx, lessThan(positions[1].dx));
    expect(positions[1].dx, lessThan(positions[2].dx));
    expect(positions[2].dx, lessThan(positions[3].dx));
  });
}

Contribution _line(
  DateTime now,
  String id,
  String body,
  double position,
) {
  return Contribution(
    id: id,
    projectId: 'song-1',
    authorId: 'user-1',
    authorName: 'Taylor',
    body: body,
    colorValue: 0xFFFF8A4C,
    createdAt: now,
    position: position,
  );
}
