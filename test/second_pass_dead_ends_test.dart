import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/listen_screen.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:colabroom/features/rooms/room_members_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dead ends from the second pass of the audit, 17 September 2026.
class _NothingUp extends InMemoryMusicRepository {
  _NothingUp() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<FeedTrack>> openMicFeed({int limit = 12, String? part}) async => const <FeedTrack>[];
}

/// A song on the Open Mic that is yours.
class _Mine extends InMemoryMusicRepository {
  _Mine() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<OpenMicSong?> openMicSong(String projectId) async => OpenMicSong(
        id: projectId,
        title: 'Midnight Signal',
        ownerName: 'Taylor',
        ownerId: currentUserId,
        putUpAt: DateTime.now(),
        heard: 3,
      );
}

Future<MusicBetaController> _pump(WidgetTester tester, InMemoryMusicRepository repository, Widget page) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Go'));
  for (var i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  return controller;
}

void main() {
  testWidgets('Listen with nothing up still has a way back', (tester) async {
    final repository = _NothingUp();
    await _pump(tester, repository, ListenScreen(repository: repository));

    expect(find.text('Nothing to listen to yet'), findsOneWidget);
    expect(find.byKey(const Key('listen_close')), findsOneWidget, reason: 'it was only drawn over tracks');

    await tester.tap(find.byKey(const Key('listen_close')));
    await tester.pumpAndSettle();
    expect(find.byType(ListenScreen), findsNothing);
  });

  testWidgets('your own song on the Open Mic is not offered back to you', (tester) async {
    final repository = _Mine();
    await _pump(tester, repository, OpenMicSongScreen(projectId: 'song-1', repository: repository));

    expect(find.text('Offer to play on this'), findsNothing);
    expect(find.byTooltip('Report this song'), findsNothing);
    expect(find.byKey(const Key('open_mic_yours')), findsOneWidget);
    expect(find.textContaining('3 people heard it'), findsOneWidget);
    expect(find.byKey(const Key('open_mic_yours_offers')), findsOneWidget);
    expect(find.byKey(const Key('open_mic_yours_open')), findsOneWidget);
  });

  testWidgets("somebody else's song still is", (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    final feed = await repository.openMicFeed();
    await _pump(tester, repository, OpenMicSongScreen(projectId: feed.first.id, repository: repository));

    expect(find.text('Offer to play on this'), findsOneWidget);
    expect(find.byKey(const Key('open_mic_yours')), findsNothing);
  });

  testWidgets("a member of the room opens their page; you don't open yours", (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    final room = controller.rooms.firstWhere((r) => r.members.length > 1);
    final other = room.members.firstWhere((m) => m.userId != repository.currentUserId);
    controller.dispose();

    await _pump(tester, repository, RoomMembersScreen(roomId: room.id));

    await tester.tap(find.byKey(Key('member_${other.userId}')));
    await tester.pumpAndSettle();
    expect(find.byType(MusicianProfileScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('member_${repository.currentUserId}')));
    await tester.pumpAndSettle();
    expect(find.byType(MusicianProfileScreen), findsNothing);
  });
}
