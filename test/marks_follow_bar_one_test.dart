import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/domain/song_cycle.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/practice_marks.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Practice marks keep up when bar 1 moves.
///
/// #385 let a song say where its own bar 1 is and moved every number in the
/// app onto it, and disclosed one place it could not reach: a practice mark
/// keeps the words it was kept under, so a card made before bar 1 moved went
/// on saying "Bars 9–12" about a passage the bar picker had started calling
/// "Bars 8–11". Tapping Practise already opened the right passage under the
/// right name — only the card's own text was stale, and a student reading it
/// was being sent to a bar nobody else in the room was counting.
///
/// The words follow the song now. A mark stores two times and a few words;
/// the times are the truth and never move, and the words are worked out
/// again from them through the same loopFor that names Perform's chips.
void main() {
  /// Sixteen bars at one a second, four beats to each.
  const downbeats = <int>[
    0, 1000, 2000, 3000, 4000, 5000, 6000, 7000, //
    8000, 9000, 10000, 11000, 12000, 13000, 14000, 15000,
  ];
  final beats = <int>[
    for (var i = 0; i < 64; i += 1) i * 250,
  ];
  const sections = <StructureSection>[
    StructureSection(startMs: 0, endMs: 4000, label: 'Verse'),
    StructureSection(startMs: 4000, endMs: 8000, label: 'Chorus'),
  ];
  final grid = SongGrid(
    beatsMs: beats,
    downbeatsMs: downbeats,
    sections: sections,
  );

  /// The mark a teacher's hour leaves on bars 9 to 12, at seven tenths.
  const worked = PracticePart(
    label: 'Bars 9–12',
    rate: 0.7,
    seconds: 300,
    startMs: 8000,
    endMs: 12000,
  );

  SongCount counting({int barOne = 1, SongCycle? cycle}) =>
      SongCount.of(grid, barOne: barOne, cycle: cycle);

  group('the words follow the song', () {
    test('a mark kept on bars 9–12 reads bars 8–11 once bar 1 moves on a bar', () {
      expect(practicePassage(worked, counted: counting()), 'Bars 9–12');
      expect(practicePassage(worked, counted: counting(barOne: 2)), 'Bars 8–11');
      expect(practiceSaid(worked, counted: counting(barOne: 2)), 'Bars 8–11 at 70%');
    });

    test('and bar 1 moving back the other way puts the numbers back up', () {
      // Bar 1 at the third downbeat: the passage is two bars further into the
      // count than it was, not two bars earlier.
      expect(practicePassage(worked, counted: counting(barOne: 3)), 'Bars 7–10');
    });

    test('only the words move: the mark still loops the same milliseconds', () {
      final loop = counting(barOne: 2).passage(worked.startMs, worked.endMs);
      expect(loop!.startMs, 8000);
      expect(loop.endMs, 12000);
      expect(worked.startMs, 8000, reason: 'the part itself is untouched');
      expect(worked.endMs, 12000);
    });

    test('a passage that now starts in the pickup says so, and never a 0', () {
      // Bar 1 at the eleventh downbeat: the passage opens a bar and a half
      // ahead of the count and runs two bars into it.
      final said = practicePassage(worked, counted: counting(barOne: 11));
      expect(said, 'Pickup–bar 2');
      expect(said, isNot(contains('0')));
      expect(said, isNot(contains('-')));
    });

    test('a passage now wholly ahead of bar 1 is the pickup', () {
      // Bar 1 at the thirteenth downbeat, which is where the passage ended.
      final said = practicePassage(worked, counted: counting(barOne: 13));
      expect(said, 'Pickup');
      expect(said, isNot(matches(RegExp(r'\d'))),
          reason: 'there are no bar numbers in front of bar 1 to print');
    });

    test('a part with a part’s own two edges keeps the part’s name', () {
      const chorus = PracticePart(
        label: 'Chorus',
        rate: 0.75,
        seconds: 200,
        startMs: 4000,
        endMs: 8000,
      );
      expect(practicePassage(chorus, counted: counting(barOne: 4)), 'Chorus',
          reason: 'where bar 1 is does not move where the chorus is');
    });

    test('the whole song has no times to work anything out from', () {
      const whole = PracticePart(label: 'The whole song', rate: 0.5, seconds: 400);
      expect(practicePassage(whole, counted: counting(barOne: 5)), 'The whole song');
    });

    test('a song with no downbeats is left exactly as it was', () {
      expect(practicePassage(worked, counted: SongCount.of(const SongGrid())),
          'Bars 9–12');
      expect(practicePassage(worked), 'Bars 9–12',
          reason: 'nothing read yet, so the mark speaks for itself');
    });

    test('a recording with beats but no bars still counts its cycle', () {
      // The beat tracker heard beats and never settled on a bar. A cycle is
      // laid over the beats and needs no analysed bars at all, so Perform
      // names this passage in cycles — and Home, which counted a grid with
      // no downbeats as nothing to count on, went on saying the words the
      // mark was kept under (review, 19 September 2026).
      final noBars = SongGrid(beatsMs: beats);
      expect(noBars.isEmpty, isFalse, reason: 'beats are something to count on');
      expect(
        practicePassage(worked,
            counted: SongCount.of(noBars, cycle: SongCycle(7, const <int>[4, 6]))),
        'Cycles 5–7',
      );
      expect(practicePassage(worked, counted: SongCount.of(noBars)), 'Bars 9–12',
          reason: 'no cycle and no bars leaves nothing to rename it from');
    });

    test('counting a cycle re-names it, and clearing the cycle puts it back', () {
      final seven = SongCycle(7, const <int>[4, 6]);
      expect(practicePassage(worked, counted: counting(cycle: seven)),
          'Cycles 5–7');
      expect(practicePassage(worked, counted: counting()), 'Bars 9–12',
          reason: 'the cycle cleared, so the analysed bars count again');
    });

    test('a whole mark is said in the numbers of today', () {
      final mark = PracticeMark(
        id: 'mark',
        projectId: 'song',
        ledByName: 'Jess',
        parts: const <PracticePart>[
          worked,
          PracticePart(
            label: 'Bars 1–3',
            rate: 1,
            seconds: 90,
            startMs: 0,
            endMs: 3000,
          ),
        ],
        updatedAt: DateTime(2026, 9, 19),
      );
      expect(practiceWorked(mark, counted: counting(barOne: 2)),
          'Bars 8–11 at 70% and Pickup–bar 2');
      expect(practiceWorked(mark), 'Bars 9–12 at 70% and Bars 1–3',
          reason: 'with nothing read, the words the mark was kept under');
    });
  });

  group('on Home', () {
    /// The practice card is the only list of marks there is: one card a song,
    /// in the strip at the top of Home.
    Future<
        ({
          MusicBetaController controller,
          InMemoryMusicRepository repository,
          String songId,
        })> withAMark(
      WidgetTester tester, {
      int? barOne,
      SongCycle? cycle,
      List<PracticePart> parts = const <PracticePart>[worked],
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repository = InMemoryMusicRepository.seeded();
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      final song = controller.rooms.expand((room) => room.projects).first;
      await controller.keepPracticeMark(PracticeMark(
        id: 'mark-bars',
        projectId: song.id,
        ledBy: repository.currentUserId,
        ledByName: 'You',
        parts: parts,
        updatedAt: DateTime(2026, 9, 19),
      ));
      if (barOne != null) await repository.setBarOne(song.id, barOne);
      if (cycle != null) await repository.setSongCycle(song.id, cycle);
      if (barOne != null || cycle != null) {
        await controller.refreshProject(song.id);
      }
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      return (
        controller: controller,
        repository: repository,
        songId: song.id,
      );
    }

    Future<void> pumpHome(
      WidgetTester tester,
      MusicBetaController controller,
      SongAnalysisService analysis,
    ) async {
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(
            body: SongsScreen(
              displayName: 'Jess',
              onOpenAccount: () {},
              onOpenNotifications: () {},
              analysisService: analysis,
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }

    Finder detailOf(String text) => find.descendant(
          of: find.byKey(const Key('waiting_card_practice-mark-bars')),
          matching: find.text(text),
        );

    testWidgets('the card says the bars the picker says now', (tester) async {
      final home = await withAMark(tester, barOne: 2);
      final analysis = _Counting(<String, SongGrid>{home.songId: grid});
      await pumpHome(tester, home.controller, analysis);

      expect(detailOf('Bars 8–11 at 70%'), findsOneWidget);
      expect(detailOf('Bars 9–12 at 70%'), findsNothing,
          reason: 'the numbers the mark was kept under are a bar out now');
      expect(analysis.asked, 1, reason: 'one request, for the songs with cards');
      expect(tester.takeException(), isNull);
    });

    testWidgets('and says cycles once the band counts one', (tester) async {
      final home = await withAMark(tester, cycle: SongCycle(7, const <int>[4, 6]));
      final analysis = _Counting(<String, SongGrid>{home.songId: grid});
      await pumpHome(tester, home.controller, analysis);

      expect(detailOf('Cycles 5–7 at 70%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song whose grid nothing answers for keeps its own words',
        (tester) async {
      final home = await withAMark(tester, barOne: 2);
      final analysis = _Counting(const <String, SongGrid>{});
      await pumpHome(tester, home.controller, analysis);

      expect(detailOf('Bars 9–12 at 70%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing is asked for when no card names a passage',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final analysis = _Counting(const <String, SongGrid>{});
      await pumpHome(tester, controller, analysis);

      expect(analysis.asked, 0,
          reason: 'a Home with nothing to rename fetches nothing');
      expect(tester.takeException(), isNull);
    });

    testWidgets('nor for a mark that only points at the whole song',
        (tester) async {
      final home = await withAMark(
        tester,
        barOne: 2,
        parts: const <PracticePart>[
          PracticePart(label: 'The whole song', rate: 0.5, seconds: 400),
        ],
      );
      final analysis = _Counting(<String, SongGrid>{home.songId: grid});
      await pumpHome(tester, home.controller, analysis);

      expect(detailOf('The whole song at ½'), findsOneWidget);
      expect(analysis.asked, 0,
          reason: 'the whole song is called that whatever the band counts');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Home already open follows bar 1 moving under it',
        (tester) async {
      // The ordinary way this happens: Practise, say "this is bar 1" in the
      // picker, close Perform. Home never went anywhere, and what it holds
      // is the grid rather than a finished count, so the card is renamed
      // from what it already has.
      final home = await withAMark(tester);
      final analysis = _Counting(<String, SongGrid>{home.songId: grid});
      await pumpHome(tester, home.controller, analysis);
      expect(detailOf('Bars 9–12 at 70%'), findsOneWidget);

      await home.repository.setBarOne(home.songId, 2);
      await home.controller.refreshProject(home.songId);
      await tester.pump(const Duration(milliseconds: 200));

      expect(detailOf('Bars 8–11 at 70%'), findsOneWidget);
      expect(analysis.asked, 1,
          reason: 'where bar 1 is comes off the song, not off the network');
      expect(tester.takeException(), isNull);
    });

    testWidgets('and a cycle being counted under it, and then cleared',
        (tester) async {
      final home = await withAMark(tester);
      final analysis = _Counting(<String, SongGrid>{home.songId: grid});
      await pumpHome(tester, home.controller, analysis);
      expect(detailOf('Bars 9–12 at 70%'), findsOneWidget);

      await home.repository.setSongCycle(home.songId, SongCycle(7, const <int>[4, 6]));
      await home.controller.refreshProject(home.songId);
      await tester.pump(const Duration(milliseconds: 200));
      expect(detailOf('Cycles 5–7 at 70%'), findsOneWidget);

      await home.repository.setSongCycle(home.songId, null);
      await home.controller.refreshProject(home.songId);
      await tester.pump(const Duration(milliseconds: 200));
      expect(detailOf('Bars 9–12 at 70%'), findsOneWidget,
          reason: 'the cycle cleared, so the analysed bars count again');
      expect(analysis.asked, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a request that failed is asked again, not remembered',
        (tester) async {
      // The card's own words are a bar out and the phone is in a tunnel.
      // Signal coming back has to be enough: a screen that took the first
      // failure as the answer would read the stale numbers until the app
      // was killed, which is the bug this whole slice is about.
      final home = await withAMark(tester, barOne: 2);
      final analysis = _Counting(
        <String, SongGrid>{home.songId: grid},
        failTimes: 1,
      );
      await pumpHome(tester, home.controller, analysis);

      // Anything that redraws the strip: the controller came back with
      // something, the app woke up, somebody returned from a song.
      await home.controller.refreshProject(home.songId);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(analysis.asked, 2, reason: 'a tunnel is not an answer');
      expect(detailOf('Bars 8–11 at 70%'), findsOneWidget);
      expect(detailOf('Bars 9–12 at 70%'), findsNothing,
          reason: 'a screen that filed the failure would still print these');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song the server has no recording of is not asked twice',
        (tester) async {
      final home = await withAMark(tester, barOne: 2);
      final analysis = _Counting(const <String, SongGrid>{});
      await pumpHome(tester, home.controller, analysis);
      expect(analysis.asked, 1);

      await home.controller.refreshProject(home.songId);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(analysis.asked, 1,
          reason: 'an answered "there is nothing there" is settled');
      expect(detailOf('Bars 9–12 at 70%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// The grids of a handful of songs, without a network.
class _Counting extends SongAnalysisService {
  _Counting(this.grids, {this.failTimes = 0}) : super(client: null);

  final Map<String, SongGrid> grids;

  /// How many of the first requests come back as a dropped connection
  /// rather than as an answer — a phone in a basement, or a server that
  /// said no.
  int failTimes;

  /// How many times the screen has asked. One request covers every song with
  /// a card on it, and a song is asked about once.
  int asked = 0;

  @override
  Future<SongGrids> gridsFor(Iterable<String> projectIds) async {
    asked += 1;
    if (failTimes > 0) {
      failTimes -= 1;
      return SongGrids(missed: projectIds.toSet());
    }
    return SongGrids(grids: <String, SongGrid>{
      for (final id in projectIds)
        if (grids.containsKey(id)) id: grids[id]!,
    });
  }
}
