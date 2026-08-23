import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Live mode exposes chord editing without leaving performance', (
    tester,
  ) async {
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
          // Sections are explicit now — a `[Bracketed]` body with
          // ContributionKind.section — rather than inferred from a trailing
          // colon, which is what this fixture still used.
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
    // Deliberately not `ready`: a ready bundle switches Live mode to its
    // Song Sheet source, which renders the analysis transcript and ignores
    // workspace lyrics entirely. This test is about placing chords onto the
    // project's own typed lines ('Verse 1:' and 'line-1'), which is the
    // workspace source — so the reference stays mid-analysis.
    const analysis = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-live',
        fileId: 'file-live',
        storagePath: 'room/song/reference.wav',
        displayName: 'reference.wav',
        state: SongAnalysisState.processing,
        durationMs: 12000,
        musicalKey: 'D',
      ),
      lyricCues: <LyricSyncCue>[
        LyricSyncCue(
          contributionId: 'line-1',
          startMs: 2500,
          endMs: 8500,
          confidence: 1,
          source: 'manual',
        ),
      ],
      chordCues: <ChordCue>[
        ChordCue(
          id: 5,
          startMs: 2500,
          endMs: 5000,
          chord: 'D',
          confidence: 1,
          source: 'manual',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        // `initialAnalysis`/`startSynced` were renamed away — the screen takes
        // `analysis` and works out for itself whether it has real per-line
        // timing to sync to. This kept referencing the old names because
        // nothing in CI ever ran the suite.
        home: LivePerformanceScreen(
          project: project,
          analysis: analysis,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('VERSE 1'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.byKey(const Key('live_edit_chords')), findsOneWidget);
    expect(find.byKey(const Key('live_tap_sync')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live_edit_chords')));
    await tester.pumpAndSettle();

    expect(find.text('LIVE · EDIT CHORDS'), findsOneWidget);
    expect(find.byKey(const Key('place_chord_line-1_0')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
