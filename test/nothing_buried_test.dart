import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/tonight_models.dart';
import 'package:colabroom/features/songs/pick_it_back_up.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/songs/tonight.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nothing buried.
///
/// Taylor, 16 Sep 2026, on Home's row of cards: "currently you close one out
/// and there's just another behind that one. i like the idea of them all
/// being there scrollable and you can remove the ones you want and keep the
/// ones you want without anything being buried."
///
/// Several kinds of card were a queue with one showing: a song you left, a
/// recording without a song sheet, the news, Tonight. Closing the visible
/// one brought the next out from behind it. Now every one is a card in the
/// row at once, closing one removes that card and nothing else, and the row
/// holds its order.
void main() {
  group('every card that is due', () {
    final even = DateTime(2026, 9, 16);
    const song = TonightSong(
      projectId: 'song-1',
      title: 'Divide',
      key: 'D major',
      chords: <String>['D:maj', 'G:maj', 'A:maj', 'Bm'],
    );
    const prompt = TonightPrompt(
      id: 7,
      kind: 'first_line',
      title: 'Write the first line',
      body: 'The thing you should have said in the car.',
      cta: 'Record',
    );
    final release = ReleaseNote(
      sha: 'abc1234',
      title: 'The band talks in the room',
      body: 'Every room is a thread now.',
      mergedAt: even.subtract(const Duration(days: 2)),
    );

    test('Tonight offers all of today, not the first of it', () {
      final cards = composeTonightCards(
        today: even,
        releases: <ReleaseNote>[release],
        song: song,
        prompt: prompt,
        seen: (_) => false,
      );
      expect(cards.map((card) => card.kind), <TonightKind>[
        TonightKind.whatChanged,
        TonightKind.chordMove,
        TonightKind.firstLine,
      ]);

      // Closing one takes that one away and nothing else arrives.
      final closed = composeTonightCards(
        today: even,
        releases: <ReleaseNote>[release],
        song: song,
        prompt: prompt,
        seen: (id) => id == 'release-abc1234',
      );
      expect(closed.map((card) => card.kind), <TonightKind>[TonightKind.chordMove, TonightKind.firstLine]);

      // The single-card version is still the first of the list.
      expect(
        composeTonight(today: even, releases: <ReleaseNote>[release], song: song, prompt: prompt, seen: (_) => false)!.kind,
        TonightKind.whatChanged,
      );
    });

    test('every song you left, the longest-left first', () {
      final today = DateTime(2026, 9, 16);
      SongProject left(String title, int daysAgo, {bool audio = true}) => SongProject(
            id: title,
            roomId: 'room',
            accountId: 'account',
            title: title,
            createdAt: today.subtract(Duration(days: daysAgo)),
            updatedAt: today.subtract(Duration(days: daysAgo)),
            hasAudioReference: audio,
          );
      final all = PickItBackUp.all(<SongProject>[
        left('Twenty days', 20),
        left('Forty days', 40),
        left('Five days', 5),
        left('No recording', 60, audio: false),
      ], now: today);
      expect(all.map((each) => each.song.title), <String>['Forty days', 'Twenty days']);
    });
  });

  testWidgets('cards of the same rank hold the order they were given', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    WaitingItem card(String id) => WaitingItem(
          id: id,
          kind: WaitingKind.unfinished,
          line: id,
          actionLabel: 'Open',
          onAction: () {},
          onDismiss: () {},
        );
    final items = <WaitingItem>[for (final id in <String>['c', 'a', 'd', 'b']) card(id)];
    Future<List<String>> order() async {
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(body: Column(children: <Widget>[WaitingOnYou(items: List<WaitingItem>.of(items))])),
        ),
      ));
      await tester.pump();
      final shown = <String>['c', 'a', 'd', 'b']
          .map((id) => (id, tester.getTopLeft(find.byKey(Key('waiting_card_$id'))).dx))
          .toList()
        ..sort((x, y) => x.$2.compareTo(y.$2));
      return shown.map((each) => each.$1).toList();
    }

    expect(await order(), <String>['c', 'a', 'd', 'b']);
    expect(await order(), <String>['c', 'a', 'd', 'b']);
  });

  testWidgets('on Home, closing a song you left takes that card and brings nothing out', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SetAside.load();
    final repository = _ThreeLeftSongs();
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
          body: SongsScreen(displayName: 'Taylor', onOpenAccount: () {}, onOpenNotifications: () {}),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    // What the row is given, rather than what a lazy list has built so far:
    // cards past the edge of the screen are not built until scrolled to.
    List<String> cards(String prefix) => tester
        .widget<WaitingOnYou>(find.byType(WaitingOnYou))
        .items
        .map((item) => item.id)
        .where((id) => id.startsWith(prefix))
        .toList()
      ..sort();

    expect(cards('left-'), hasLength(3), reason: 'all three songs, not one at a time');
    expect(cards('sheet-'), hasLength(3), reason: 'every recording without a sheet');

    // The card's own x, off the edge of a phone-width row and so not built:
    // the same call the x makes.
    tester
        .widget<WaitingOnYou>(find.byType(WaitingOnYou))
        .items
        .firstWhere((item) => item.id == 'left-song-a')
        .onDismiss!();
    await tester.pump(const Duration(milliseconds: 200));

    expect(cards('left-'), <String>['left-song-b', 'left-song-c'],
        reason: 'the closed card goes, and no other song comes out in its place');
    expect(cards('sheet-'), hasLength(3), reason: 'closing one kind of card touches no other');
  });
}

/// One room, three songs recorded long ago with no song sheet: each is both
/// a song you left and a recording waiting for a sheet.
class _ThreeLeftSongs extends InMemoryMusicRepository {
  _ThreeLeftSongs() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<MusicRoom>> loadRooms() async {
    final longAgo = DateTime.now().subtract(const Duration(days: 30));
    SongProject song(String id, int extraDays) => SongProject(
          id: id,
          roomId: 'room-left',
          accountId: 'preview-user',
          title: 'Song ${id.substring(id.length - 1).toUpperCase()}',
          createdAt: longAgo.subtract(Duration(days: extraDays)),
          updatedAt: longAgo.subtract(Duration(days: extraDays)),
          hasAudioReference: true,
        );
    return <MusicRoom>[
      MusicRoom(
        id: 'room-left',
        accountId: 'preview-user',
        name: 'Old ideas',
        icon: '♪',
        createdAt: longAgo,
        updatedAt: longAgo,
        members: const <RoomMember>[
          RoomMember(userId: 'preview-user', displayName: 'Taylor', role: RoomRole.owner, colorValue: 0xFFFF8A4C),
        ],
        projects: <SongProject>[song('song-a', 3), song('song-b', 2), song('song-c', 1)],
      ),
    ];
  }
}
