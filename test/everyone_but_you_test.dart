import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/play_along.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The band without you.
///
/// The last of the daily-reason slices: the separated parts, summed with
/// one left out, so a musician plays along with everyone else on their own
/// recording. The sum is one file (players drift; a file cannot), turned
/// down rather than clipped, and the chips exist only when there are parts
/// to leave out.
void main() {
  group('summing the parts', () {
    test('adds sample by sample, the longest deciding the length', () {
      final mixed = PlayAlong.sum(<Float64List>[
        Float64List.fromList(<double>[0.1, 0.2, 0.3]),
        Float64List.fromList(<double>[0.1, 0.1]),
      ]);
      expect(mixed.length, 3);
      expect(mixed[0], closeTo(0.2, 1e-9));
      expect(mixed[1], closeTo(0.3, 1e-9));
      expect(mixed[2], closeTo(0.3, 1e-9));
    });

    test('turns the whole thing down rather than clipping a chorus', () {
      final mixed = PlayAlong.sum(<Float64List>[
        Float64List.fromList(<double>[0.8, 0.2]),
        Float64List.fromList(<double>[0.8, 0.2]),
      ]);
      // 1.6 would clip; the peak lands on the ceiling and the quiet sample
      // keeps its proportion.
      expect(mixed[0], closeTo(PlayAlong.ceiling, 1e-9));
      expect(mixed[1], closeTo(PlayAlong.ceiling * 0.25, 1e-9));
    });

    test('a quiet mix is left alone', () {
      final mixed = PlayAlong.sum(<Float64List>[Float64List.fromList(<double>[0.3, -0.3])]);
      expect(mixed[0], closeTo(0.3, 1e-9));
      expect(mixed[1], closeTo(-0.3, 1e-9));
    });
  });

  final now = DateTime(2026, 9, 14);
  final project = SongProject(
    id: 'song-band',
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: 'song-band',
        authorId: 'user-1',
        authorName: 'Taylor',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: now,
        position: 1,
      ),
    ],
  );
  const reference = ReferenceTrack(
    projectId: 'song-band',
    fileId: 'file',
    storagePath: 'room/song-band/reference.m4a',
    displayName: 'Weathervane.m4a',
    state: SongAnalysisState.ready,
    durationMs: 6000,
    transcriptText: 'turning in the wind',
    transcriptWords: <TranscriptWord>[
      TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
      TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
      TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
      TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
    ],
  );
  const separated = SongAnalysisBundle(
    reference: reference,
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[],
    stems: <SongStem>[
      SongStem(projectId: 'song-band', kind: StemKind.vocals, storagePath: 'stems/vocals.mp3'),
      SongStem(projectId: 'song-band', kind: StemKind.guitar, storagePath: 'stems/guitar.mp3'),
      SongStem(projectId: 'song-band', kind: StemKind.drums, storagePath: 'stems/drums.mp3'),
    ],
  );
  const whole = SongAnalysisBundle(
    reference: reference,
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[],
  );

  /// Scrolls the practice row until [key] is on screen.
  Future<void> reveal(WidgetTester tester, Key key) async {
    final row = find.descendant(
      of: find.byKey(const Key('live_practice_row')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.byKey(key), 120, scrollable: row.first);
    await tester.pump(const Duration(milliseconds: 60));
  }

  Future<void> boot(
    WidgetTester tester,
    SongAnalysisBundle bundle, {
    Future<String> Function(List<SongStem>, StemKind, void Function(String))? mixer,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LivePerformanceScreen(project: project, analysis: bundle, playAlongMixer: mixer),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('one chip per separated part, and none without parts', (tester) async {
    await boot(tester, whole);
    expect(find.byKey(const Key('live_practice_row')), findsOneWidget);
    expect(find.byKey(const Key('live_without_guitar')), findsNothing);

    await boot(tester, separated);
    // The row is a lazy horizontal list, so the chips to the right of the
    // phone's edge do not exist until it is scrolled -- as a person would.
    await reveal(tester, const Key('live_without_vocals'));
    expect(find.byKey(const Key('live_without_vocals')), findsOneWidget);
    await reveal(tester, const Key('live_without_guitar'));
    expect(find.text('No guitar'), findsOneWidget);
    await reveal(tester, const Key('live_without_drums'));
    expect(find.byKey(const Key('live_without_drums')), findsOneWidget);
    expect(find.byKey(const Key('live_without_bass')), findsNothing);
  });

  testWidgets('leaving a part out asks the mixer for the rest, and says so', (tester) async {
    final asked = <StemKind>[];
    var stemsSeen = 0;
    await boot(tester, separated, mixer: (stems, without, onProgress) async {
      asked.add(without);
      stemsSeen = stems.length;
      onProgress('Mixing the band without the ${without.label.toLowerCase()}…');
      return '/tmp/without-${without.name}.wav';
    });
    await reveal(tester, const Key('live_without_guitar'));
    await tester.tap(find.byKey(const Key('live_without_guitar')));
    await tester.pump();
    await tester.pump();
    expect(asked, <StemKind>[StemKind.guitar]);
    // Every stem is handed over; the mixer decides what to leave out.
    expect(stemsSeen, 3);
    // Something was said while it worked (or about why it could not: there
    // is no audio player in a test, and that is reported, not swallowed).
    expect(find.byKey(const Key('live_mix_note')), findsOneWidget);
  });
}
