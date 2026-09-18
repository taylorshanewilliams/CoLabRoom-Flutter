import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Practising is the daily reason: your own song, playing, with the chart
/// moving, one part on repeat, slowed down until the fingers catch up. The
/// sections and the timing existed for weeks; this is the first time the
/// screen lets somebody use them.
void main() {
  const intro = StructureSection(startMs: 0, endMs: 5000, label: 'Intro');
  const verse = StructureSection(startMs: 5000, endMs: 12000, label: 'Verse');
  const chorus = StructureSection(startMs: 12000, endMs: 20000, label: 'Chorus');

  const chorusLoop = PracticeLoop(startMs: 12000, endMs: 20000, label: 'Chorus');

  group('the rules', () {
    test('past the end of the part on repeat, back to its start', () {
      expect(keepInside(const Duration(seconds: 14), chorusLoop), const Duration(seconds: 14));
      expect(keepInside(const Duration(seconds: 20), chorusLoop), const Duration(seconds: 12));
      expect(keepInside(const Duration(seconds: 25), chorusLoop), const Duration(seconds: 12));
      // Nothing on repeat: nothing moves.
      expect(keepInside(const Duration(seconds: 25), null), const Duration(seconds: 25));
    });

    test('half speed is half the song per tick of the clock', () {
      expect(atRate(const Duration(milliseconds: 100), 0.5), const Duration(milliseconds: 50));
      expect(atRate(const Duration(milliseconds: 100), 0.75), const Duration(milliseconds: 75));
      expect(atRate(const Duration(milliseconds: 100), 1), const Duration(milliseconds: 100));
    });

    test('a part that comes round again is numbered; a one-off is not', () {
      expect(
        sectionChipLabels(const <StructureSection>[intro, verse, chorus, verse, chorus]),
        <String>['Intro', 'Verse 1', 'Chorus 1', 'Verse 2', 'Chorus 2'],
      );
    });

    test('a part the band renamed keeps its name', () {
      const named = StructureSection(
        startMs: 0,
        endMs: 5000,
        label: 'Bridge',
        customLabel: 'The build',
      );
      expect(sectionChipLabels(const <StructureSection>[named, chorus]), <String>['The build', 'Chorus']);
    });

    test('the speeds have names a musician says, and numbers where they do not', () {
      expect(
        practiceRates.map(rateLabel),
        <String>['½', '60%', '70%', '¾', '80%', '90%', '1×'],
      );
    });

    test('the speed steps one at a time, and stops at both ends', () {
      expect(rateStep(1, faster: false), 0.9);
      expect(rateStep(0.8, faster: false), 0.75);
      expect(rateStep(0.75, faster: true), 0.8);
      expect(rateStep(0.5, faster: false), isNull, reason: 'half is as slow as it goes');
      expect(rateStep(1, faster: true), isNull);
      // A rate kept by an older build is not one of these; the arrow still
      // moves the song the way it points, to the nearest speed that way.
      expect(rateStep(0.85, faster: false), 0.8);
      expect(rateStep(0.85, faster: true), 0.9);
      expect(rateStep(0.3, faster: false), isNull);
      expect(rateStep(1.4, faster: true), isNull);
    });
  });

  testWidgets('synced, the song has a speed, its parts, and a bar you can hold',
      (tester) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 9, 14);
    final project = SongProject(
      id: 'song-practise',
      roomId: 'room',
      accountId: 'account',
      title: 'Weathervane',
      createdAt: now,
      updatedAt: now,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-practise',
          authorId: 'user-1',
          authorName: 'Taylor',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: now,
          position: 1,
        ),
      ],
    );
    const analysis = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-practise',
        fileId: 'file',
        storagePath: 'room/song-practise/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 20000,
        transcriptText: 'turning in the wind again',
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 5000, endMs: 5800),
          TranscriptWord(word: 'in', startMs: 5800, endMs: 6100),
          TranscriptWord(word: 'the', startMs: 6100, endMs: 6400),
          TranscriptWord(word: 'wind', startMs: 6400, endMs: 7200),
          TranscriptWord(word: 'again', startMs: 12500, endMs: 13400),
        ],
        structureSections: <StructureSection>[intro, verse, chorus],
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: LivePerformanceScreen(project: project, analysis: analysis),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Synced from the start, because there is a sheet to read from, so the
    // practice row is there before anything is pressed.
    expect(find.byKey(const Key('live_practice_row')), findsOneWidget);
    expect(find.byKey(const Key('live_seek')), findsOneWidget);
    expect(find.byKey(const Key('live_rate')), findsOneWidget);
    expect(find.text('Chorus'), findsOneWidget);
    // This recording was analysed before there was a beat grid, so there is
    // nothing to count bars against and no bar controls at all.
    expect(find.byKey(const Key('live_loop_bars')), findsNothing);

    bool selected(String key) => tester
        .widget<ChoiceChip>(find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(ChoiceChip),
        ))
        .selected;

    // Slowing down is a choice that shows, one step at a time.
    expect(find.text('1×'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_rate_slower')));
    await tester.pump();
    expect(find.text('90%'), findsOneWidget);

    // Tapping a part jumps there: the bar moves to 12s of 20s.
    await tester.tap(find.byKey(const Key('live_loop_2')));
    await tester.pump();
    expect(selected('live_loop_2'), isTrue);
    expect(tester.widget<Slider>(find.byKey(const Key('live_seek'))).value, closeTo(0.6, 0.01));

    // While a part is on repeat the controls stay. On the device, every
    // practice tap had to reveal the bar first because it hid itself four
    // seconds into playing.
    double controlsOpacity() => tester
        .widget<AnimatedOpacity>(find.ancestor(
          of: find.byKey(const Key('live_practice_row')),
          matching: find.byType(AnimatedOpacity),
        ))
        .opacity;
    await tester.tap(find.byKey(const Key('live_play_pause')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(controlsOpacity(), 1.0);

    // Tapping it again is the way out -- and, at full speed with nothing on
    // repeat, the stage behaviour comes back: the bar hides.
    await tester.tap(find.byKey(const Key('live_rate_faster')));
    await tester.pump();
    expect(find.text('1×'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_loop_2')));
    await tester.pump();
    expect(selected('live_loop_2'), isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(controlsOpacity(), 0.0);
    // Back on screen for the rest of the test.
    await tester.tap(find.byKey(const Key('live_lyrics_scroll')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('live_play_pause')));
    await tester.pump();

    // In a manual mode the scroll is the clock and none of this applies.
    await tester.tap(find.text('Slow'));
    await tester.pump();
    expect(find.byKey(const Key('live_practice_row')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
