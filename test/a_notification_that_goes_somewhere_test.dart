import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A notification that goes somewhere.
///
/// "Mountains is ready" used to be a card that marked itself read and left
/// the person to find the song by hand. News about a song now opens the
/// song -- for the two kinds that imply you can open it -- and an ask stays
/// with its own card, because the person asked cannot open the song until
/// they say yes.
class _WithSongNews extends InMemoryMusicRepository {
  _WithSongNews() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<AppNotification>> loadNotifications() async => <AppNotification>[
        AppNotification(
          id: 'notif-ready',
          type: NotificationType.analysisReady,
          title: 'Midnight Signal is ready',
          body: 'Key, tempo, chords and structure are on the song sheet.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
          projectId: 'song-1',
        ),
        AppNotification(
          id: 'notif-ask',
          type: NotificationType.songAsk,
          title: 'Somebody asked you to play bass',
          body: 'A song',
          createdAt: DateTime.now().subtract(const Duration(minutes: 9)),
          // The song of the ask waiting in the inbox, which is not yours yet.
          // An ask's card that says "Mara is in" is about a song you already
          // have, and that one does open it (answer_them_where_they_are_test).
          projectId: 'preview-project-1',
        ),
      ];
}

class _Routes extends NavigatorObserver {
  final List<String?> pushed = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
  }
}

Future<_Routes> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(_WithSongNews());
  await controller.load();
  addTearDown(controller.dispose);

  final routes = _Routes();
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      navigatorObservers: <NavigatorObserver>[routes],
      home: const NotificationsScreen(),
    ),
  ));
  for (var i = 0; i < 5; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  return routes;
}

void main() {
  testWidgets('news about a song opens the song', (tester) async {
    final routes = await _open(tester);
    expect(find.text('Midnight Signal is ready'), findsOneWidget);

    await tester.tap(find.text('Midnight Signal is ready'));
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(routes.pushed, contains('/song/song-1'));
  });

  testWidgets('an ask stays with its own card', (tester) async {
    final routes = await _open(tester);
    expect(find.text('Somebody asked you to play bass'), findsOneWidget);

    await tester.tap(find.text('Somebody asked you to play bass'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(routes.pushed.where((name) => name != null && name.startsWith('/song/')), isEmpty,
        reason: 'the person asked cannot open the song until they say yes');
  });
}
