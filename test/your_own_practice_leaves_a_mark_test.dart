import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_marks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Your own practice leaves a mark too.
///
/// A followed lesson already left one. But the lesson is one hour of the week
/// and the practising is the other hundred and sixty-seven, most of it with
/// nobody else on the song at all: a part on repeat, slowed down, on a
/// Tuesday. That kept nothing until now (Every Musician, Same Song,
/// 17 September 2026). It keeps the same thing a lesson does, with the
/// person as their own leader, and the card says "Your practice" — never
/// when, never how long for.
void main() {
  final day = DateTime(2026, 9, 17);
  final project = SongProject(
    id: 'song-alone',
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: day,
    updatedAt: day,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: 'song-alone',
        authorId: 'u2',
        authorName: 'Jess',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: day,
        position: 1,
      ),
    ],
  );
  const sections = <StructureSection>[
    StructureSection(startMs: 0, endMs: 3000, label: 'Verse'),
    StructureSection(startMs: 3000, endMs: 6000, label: 'Chorus'),
  ];
  const bundle = SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-alone',
      fileId: 'file',
      storagePath: 'room/song-alone/reference.m4a',
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

  /// Opens Perform on its own — no Follow me session, nobody else on the
  /// song — and returns what it kept on the way out.
  Future<List<PracticeMark>> alone(
    WidgetTester tester, {
    PracticePart? practise,
    Duration playing = const Duration(seconds: 25),
  }) async {
    final kept = <PracticeMark>[];
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LivePerformanceScreen(
        project: project,
        analysis: bundle,
        me: 'u2',
        practise: practise,
        keepPractice: kept.add,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('live_play_pause')));
    await tester.pump();
    await tester.pump(playing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    return kept;
  }

  group('practising on your own', () {
    testWidgets('a part on repeat, slowed, is kept when Perform closes', (tester) async {
      await sized(tester);
      final kept = await alone(
        tester,
        practise: const PracticePart(
          label: 'Chorus',
          rate: 0.75,
          seconds: 60,
          startMs: 3000,
          endMs: 6000,
        ),
      );

      expect(kept, hasLength(1));
      final mark = kept.single;
      expect(mark.projectId, 'song-alone');
      expect(mark.ledBy, 'u2', reason: 'your own practice is led by you');
      expect(mark.note, isNull, reason: 'nobody said anything');
      expect(mark.parts.single.label, 'Chorus');
      expect(mark.parts.single.rate, 0.75);
      expect(mark.parts.single.startMs, 3000);
      expect(practiceWorked(mark), 'Chorus at ¾');
      expect(isYourOwnPractice(mark, me: 'u2'), isTrue);
    });

    testWidgets('a play through at full speed keeps nothing', (tester) async {
      await sized(tester);
      expect(
        await alone(tester),
        isEmpty,
        reason: 'the whole song at full speed is playing it, not working on it',
      );
    });

    testWidgets('a moment of it is passing through, and keeps nothing', (tester) async {
      await sized(tester);
      final kept = await alone(
        tester,
        practise: const PracticePart(
          label: 'Chorus',
          rate: 0.75,
          seconds: 60,
          startMs: 3000,
          endMs: 6000,
        ),
        playing: const Duration(seconds: 8),
      );
      expect(kept, isEmpty);
    });
  });

  group('what the card says', () {
    PracticeMark mark({String? ledBy, String ledByName = 'You', String? note}) => PracticeMark(
          id: 'mark-alone',
          projectId: 'song-alone',
          ledBy: ledBy,
          ledByName: ledByName,
          note: note,
          parts: const <PracticePart>[
            PracticePart(label: 'Chorus 2', rate: 0.75, seconds: 90, startMs: 3000, endMs: 6000),
          ],
          updatedAt: day,
        );

    test('your own practice says so, and a lesson still says who from', () {
      expect(practiceFrom(mark(ledBy: 'u2'), me: 'u2'), 'Your practice');
      expect(practiceFrom(mark(ledBy: 'u1', ledByName: 'Taylor'), me: 'u2'), 'From Taylor');
      expect(practiceFrom(mark(ledByName: 'Taylor'), me: 'u2'), 'From Taylor',
          reason: 'a leader whose account is gone is still not you');
      expect(isYourOwnPractice(mark(ledBy: ''), me: ''), isFalse,
          reason: 'not knowing who you are is not the same as it being yours');
    });

    test('nothing it says is about when', () {
      final said = '${practiceFrom(mark(ledBy: 'u2'), me: 'u2')} · '
          '${practiceWorked(mark(ledBy: 'u2'))}';
      expect(said, 'Your practice · Chorus 2 at ¾');
      expect(
        said,
        isNot(matches(RegExp('ago|minute|hour|day|week|month|since|last|time', caseSensitive: false))),
      );
    });

    testWidgets('Home offers it back with no name and no clock', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repository = InMemoryMusicRepository.seeded();
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      final song = controller.rooms.expand((room) => room.projects).first;
      await controller.keepPracticeMark(PracticeMark(
        id: 'mark-alone',
        projectId: song.id,
        ledBy: repository.currentUserId,
        ledByName: 'You',
        parts: const <PracticePart>[
          PracticePart(label: 'Chorus 2', rate: 0.75, seconds: 90, startMs: 3000, endMs: 6000),
        ],
        updatedAt: DateTime.now(),
      ));

      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(
            body: SongsScreen(
              displayName: 'Jess',
              onOpenAccount: () {},
              onOpenNotifications: () {},
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      final card = find.byKey(const Key('waiting_card_practice-mark-alone'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Your practice')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Chorus 2 at ¾')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('From You')), findsNothing);
      expect(find.descendant(of: card, matching: find.textContaining('ago')), findsNothing);

      // Straight back to the part it was left on, at the speed it was left at.
      await tester.tap(find.byKey(const Key('waiting_do_practice-mark-alone')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final perform = tester.widget<LivePerformanceScreen>(find.byType(LivePerformanceScreen));
      expect(perform.practise?.label, 'Chorus 2');
      expect(perform.practise?.rate, 0.75);
    });
  });
}
