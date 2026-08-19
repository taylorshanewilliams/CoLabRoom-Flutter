import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plain musician section labels are not treated as lyrics', () {
    final now = DateTime(2026, 8, 16);
    for (final value in <String>[
      'Verse 1:',
      'CHORUS',
      'Pre-Chorus',
      'Bridge:',
      'Guitar Solo',
      'Instrumental',
      'Outro',
    ]) {
      expect(
        isSheetSection(_line(now, id: value, body: value, position: 1)),
        isTrue,
        reason: '$value should be a section heading',
      );
    }
    expect(
      isSheetSection(
        _line(
          now,
          id: 'lyric',
          body: "You don't always get what you're owed",
          position: 2,
        ),
      ),
      isFalse,
    );
  });

  test('Tap Sync preserves a long instrumental gap between lyric lines', () {
    final now = DateTime(2026, 8, 16);
    final lyrics = <Contribution>[
      _line(now, id: 'one', body: 'First sung line', position: 1),
      _line(now, id: 'two', body: 'Second sung line', position: 2),
      _line(now, id: 'three', body: 'Return after the solo', position: 3),
    ];

    final cues = buildManualLyricCuesFromStarts(
      lyrics: lyrics,
      startsMs: const <int>[5000, 9000, 45000],
      durationMs: 60000,
    );

    expect(cues, hasLength(3));
    expect(cues[0].startMs, 5000);
    expect(cues[1].startMs, 9000);
    expect(cues[1].endMs, 44960);
    expect(cues[2].startMs, 45000);
    expect(cues[2].endMs, 59960);
    expect(cues.every((cue) => cue.source == 'manual'), isTrue);
  });

  testWidgets('editable chord sheet keeps one sung phrase on one row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const line = MusicianSheetLine(
      contributionId: 'line-1',
      body: "You don't always get",
      section: false,
      startMs: 1000,
      endMs: 5000,
      chords: <ChordCue>[
        ChordCue(
          id: 1,
          startMs: 1000,
          endMs: 2600,
          chord: 'D',
          confidence: 1,
          source: 'manual',
        ),
        ChordCue(
          id: 2,
          startMs: 3200,
          endMs: 5000,
          chord: 'G',
          confidence: 1,
          source: 'manual',
        ),
      ],
      approximateTiming: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: MusicianChordLyricLine(
              line: line,
              transpose: 0,
              fontScale: 1,
              showChords: true,
              editable: true,
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
    expect(
      positions.map((position) => position.dy).toSet(),
      hasLength(1),
      reason: 'The complete sung phrase should remain on one visual row.',
    );
    expect(positions[0].dx, lessThan(positions[1].dx));
    expect(positions[1].dx, lessThan(positions[2].dx));
    expect(positions[2].dx, lessThan(positions[3].dx));
  });
}

Contribution _line(
  DateTime now, {
  required String id,
  required String body,
  required double position,
}) {
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
