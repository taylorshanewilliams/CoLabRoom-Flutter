import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/app/routes.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/openmic/people_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Somebody wants to add you.
///
/// Scanning somebody's code sends them a request, and until 0132 nothing
/// told them: at a gig the phone goes back in the pocket the moment the code
/// has been scanned. Now a request arrives as a notification, and so does
/// the yes. Each card goes where the next step is.
class _Asked extends InMemoryMusicRepository {
  _Asked() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<AppNotification>> loadNotifications() async => <AppNotification>[
        AppNotification(
          id: 'notif-request',
          type: NotificationType.connectionRequest,
          title: 'Lena wants to add you',
          body: 'Add them back and you are connected.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
          actorId: 'preview-lena',
        ),
        AppNotification(
          id: 'notif-accepted',
          type: NotificationType.connectionAccepted,
          title: 'You and Jess are connected',
          body: 'Jess is one of your people now.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 7)),
          actorId: 'preview-jess',
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

Future<_Routes> _inbox(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = MusicBetaController(_Asked());
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  test('this build knows both words', () {
    expect(notificationTypeFromSql('connection_request'), NotificationType.connectionRequest);
    expect(notificationTypeFromSql('connection_accepted'), NotificationType.connectionAccepted);
  });

  testWidgets('a request opens Your people, where it is answered', (tester) async {
    final routes = await _inbox(tester);
    await tester.tap(find.text('Lena wants to add you'));
    await _settle(tester);

    expect(routes.pushed, contains(AppRoutes.people));
    expect(find.byType(PeopleScreen), findsOneWidget);
  });

  testWidgets('a yes opens the page of the person who said it', (tester) async {
    final routes = await _inbox(tester);
    await tester.tap(find.text('You and Jess are connected'));
    await _settle(tester);

    expect(routes.pushed, contains(AppRoutes.musician('preview-jess')));
    expect(find.byType(MusicianProfileScreen), findsOneWidget);
  });
}
