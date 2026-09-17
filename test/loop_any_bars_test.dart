import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_marks.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loop any bars, at more speeds.
///
/// "Bars nine to twelve, slower" is the sentence a teacher says more than any
/// other, and until now the smallest thing this app could put on repeat was a
/// whole chorus at one of three speeds (Every Musician, Same Song,
/// 17 September 2026). The downbeats have been in the analysis since
/// migration 0023; this is the first time anybody could use them.
void main() {
  final day = DateTime(2026, 9, 17);

  /// Twelve bars of half a second each, which is the grid everything below
  /// counts against: bar 1 starts at 0, bar 9 at 4000, and bar 12 runs to the
  /// end of the recording.
  const downbeats = <int>[0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500];
  const sections = <StructureSection>[
    StructureSection(startMs: 0, endMs: 3000, label: 'Verse'),
    StructureSection(startMs: 3000, endMs: 6000, label: 'Chorus'),
  ];

  group('bars come from the downbeats', () {
    test('a bar starts on its downbeat and ends on the next one', () {
      expect(barStartMs(1, downbeats), 0);
      expect(barStartMs(9, downbeats), 4000);
      expect(barEndMs(9, downbeats), 4500);
      // The last bar has no next downbeat, so it ends where the recording
      // does.
      expect(barEndMs(12, downbeats, songEndMs: 6000), 6000);
      // Without a length to go on, the last bar is as long as the one before.
      expect(barEndMs(12, downbeats), 6000);
    });

    test('a run of bars is snapped to the downbeats either side of it', () {
      final loop = barLoop(firstBar: 9, lastBar: 12, downbeatsMs: downbeats, songEndMs: 6000)!;
      expect(loop.startMs, 4000);
      expect(loop.endMs, 6000);
      expect(loop.label, 'Bars 9–12');
      expect(loop.isBars, isTrue);
      // One bar is a run of one, and says so in the singular.
      expect(barLoop(firstBar: 3, lastBar: 3, downbeatsMs: downbeats)!.label, 'Bar 3');
    });

    test('bars outside the song, or the wrong way round, still make a loop', () {
      final past = barLoop(firstBar: 11, lastBar: 40, downbeatsMs: downbeats, songEndMs: 6000)!;
      expect(past.label, 'Bars 11–12');
      final backwards = barLoop(firstBar: 12, lastBar: 9, downbeatsMs: downbeats, songEndMs: 6000)!;
      expect(backwards.label, 'Bars 9–12');
      expect(backwards.startMs, 4000);
    });

    test('no downbeats, no bars', () {
      expect(barLoop(firstBar: 1, lastBar: 4, downbeatsMs: const <int>[]), isNull);
      expect(loopFor(4000, 6000, sections: sections), isNull,
          reason: 'a time range that is not a part of the song is nothing without a grid');
    });

    test('a time range reads back as the part it is, or the bars it covers', () {
      expect(loopFor(3000, 6000, sections: sections, downbeatsMs: downbeats)?.label, 'Chorus');
      final bars = loopFor(4000, 6000, sections: sections, downbeatsMs: downbeats)!;
      expect(bars.label, 'Bars 9–12');
      expect(bars.startMs, 4000);
      expect(bars.endMs, 6000, reason: 'the follower loops exactly where the leader does');
      // The end is where the loop turns round, not a moment it plays, so it
      // does not drag in the bar after.
      expect(loopFor(4000, 4500, sections: sections, downbeatsMs: downbeats)?.label, 'Bar 9');
      // A pickup ahead of the first downbeat is not bar 1 and not bar 0.
      expect(loopFor(-200, 400, sections: sections, downbeatsMs: downbeats), isNull);
    });

    test('past the end of a bar loop, back to its first bar', () {
      final loop = barLoop(firstBar: 9, lastBar: 12, downbeatsMs: downbeats, songEndMs: 6000);
      expect(keepInside(const Duration(milliseconds: 5200), loop), const Duration(milliseconds: 5200));
      expect(keepInside(const Duration(milliseconds: 6000), loop), const Duration(milliseconds: 4000));
    });
  });

  group('a bar loop travels', () {
    test('Follow me sends it as two times, and it arrives as bars', () {
      final bars = barLoop(firstBar: 9, lastBar: 12, downbeatsMs: downbeats, songEndMs: 6000)!;
      final sent = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 4200,
        rate: 0.7,
        sentAt: day.millisecondsSinceEpoch,
        loopStartMs: bars.startMs,
        loopEndMs: bars.endMs,
      );
      final heard = FollowState.fromJson(sent.toJson())!;
      expect(heard.looping, isTrue);
      expect(heard.rate, 0.7);

      // The leader never sends the words "Bars 9–12"; the follower works them
      // out from its own copy of the same analysis.
      final followed = loopFor(
        heard.loopStartMs,
        heard.loopEndMs,
        sections: sections,
        downbeatsMs: downbeats,
      )!;
      expect(followed, bars);
      expect(followed.label, 'Bars 9–12');
    });

    test('a slower speed still rounds the loop back to its start', () {
      final bars = barLoop(firstBar: 9, lastBar: 12, downbeatsMs: downbeats, songEndMs: 6000)!;
      final state = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 5800,
        rate: 0.7,
        sentAt: 1000,
        loopStartMs: bars.startMs,
        loopEndMs: bars.endMs,
      );
      // 700ms of song later, which is past the end of bar 12.
      expect(followTargetMs(state, 2000), 4500);
    });
  });

  group('what it leaves behind', () {
    test('a practice mark says the bars and the speed', () {
      const part = PracticePart(
        label: 'Bars 9–12',
        rate: 0.7,
        seconds: 240,
        startMs: 4000,
        endMs: 6000,
      );
      expect(practiceSaid(part), 'Bars 9–12 at 70%');
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-bars',
      roomId: 'room',
      accountId: 'account',
      title: 'Weathervane',
      createdAt: day,
      updatedAt: day,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-bars',
          authorId: 'u2',
          authorName: 'Jess',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: day,
          position: 1,
        ),
      ],
    );
    const bundle = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-bars',
        fileId: 'file',
        storagePath: 'room/song-bars/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 6000,
        downbeatsMs: downbeats,
        transcriptText: 'turning in the wind',
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
          TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
          TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
          TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
        ],
        structureSections: sections,
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    Future<void> sized(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('pick a run of bars, and it is what is on repeat', (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      // It opens on the bars the song is sitting in, four of them, rather
      // than on bar 1 of a song somebody has already scrolled through.
      expect(find.text('Bars 1–4'), findsOneWidget);

      tester
          .widget<RangeSlider>(find.byKey(const Key('live_bar_range')))
          .onChanged!(const RangeValues(9, 12));
      await tester.pump();
      expect(find.text('Bars 9–12'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_bar_loop_apply')));
      await tester.pumpAndSettle();

      // The chip says what is on repeat, and the song has jumped to bar 9 --
      // 4s of 6s.
      expect(find.text('Bars 9–12'), findsOneWidget);
      expect(
        tester.widget<ChoiceChip>(find.descendant(
          of: find.byKey(const Key('live_loop_bars')),
          matching: find.byType(ChoiceChip),
        )).selected,
        isTrue,
      );
      expect(tester.widget<Slider>(find.byKey(const Key('live_seek'))).value, closeTo(0.667, 0.01));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a lesson on four bars is what the mark remembers', (tester) async {
      await sized(tester);
      final kept = <PracticeMark>[];
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: bundle,
          me: 'u2',
          keepPractice: kept.add,
          // Reopened from a mark that already held these bars: a start and an
          // end, with the name worked out again from the downbeats.
          practise: const PracticePart(
            label: 'Bars 9–12',
            rate: 0.7,
            seconds: 240,
            startMs: 4000,
            endMs: 6000,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('70%'), findsOneWidget);
      expect(find.text('Bars 9–12'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 25));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(kept, hasLength(1));
      expect(practiceWorked(kept.single), 'Bars 9–12 at 70%');
    });
  });
}
