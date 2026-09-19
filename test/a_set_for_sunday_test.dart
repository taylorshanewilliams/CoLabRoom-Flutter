import 'dart:convert';
import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/data/music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/features/songs/a_set_for_a_day.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/kept_songs.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A set for Sunday, and one quiet card for each of you.
///
/// Every Musician, Same Song, 17 September 2026, worship teams item 2: "the
/// dated set practised during the week, with one quiet card per member.
/// Leaders never see who opened it."
///
/// Four things have to hold. The card is there for the week before the day
/// and gone after it. It opens the set's songs in Perform, in the running
/// order and each in the key the set does it in. The day is the set owner's
/// to say and nobody else's. And nothing anywhere records that the card was
/// opened, so there is no answer to give a leader who asks.

/// The Sunday this set is for, and the Monday six days before it.
final DateTime _sunday = DateTime(2026, 10, 4);
final DateTime _theMondayBefore = DateTime(2026, 9, 28, 9, 30);

/// Today, and a day from it. Home asks the phone what day it is, so the
/// widget tests below date their set against the real calendar rather than
/// against a Sunday in a fixture.
final DateTime _today = DateTime.now();
DateTime _inDays(int days) =>
    DateTime(_today.year, _today.month, _today.day + days);

/// Who leads, and who is only playing on Sunday.
const String _leader = 'the-leader';
const String _player = 'preview-user';

/// A library with two songs, and the leader's set for Sunday: the new song
/// first, then the seeded one, so a running order that was read backwards
/// would show.
Future<(InMemoryMusicRepository, Setlist, SongProject)> _theSetForSunday({
  DateTime? day,
  DateTime? now,
}) async {
  final repository = InMemoryMusicRepository.seeded();
  if (now != null) repository.clock = () => now;
  final room = (await repository.loadRooms()).first;
  final second = await repository.createSong(room: room, title: 'Cornerstone');

  // Whoever leads is in the band. A set only reaches a room through somebody
  // who is in that room (0164), so the fake has to hold the membership the
  // database would.
  repository.addToRoom(
    room.id,
    const RoomMember(
      userId: _leader,
      displayName: 'The leader',
      role: RoomRole.editor,
      colorValue: 0xFF7BE0C9,
    ),
  );

  // Made by whoever leads, which is what makes this a set somebody else is
  // handed rather than one of their own.
  repository.currentUserId = _leader;
  var set = await repository.createSetlist('Morning service');
  await repository.addProjectsToSetlist(set, <String>[second.id, 'song-1']);
  set = (await repository.loadSetlists()).first;
  // Down a tone and up a tone from the songs' own G, so a Perform that
  // ignored the set would be caught either way.
  await repository.saveSetlistSong(
      set, SetlistSong(projectId: second.id, key: 'F'));
  await repository.saveSetlistSong(
      set, const SetlistSong(projectId: 'song-1', key: 'A'));
  if (day != null) await repository.setSetlistDay(set, day);
  repository.currentUserId = _player;

  return (repository, (await repository.loadSetlists()).first, second);
}

/// Home, with the card row on it.
Future<MusicBetaController> _openHome(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  _Sheets? sheets,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await SetAside.load();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: SongsScreen(
          displayName: 'Taylor',
          onOpenAccount: () {},
          onOpenNotifications: () {},
          analysisService: sheets ?? _Sheets(),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 200));
  return controller;
}

List<WaitingItem> _setCards(WidgetTester tester) => tester
    .widget<WaitingOnYou>(find.byType(WaitingOnYou))
    .items
    .where((item) => item.kind == WaitingKind.setDay)
    .toList();

/// Finds the set's card in the row -- which scrolls sideways, so it may not
/// be built yet -- and brings it where it can be tapped.
Future<Finder> _theCard(WidgetTester tester) async {
  final card = find.byKey(Key('waiting_card_${_setCards(tester).single.id}'));
  await tester.scrollUntilVisible(
    card,
    160,
    scrollable: find.descendant(
      of: find.byKey(const Key('waiting_row')),
      matching: find.byType(Scrollable),
    ),
  );
  // Built is not the same as on screen: the row stops scrolling the moment
  // the card exists, which can be with half of it past the right edge.
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  return card;
}

Future<void> _tapTheCard(WidgetTester tester) async {
  await tester.tap(await _theCard(tester));
  await tester.pumpAndSettle();
}

void main() {
  group('the card is there for the week, and then it is not', () {
    test('a week out, on the day, and gone the day after', () {
      final set = _dated(_sunday);

      // The Monday before, and every day up to Sunday itself.
      expect(setIsForTheWeekOf(set, _theMondayBefore), isTrue);
      expect(setIsForTheWeekOf(set, DateTime(2026, 9, 27)), isTrue,
          reason: 'a week out is the first day it shows');
      expect(setIsForTheWeekOf(set, DateTime(2026, 10, 4, 6)), isTrue,
          reason: 'it is still the set on the morning it is for');

      // And not before the week, and not once the day has gone.
      expect(setIsForTheWeekOf(set, DateTime(2026, 9, 26)), isFalse);
      expect(setIsForTheWeekOf(set, DateTime(2026, 10, 5)), isFalse);

      // A set with no day is not an occasion, and one with no songs has
      // nothing to open.
      expect(setIsForTheWeekOf(_dated(null), _theMondayBefore), isFalse);
      expect(
        setIsForTheWeekOf(_dated(_sunday, songs: const <SetlistSong>[]),
            _theMondayBefore),
        isFalse,
      );
    });

    test('soonest first', () {
      final sets = setsForTheWeek(<Setlist>[
        _dated(_sunday, id: 'sunday'),
        _dated(DateTime(2026, 9, 30), id: 'wednesday'),
        _dated(DateTime(2027, 1, 1), id: 'new year'),
      ], _theMondayBefore);
      expect(sets.map((set) => set.id), <String>['wednesday', 'sunday']);
    });

    test('the day is named, never counted down to', () {
      // Inside the coming six days a weekday names exactly one day.
      expect(setDayNamed(_sunday, _theMondayBefore), 'Sunday');
      expect(setDayNamed(DateTime(2026, 9, 28), _theMondayBefore), 'Monday',
          reason: 'today is a day, not "today"');
      // A week out, "Sunday" could be either Sunday.
      expect(setDayNamed(_sunday, DateTime(2026, 9, 27)), 'Sunday 4 October');
      expect(setDayInFull(_sunday), 'Sunday 4 October 2026');
    });

    test('the card says the set and the day, and asks for nothing', () {
      final card = setForDayCard(_dated(_sunday),
          today: _theMondayBefore, onOpen: () {});

      expect(card.line, 'The set for Sunday');
      expect(card.eyebrow, 'Morning service');
      expect(card.actionLabel, 'Open');
      // No number of days, no songs counted, nothing about practising.
      expect(card.detail, isNull);
      expect(card.at, isNull);
      expect(card.who, isNull);
      // And no permanent no. There is nothing to decline — the set is still
      // on Sunday — so the x hides it until the app is opened again, which
      // is also what keeps anything at all from being written when it is
      // answered.
      expect(card.onDismiss, isNull);
    });
  });

  group('the day is the set owner\'s', () {
    test('the owner says it, and can take it off again', () async {
      final (repository, set, _) =
          await _theSetForSunday(now: _theMondayBefore);
      repository.currentUserId = _leader;

      await repository.setSetlistDay(set, _sunday);
      expect((await repository.loadSetlists()).first.forDay, _sunday);

      await repository.setSetlistDay(set, null);
      expect((await repository.loadSetlists()).first.forDay, isNull);
    });

    test('somebody who is only playing on Sunday cannot', () async {
      final (repository, set, _) =
          await _theSetForSunday(day: _sunday, now: _theMondayBefore);

      // Signed in as the player, which is who the fake is by the time the
      // set comes back from _theSetForSunday.
      await expectLater(
        repository.setSetlistDay(set, DateTime(2026, 11, 1)),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            MusicRepository.notYourSet)),
      );
      expect((await repository.loadSetlists()).first.forDay, _sunday);
    });

    test('only a dated set is handed to the people playing it', () async {
      final (repository, set, second) =
          await _theSetForSunday(day: _sunday, now: _theMondayBefore);

      final waiting = await repository.setsForTheDay();
      expect(waiting.single.id, set.id);
      expect(waiting.single.forDay, _sunday);
      expect(waiting.single.projectIds, <String>[second.id, 'song-1']);
      expect(waiting.single.songFor(second.id)?.key, 'F');

      // Undate it and there is nothing waiting for anybody.
      repository.currentUserId = _leader;
      await repository.setSetlistDay(set, null);
      expect(await repository.setsForTheDay(), isEmpty);

      // And a set whose day has gone by is done with.
      await repository.setSetlistDay(set, DateTime(2026, 9, 20));
      expect(await repository.setsForTheDay(), isEmpty);
    });

    test('somebody who has left the band cannot still write on its Home',
        () async {
      final (repository, set, _) =
          await _theSetForSunday(day: _sunday, now: _theMondayBefore);
      expect(await repository.setsForTheDay(), isNotEmpty);

      // Removed from the room, the way somebody is after a falling-out. What
      // joins their set to the band's songs is a row nothing takes away
      // (0005 checks membership as it goes in and never again), so the set
      // is still joined and would still arrive if the join were the only
      // rule — and its name is eighty characters of theirs, on every
      // member's Home, every week they re-date it.
      final room = (await repository.loadRooms()).first;
      await repository.removeRoomMember(roomId: room.id, userId: _leader);

      expect(await repository.setsForTheDay(), isEmpty);
      // The set itself is untouched. It is theirs and it still says Sunday;
      // it is simply no longer anything to do with that room.
      expect((await repository.loadSetlists())
          .firstWhere((held) => held.id == set.id)
          .forDay, _sunday);
    });

    test('and neither does somebody you have blocked', () async {
      final (repository, _, __) =
          await _theSetForSunday(day: _sunday, now: _theMondayBefore);
      expect(await repository.setsForTheDay(), isNotEmpty);

      await repository.blockUser(_leader);
      expect(await repository.setsForTheDay(), isEmpty);

      await repository.unblockUser(_leader);
      expect(await repository.setsForTheDay(), isNotEmpty);
    });

    testWidgets('the owner says the day on the set itself', (tester) async {
      final (repository, set, _) =
          await _theSetForSunday(now: _theMondayBefore);
      repository.currentUserId = _leader;
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SetlistDetailScreen(
            setlistId: set.id,
            loadAnalysis: (_) async => null,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Nothing on the screen until there is a day: a set that is not an
      // occasion says nothing about one.
      expect(find.byKey(const Key('set_day_line')), findsNothing);

      await controller.setSetlistDay(set, _sunday);
      await tester.pumpAndSettle();
      expect(find.text('For Sunday 4 October 2026'), findsOneWidget);

      // And the x on that line takes the day off, which takes the card off
      // everybody's Home.
      await tester.tap(find.byKey(const Key('set_no_day')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('set_day_line')), findsNothing);
      expect(controller.setlistById(set.id)?.forDay, isNull);
    });

    testWidgets('a set dated long ago can still be re-dated', (tester) async {
      final (repository, set, _) = await _theSetForSunday();
      repository.currentUserId = _leader;
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);

      // 'Morning service' after a summer off: the set still says a day two
      // months back, which is further behind than the picker offers.
      await controller.setSetlistDay(set, _inDays(-60));

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SetlistDetailScreen(
            setlistId: set.id,
            loadAnalysis: (_) async => null,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('set_day_line')));
      await tester.pumpAndSettle();

      // The picker opens on today rather than throwing on a day outside its
      // own window, and the day the set says is untouched until a new one is
      // picked.
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.setlistById(set.id)?.forDay, _inDays(-60));
    });
  });

  group('one quiet card, opening the set', () {
    testWidgets('it is on Home before the day, and not after', (tester) async {
      final (repository, _, __) = await _theSetForSunday(day: _inDays(3));
      await _openHome(tester, repository);

      expect(_setCards(tester).single.line,
          'The set for ${setDayNamed(_inDays(3), _today)}');
      expect(find.text('Morning service'), findsOneWidget);

      // The day after the day. The same set, the same songs, and no card —
      // the server still hands it over (yesterday is inside its window) and
      // the phone is what decides the week is done.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final (yesterday, _, ___) = await _theSetForSunday(day: _inDays(-1));
      expect(await yesterday.setsForTheDay(), isNotEmpty);
      await _openHome(tester, yesterday);
      expect(_setCards(tester), isEmpty);
    });

    testWidgets('it opens the set in order, each in the set\'s key',
        (tester) async {
      final (repository, _, second) = await _theSetForSunday(day: _inDays(3));
      await _openHome(tester, repository);

      await _tapTheCard(tester);

      // First the song the set puts first, in the key the set does it in:
      // G down two is F.
      expect(find.byType(LivePerformanceScreen), findsOneWidget);
      expect(find.text('Cornerstone'), findsWidgets);
      expect(find.text('Key of F'), findsOneWidget);
      expect(find.text('Next · Midnight Signal'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_next_in_set')));
      await tester.pumpAndSettle();

      // Then the second, up a tone instead. And nothing after it: the last
      // song of a set offers no next.
      expect(find.text('Midnight Signal'), findsWidgets);
      expect(find.text('Key of A'), findsOneWidget);
      expect(find.byKey(const Key('live_next_in_set')), findsNothing);
      expect(find.text('LIVE'), findsOneWidget);
      expect(second.id, isNot('song-1'));

      // Closing the last one is the end of the set, back on Home.
      await tester.tap(find.byKey(const Key('close_live_mode')));
      await tester.pumpAndSettle();
      expect(find.byType(LivePerformanceScreen), findsNothing);
      expect(find.byType(WaitingOnYou), findsOneWidget);
    });

    testWidgets('closing the first song ends the set there', (tester) async {
      final (repository, _, __) = await _theSetForSunday(day: _inDays(3));
      await _openHome(tester, repository);

      await _tapTheCard(tester);
      expect(find.text('Key of F'), findsOneWidget);

      await tester.tap(find.byKey(const Key('close_live_mode')));
      await tester.pumpAndSettle();
      expect(find.byType(LivePerformanceScreen), findsNothing);
      expect(find.byType(WaitingOnYou), findsOneWidget);
    });

    testWidgets('the next song is read while this one is open', (tester) async {
      final (repository, _, second) = await _theSetForSunday(day: _inDays(3));
      final sheets = _Sheets();
      await _openHome(tester, repository, sheets: sheets);

      await _tapTheCard(tester);

      // The first song is on the screen and the second has already been
      // asked for. Asking only once Perform closes would drop the player
      // back onto Home in the middle of the set for as long as the read
      // takes -- which on a church wifi is long enough to think the set
      // ended and tap something else.
      expect(find.byType(LivePerformanceScreen), findsOneWidget);
      expect(sheets.asked, <String>[second.id, 'song-1']);
    });

    testWidgets('tapping the card twice does not open the set twice',
        (tester) async {
      final (repository, _, __) = await _theSetForSunday(day: _inDays(3));
      await _openHome(tester, repository, sheets: _SlowSheets());

      // Two taps while the first song's sheet is still being read: the card
      // is on Home and Home is what is on the screen until Perform opens.
      final card = await _theCard(tester);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tap(card);
      await tester.pumpAndSettle();

      // One Perform, not a second set walking underneath it -- which would
      // show later as a stale song appearing when this one is closed.
      expect(find.byType(LivePerformanceScreen, skipOffstage: false),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('close_live_mode')));
      await tester.pumpAndSettle();
      expect(find.byType(LivePerformanceScreen, skipOffstage: false),
          findsNothing);
      // The read asked for ahead of a set that is now closed still has to
      // land somewhere, and nothing is waiting for it.
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('opening it records nothing at all', (tester) async {
      final (repository, set, _) = await _theSetForSunday(day: _inDays(3));
      await _openHome(tester, repository);
      final before = (await SharedPreferences.getInstance()).getKeys().toSet();

      await _tapTheCard(tester);
      await tester.tap(find.byKey(const Key('live_next_in_set')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close_live_mode')));
      await tester.pumpAndSettle();

      // The set is exactly what it was, on this phone and on the server.
      final after = (await repository.loadSetlists()).first;
      expect(after.forDay, _inDays(3));
      expect(after.updatedAt, set.updatedAt);
      expect((await repository.setsForTheDay()).single.projectIds,
          set.projectIds);

      // Nothing was written on this phone either. The whole set was walked
      // through, so a receipt kept anywhere would have landed by now, and
      // the singer's own key for these songs is untouched: the set's key was
      // the occasion's and not a preference of theirs.
      final now = (await SharedPreferences.getInstance()).getKeys().toSet();
      expect(now.difference(before), isEmpty);
      expect(now.where((key) => key.contains(set.id)), isEmpty);

      // And the card is still there, because nothing about it was answered.
      expect(_setCards(tester).single.line,
          'The set for ${setDayNamed(_inDays(3), _today)}');
    });
  });

  test('the server keeps no receipt either', () {
    final whole =
        File('supabase/migrations/0164_a_set_for_a_day.sql').readAsStringSync();
    // The SQL without the prose around it: the comment says the words
    // "opened" and "receipt" precisely because the schema must not.
    final migration = const LineSplitter()
        .convert(whole)
        .where((line) => !line.trimLeft().startsWith('--'))
        .join(' ');

    // The one column, and no second one that could say who looked.
    expect(migration, contains('add column if not exists for_day date'));
    expect(migration, isNot(contains('opened_at')));
    expect(migration, isNot(contains('seen_at')));
    expect(migration, isNot(contains('create table')));
    expect(migration, isNot(contains('insert into')));
    // A stable function cannot write a row even if somebody later wanted it
    // to, which is what makes "leaders never see who opened it" a property
    // of the schema rather than a rule about reading it.
    expect(migration, contains('stable'));
    expect(migration, contains('revoke all on function public.sets_for_the_day() from public, anon'));

    // And the read asks for both memberships, not just the caller's: a set
    // of somebody who has left the room is joined to its songs by a row
    // nothing removes, and it must not reach the room.
    expect(migration, contains('from public.room_members m'));
    expect(migration, contains('blocked_between'));
  });
}

/// A set for [day] with two songs in it, for the rules that need no library.
Setlist _dated(
  DateTime? day, {
  String id = 'set-1',
  List<SetlistSong> songs = const <SetlistSong>[
    SetlistSong(projectId: 'song-2', key: 'F'),
    SetlistSong(projectId: 'song-1', key: 'A'),
  ],
}) =>
    Setlist(
      id: id,
      ownerId: _leader,
      name: 'Morning service',
      createdAt: _theMondayBefore,
      updatedAt: _theMondayBefore,
      forDay: day,
      songs: songs,
    );

/// Every song's sheet, in G, with two chords on it — so a set that says F
/// reads down a tone and a set that says A reads up one.
class _Sheets extends SongAnalysisService {
  _Sheets() : super(client: null, kept: _NothingKept());

  /// Every song this service has been asked for, in the order it was asked.
  final List<String> asked = <String>[];

  @override
  Future<SongAnalysisBundle> load(String projectId) async => _sheetIn(projectId);

  SongAnalysisBundle _sheetIn(String projectId) {
    asked.add(projectId);
    return SongAnalysisBundle(
        reference: ReferenceTrack(
          projectId: projectId,
          fileId: 'file-$projectId',
          storagePath: 'room-1/$projectId/reference.m4a',
          displayName: 'reference.m4a',
          state: SongAnalysisState.ready,
          durationMs: 20000,
          musicalKey: 'G',
          transcriptWords: const <TranscriptWord>[
            TranscriptWord(word: 'Streetlights', startMs: 5000, endMs: 5800),
          ],
        ),
        lyricCues: const <LyricSyncCue>[],
        chordCues: const <ChordCue>[
          ChordCue(id: 1, startMs: 5000, endMs: 7000, chord: 'G:maj', confidence: 0.9),
        ],
      );
  }

  @override
  Future<String> ensureLocalReference(ReferenceTrack reference) async =>
      throw StateError('No recording in a widget test.');
}

/// The same sheets, a beat later — which is what a read over a church wifi
/// is, and what a service answering in the same microtask cannot show.
class _SlowSheets extends _Sheets {
  @override
  Future<SongAnalysisBundle> load(String projectId) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _sheetIn(projectId);
  }
}

/// Nothing is kept on this phone, answered without touching a disk.
class _NothingKept extends KeptSongs {
  _NothingKept()
      : super(
          root: () async => throw StateError('No disk in a widget test.'),
          download: (_) async => throw StateError('No network in a widget test.'),
        );

  @override
  Future<KeptSong?> load(String projectId) async => null;

  @override
  Future<Set<String>> keptIds() async => <String>{};

  @override
  Future<String?> audioPath(String projectId, String storagePath) async => null;

  @override
  Future<void> refresh(SongProject project, SongAnalysisBundle sheet) async {}
}
