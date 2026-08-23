import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// This file used to assert that Live mode exposed chord editing in place,
// via `live_edit_chords` / `live_tap_sync`. Neither key exists anywhere in
// the app, and neither appears in this repository's history — the test was
// carried over from before the current codebase and had been failing
// silently the whole time, because nothing in CI ran the suite.
//
// Replaced with coverage of what Live actually does today: render the
// project's lyrics for performance. If in-Live chord editing is meant to
// come back, it needs building, not a test re-pointed at it.
void main() {
  testWidgets('Live mode renders the song lyrics for performance', (tester) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 8, 16);
    final project = SongProject(
      id: 'song-live',
      roomId: 'room-live',
      accountId: 'account-live',
      title: 'Mountains',
      createdAt: now,
      updatedAt: now,
      contributions: <Contribution>[
        Contribution(
          id: 'section-1',
          projectId: 'song-live',
          authorId: 'user-1',
          authorName: 'Taylor',
          body: '[Verse 1]',
          kind: ContributionKind.section,
          colorValue: 0xFFFF8A4C,
          createdAt: now,
          position: 1,
        ),
        Contribution(
          id: 'line-1',
          projectId: 'song-live',
          authorId: 'user-1',
          authorName: 'Taylor',
          body: "You don't always get",
          colorValue: 0xFFFF8A4C,
          createdAt: now,
          position: 2,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: LivePerformanceScreen(project: project),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Lyrics render word by word so chords can sit above individual words.
    expect(find.text('You'), findsOneWidget);
    expect(find.textContaining('Verse'), findsWidgets);

    // Live runs a ticker; tearing the tree down must cancel it cleanly
    // rather than leave a timer firing after dispose.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
