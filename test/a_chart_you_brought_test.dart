import 'dart:io' show SocketException;

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/songs/new_song_flow.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/song_analysis_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/services/brought_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Bringing a chart you already have.
///
/// Taylor, 19 September 2026: can people practise any song they want in here?
/// Chords in this app are timed against a recording, so a song nobody has
/// recorded had nowhere at all to hold one — the app could hand a chart out
/// (#360) and could not take one in.
///
/// Nothing in this feature fetches a chart from anywhere, and nothing in this
/// file does either: every chart here is typed out, in words old enough to be
/// anyone's.

/// Amazing Grace as a tab site prints it: a bracketed part name, a line of
/// chords, a line of words under it.
const String _asATabSite = '[Verse 1]\n'
    'G             G7          C          G\n'
    'Amazing grace how sweet the sound\n';

Future<MusicBetaController> _controllerFor(
  InMemoryMusicRepository repository,
) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  return controller;
}

Future<void> _boot(WidgetTester tester, Widget home,
    MusicBetaController controller) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
  ));
  await tester.pump(const Duration(milliseconds: 200));
}

/// What is on the clipboard when somebody taps Paste.
///
/// Set on the platform channel rather than anywhere in this app, because the
/// app reads the real clipboard and only on that tap.
void _clipboardHolds(String text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      return <String, dynamic>{'text': text};
    }
    return null;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('where a brought chart is kept', () {
    test('a second chart replaces the first, and a blank is not a chart',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      final song = (await repository.loadRooms())
          .firstWhere((room) => room.id == 'room-1')
          .projects
          .first;

      expect(await repository.broughtChart(song.id), isNull,
          reason: 'a song has no chart until somebody brings one');

      await repository.bringChart(song.id, readChart(_asATabSite).chordPro);
      expect((await repository.broughtChart(song.id))!.body,
          contains('[G]Amazing'));

      await repository.bringChart(song.id, '[D]Amazing grace');
      expect((await repository.broughtChart(song.id))!.body,
          contains('[D]Amazing'),
          reason: 'one song, one chart — that is what Replace means');

      await expectLater(
        repository.bringChart(song.id, '   '),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', '22023')),
      );
      await expectLater(
        repository.bringChart(song.id, 'C' * (chartBodyLimit + 1)),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', '22023')),
      );
      expect((await repository.broughtChart(song.id))!.body,
          contains('[D]Amazing'),
          reason: 'a refused chart leaves the one that was there');
    });

    test('an editor may bring one and somebody who can only look may not',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      repository.addToRoom(
        'room-1',
        const RoomMember(
          userId: 'vee',
          displayName: 'Vee',
          role: RoomRole.viewer,
          colorValue: 0xFFE3B34D,
        ),
      );
      final song = (await repository.loadRooms())
          .firstWhere((room) => room.id == 'room-1')
          .projects
          .first;

      // Usually the person actually playing the thing, which is why the gate
      // is owner-or-editor rather than owner (0168).
      repository.currentUserId = 'preview-jess';
      await repository.bringChart(song.id, '[G]Amazing grace');
      expect((await repository.broughtChart(song.id))!.body,
          contains('[G]Amazing'));

      Matcher refused() => throwsA(
            isA<PostgrestException>()
                .having((e) => e.code, 'code', '42501')
                .having((e) => e.message, 'message', contains('can edit')),
          );

      repository.currentUserId = 'vee';
      await expectLater(repository.bringChart(song.id, '[C]No'), refused());
      repository.currentUserId = 'nobody-at-all';
      await expectLater(repository.bringChart(song.id, '[C]No'), refused());

      expect((await repository.broughtChart(song.id))!.body,
          contains('[G]Amazing'),
          reason: 'the editor’s chart stands through all of that');
    });

    test('a song that is not there is refused rather than half-written',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      await expectLater(
        repository.bringChart('not-a-song', '[G]Amazing'),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', '22023')),
      );
      expect(await repository.broughtChart('not-a-song'), isNull);
    });
  });

  group('the doors', () {
    testWidgets('the empty library offers Learn a song', (tester) async {
      final controller = await _controllerFor(_NoSongs());
      addTearDown(controller.dispose);
      await _boot(
        tester,
        Scaffold(
          body: SongsScreen(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
            onRecord: () {},
            onFindMusicians: () {},
          ),
        ),
        controller,
      );

      expect(find.byKey(const Key('door_learn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('door_learn')));
      await tester.pumpAndSettle();
      expect(find.text('Where should this song live?'), findsOneWidget,
          reason: 'the door opens the flow rather than describing it');
    });

    testWidgets('the song opens where the chart is', (tester) async {
      // The chart has to be on the screen the flow lands on. Landing on the
      // words editor instead put a new person in front of an empty lyric box
      // with Record as the lit thing to do and no chords anywhere, one unlit
      // pill away from what they had just pasted — so they believe it was
      // lost (review, 19 September 2026).
      _clipboardHolds(_asATabSite);
      final controller = await _controllerFor(InMemoryMusicRepository.seeded());
      addTearDown(controller.dispose);
      await _boot(
        tester,
        Scaffold(
          body: SongsScreen(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
            onRecord: () {},
            onFindMusicians: () {},
          ),
        ),
        controller,
      );

      await tester.tap(find.byKey(const Key('songs_new_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('songs_new_learn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick_room_room-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('learn_a_song_title')), 'Amazing Grace');
      await tester.pump();
      await tester.tap(find.byKey(const Key('learn_a_song_next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bring_a_chart_paste')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bring_a_chart_read')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bring_a_chart_keep')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 20));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('brought_chart')), findsOneWidget,
          reason: 'the chart is on the page the song opened on');
    });

    testWidgets('New offers a song to learn', (tester) async {
      final controller = await _controllerFor(InMemoryMusicRepository.seeded());
      addTearDown(controller.dispose);
      await _boot(
        tester,
        Scaffold(
          body: SongsScreen(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
            onRecord: () {},
            onFindMusicians: () {},
          ),
        ),
        controller,
      );

      await tester.tap(find.byKey(const Key('songs_new_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('songs_new_learn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('songs_new_learn')));
      await tester.pumpAndSettle();
      expect(find.text('Where should this song live?'), findsOneWidget);
    });

    testWidgets('a song with no chords says where a chart would go',
        (tester) async {
      final controller = await _controllerFor(InMemoryMusicRepository.seeded());
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await _boot(tester, SongAnalysisScreen(project: project), controller);

      await tester.scrollUntilVisible(
        find.byKey(const Key('bring_a_chart_door')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Bring a chart'), findsOneWidget,
          reason: 'the place the chart goes is the door to putting one there');

      await tester.tap(find.byKey(const Key('bring_a_chart_door')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bring_a_chart_paste')), findsOneWidget);
      expect(find.byKey(const Key('bring_a_chart_file')), findsOneWidget);
    });

    testWidgets('a song nobody has recorded still reaches its sheet',
        (tester) async {
      // The one that would have made the whole feature unreachable: the Song
      // Sheet pill used to be dropped from a song with no recording, on the
      // reasoning that Record went to the same screen. A song with no
      // recording is exactly the song whose chords live on a brought chart.
      final controller = await _controllerFor(InMemoryMusicRepository.seeded());
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await _boot(tester, SongWorkspaceScreen(projectId: project.id),
          controller);
      for (var i = 0; i < 5; i += 1) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      await tester.tap(find.byKey(const Key('workspace_analyze_button')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('bring_a_chart_door')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Bring a chart'), findsOneWidget);
    });

    testWidgets('a chart that could not be looked for is not offered over',
        (tester) async {
      // "Bring a chart" is an offer to write over whatever is there, and
      // there is no history to get the old one back from. A select that timed
      // out on a train looked exactly like a song with no chart, so the
      // careful chart the owner typed out last week was one paste away from
      // gone (review, 19 September 2026).
      final controller = await _controllerFor(_CannotLook());
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await _boot(tester, SongAnalysisScreen(project: project), controller);

      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('bring_a_chart_door')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Could not look for the chart'), findsOneWidget);
      expect(find.text('Bring a chart'), findsNothing);

      // What it offers instead is looking again, and that is what it does.
      await tester.tap(find.byKey(const Key('bring_a_chart_door')));
      await tester.pumpAndSettle();
      expect(find.text('Could not look for the chart'), findsOneWidget);
      expect(find.byKey(const Key('bring_a_chart_paste')), findsNothing);
    });
  });

  group('bringing one', () {
    testWidgets('what was understood is shown before anything is kept',
        (tester) async {
      _clipboardHolds(_asATabSite);
      final repository = InMemoryMusicRepository.seeded();
      final controller = await _controllerFor(repository);
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await _boot(tester, SongAnalysisScreen(project: project), controller);

      await tester.scrollUntilVisible(
        find.byKey(const Key('bring_a_chart_door')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('bring_a_chart_door')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bring_a_chart_paste')));
      await tester.pumpAndSettle();

      // The clipboard arrived in the box, because the tap said Paste.
      expect(
        tester.widget<TextField>(find.byKey(const Key('bring_a_chart_field')))
            .controller!
            .text,
        _asATabSite,
      );
      await tester.tap(find.byKey(const Key('bring_a_chart_read')));
      await tester.pumpAndSettle();

      // The preview is the page, not a report about it: the words, the part's
      // name, and the chords over the words.
      expect(find.byKey(const Key('bring_a_chart_preview')), findsOneWidget);
      expect(find.text('VERSE 1'), findsOneWidget);
      expect(find.text('Amazing'), findsOneWidget);
      expect(find.text('G7'), findsOneWidget);
      // Nothing was kept by looking at it.
      expect(await repository.broughtChart(project.id), isNull);

      await tester.tap(find.byKey(const Key('bring_a_chart_keep')));
      await tester.pumpAndSettle();

      final kept = await repository.broughtChart(project.id);
      expect(kept, isNotNull);
      expect(kept!.body, contains('[G]Amazing'));
      expect(kept.body, contains('{comment: Verse 1}'));

      // And the sheet is drawing it, with the way to change it in the same
      // place the door was.
      expect(find.byKey(const Key('brought_chart')), findsOneWidget);
      expect(find.byKey(const Key('bring_a_chart_door')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('replace_the_chart')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Replace the chart'), findsOneWidget);
    });
  });

  group('reading it your own way', () {
    testWidgets('a brought chart moves with the key you read it in',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final controller = await _controllerFor(repository);
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await repository.bringChart(
          project.id, readChart(_asATabSite).chordPro);

      await _boot(tester, SongAnalysisScreen(project: project), controller);
      await tester.scrollUntilVisible(
        find.byKey(const Key('chart_read_as')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Original key'), findsOneWidget);
      expect(find.text('G7'), findsOneWidget);

      // Up two, the way a singer asks for it. The chords are chord names, so
      // every reading built for the song sheet works on a chart as well.
      await tester.tap(find.byTooltip('Transpose up'));
      await tester.pump();
      await tester.tap(find.byTooltip('Transpose up'));
      await tester.pumpAndSettle();

      expect(find.text('+2 semitones'), findsOneWidget);
      expect(find.text('A7'), findsOneWidget);
      expect(find.text('G7'), findsNothing);
    });

    testWidgets('a line with more chords than words keeps every one of them',
        (tester) async {
      // The sheet holds one chord over each piece of a line, which is right
      // for almost every line ever written and wrong for the short ones: two
      // chords over one word would draw the second and quietly lose the
      // first. Losing a chord is the one thing a chart must never do.
      final repository = InMemoryMusicRepository.seeded();
      final controller = await _controllerFor(repository);
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await repository.bringChart(
        project.id,
        readChart('C   G\nOh\n').chordPro,
      );

      await _boot(tester, SongAnalysisScreen(project: project), controller);
      await tester.scrollUntilVisible(
        find.byKey(const Key('brought_chart')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Oh'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('G'), findsOneWidget);
    });

    testWidgets('a chart that names no key is read in the band\'s',
        (tester) async {
      // The chart's own statement first, the room's key behind it. A chart
      // with no Key line is most pasted charts, and a room that has already
      // said what key the song is in said it about the song and not only
      // about its recording — without which the capo and the numbers, both
      // counted from a key, could not even be chosen (review, 19 September
      // 2026).
      final repository = InMemoryMusicRepository.seeded();
      final controller = await _controllerFor(repository);
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await repository.setSongKey(project.id, 'A minor');
      await repository.bringChart(
        project.id,
        readChart('Am      C\nThere is a house\n').chordPro,
      );
      final said = (await repository.loadRooms())
          .expand((room) => room.projects)
          .firstWhere((p) => p.id == project.id);
      expect(said.songKey(null), 'A minor');

      await _boot(tester, SongAnalysisScreen(project: said), controller);
      await tester.scrollUntilVisible(
        find.byKey(const Key('chart_read_as')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('chart_read_as')));
      await tester.pumpAndSettle();

      // The key sheet, not the keyless one: a capo can be put on and the
      // numbers counted from the 1.
      expect(find.byKey(const Key('reading_choice_sheet')), findsNothing);
      expect(find.byKey(const Key('key_reference_sheet')), findsOneWidget);
    });

    testWidgets('a chart with no key anywhere can be given one',
        (tester) async {
      // A song with no recording has no key badge and no song sheet, so
      // without this its key could never be said at all.
      final repository = InMemoryMusicRepository.seeded();
      final controller = await _controllerFor(repository);
      addTearDown(controller.dispose);
      final project = controller.projects.first;
      await repository.bringChart(
        project.id,
        readChart('Am      C\nThere is a house\n').chordPro,
      );

      await _boot(tester, SongAnalysisScreen(project: project), controller);
      await tester.scrollUntilVisible(
        find.byKey(const Key('chart_read_as')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('chart_read_as')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reading_choice_sheet')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('which_key_is_A')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('which_key_is_A')));
      await tester.pumpAndSettle();

      final said = (await repository.loadRooms())
          .expand((room) => room.projects)
          .firstWhere((p) => p.id == project.id);
      expect(said.songKey(null), 'A major',
          reason: 'the key is the room\'s, said once and seen by everybody');
    });

    test('the sheet reads the chart by column, not by a clock', () {
      final chart = readChart(_asATabSite);
      final line = chart.lines
          .firstWhere((line) => line.kind == ChartLineKind.words);
      final sheet = broughtLineAsSheetLine(line);
      expect(sheet.body, 'Amazing grace how sweet the sound');
      expect(sheet.wordStartsMs, <int>[0, 1000, 2000, 3000, 4000, 5000]);
      expect(
        sheet.chords.map((c) => '${c.chord}@${c.startMs}').toList(),
        <String>['G@0', 'G7@2000', 'C@4000', 'G@5000'],
        reason: 'a chord written over a word belongs to that word, and a '
            'chord in the gap before one belongs to the word it precedes',
      );
    });
  });

  group('whose song it is', () {
    testWidgets('a song made from a chart is somebody else’s unless you say',
        (tester) async {
      _clipboardHolds(_asATabSite);
      final repository = InMemoryMusicRepository.seeded();
      final controller = await _controllerFor(repository);
      addTearDown(controller.dispose);

      await _boot(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('start'),
                onPressed: () => showLearnASongFlow(context, controller),
                child: const Text('Learn a song'),
              ),
            ),
          ),
        ),
        controller,
      );

      await tester.tap(find.byKey(const Key('start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('After Hours Studio'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('learn_a_song_title')), 'Amazing Grace');
      await tester.enterText(
          find.byKey(const Key('learn_a_song_artist')), 'Traditional');
      await tester.pump();
      await tester.tap(find.byKey(const Key('learn_a_song_next')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('bring_a_chart_paste')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bring_a_chart_read')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bring_a_chart_keep')));
      await tester.pumpAndSettle();

      // Asked once, in the words it is asked in everywhere else — and walked
      // away from, which is the case that matters: an unanswered song made
      // out of somebody else's chart is somebody else's.
      expect(find.text('Who wrote this song?'), findsOneWidget);

      // Already somebody else's while the question is still on the screen.
      // Everything between keeping the chart and answering can end the flow —
      // the phone reaped with the sheet open, a connection that drops — and
      // each of those used to leave the song unanswered rather than a cover,
      // which is a different thing in SQL: 0155 refuses the Open Mic to a
      // song that `is not distinct from 'cover'` and lets a null through
      // (review, 19 September 2026).
      final duringTheQuestion = (await repository.loadRooms())
          .expand((room) => room.projects)
          .firstWhere((project) => project.title == 'Amazing Grace');
      expect(duringTheQuestion.songOrigin, SongOrigin.cover);

      await tester.tapAt(const Offset(195, 20));
      await tester.pumpAndSettle();

      final song = controller.projects
          .firstWhere((project) => project.title == 'Amazing Grace');
      expect(song.songOrigin, SongOrigin.cover,
          reason: 'which keeps it in the room, off both public surfaces, and '
              'exporting its chords without its words (0142)');

      final kept = await repository.broughtChart(song.id);
      expect(kept, isNotNull);
      expect(kept!.body, contains('{artist: Traditional}'),
          reason: 'who wrote it is a fact the chart states about itself');
    });
  });
}

class _NoSongs extends InMemoryMusicRepository {
  _NoSongs() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<MusicRoom>> loadRooms() async => const <MusicRoom>[];
}

/// A room that cannot be asked whether the song has a chart.
class _CannotLook extends InMemoryMusicRepository {
  _CannotLook() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<SongChart?> broughtChart(String projectId) async =>
      throw const SocketException('offline');
}
