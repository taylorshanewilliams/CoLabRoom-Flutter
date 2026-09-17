import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/meeting/add_person_screen.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answer somebody where they are shown.
///
/// From the audit, 17 September 2026. Home says "Wants to connect · Mara ·
/// See who", and See who opened a page with no way to answer her. And "Join
/// with a code" -- the one box people reach for -- refused an invitation
/// link, refused a person's code, and with nothing typed said the code was
/// not valid.
Future<(MusicBetaController, InMemoryMusicRepository)> _boot(
  WidgetTester tester,
  Widget Function(InMemoryMusicRepository repository) home, {
  InMemoryMusicRepository? repository,
}) async {
  final repo = repository ?? InMemoryMusicRepository.seeded();
  final controller = MusicBetaController(repo);
  await controller.load();
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home(repo)),
  ));
  await tester.pumpAndSettle();
  return (controller, repo);
}

/// A yes to your ask, the kind that used to open nothing.
class _TheyAreIn extends InMemoryMusicRepository {
  _TheyAreIn() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<AppNotification>> loadNotifications() async => <AppNotification>[
        AppNotification(
          id: 'notif-in',
          type: NotificationType.songAsk,
          title: 'Mara is in',
          body: 'On Midnight Signal.',
          createdAt: DateTime.now(),
          projectId: 'song-1',
        ),
      ];
}

Widget _page(InMemoryMusicRepository repository, String id) =>
    MusicianProfileScreen(profileId: id, repository: repository);

void main() {
  group('on their page', () {
    testWidgets('somebody who asked can be answered: Add back', (tester) async {
      final (_, repository) = await _boot(tester, (repo) => _page(repo, 'preview-mara'));

      expect(find.byKey(const Key('profile_wants_to_add_you')), findsOneWidget,
          reason: 'Home sends you here to answer her');
      expect(find.byKey(const Key('message_them')), findsNothing);

      await tester.tap(find.byKey(const Key('profile_add_back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile_connected')), findsOneWidget);
      expect(find.byKey(const Key('message_them')), findsOneWidget, reason: 'connected people can write');
      final mara = (await repository.listConnections()).firstWhere((c) => c.personId == 'preview-mara');
      expect(mara.accepted, isTrue);
    });

    testWidgets('or Not now, which leaves a way to add them later', (tester) async {
      await _boot(tester, (repo) => _page(repo, 'preview-mara'));

      await tester.tap(find.byKey(const Key('profile_not_now')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile_wants_to_add_you')), findsNothing);
      expect(find.byKey(const Key('profile_add_person')), findsOneWidget);
    });

    testWidgets('anybody else can be added, and the page says you asked', (tester) async {
      await _boot(tester, (repo) => _page(repo, 'preview-dev'));

      expect(find.byKey(const Key('profile_add_person')), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile_add_person')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile_asked')), findsOneWidget);
      expect(find.byKey(const Key('profile_add_person')), findsNothing);
    });

    testWidgets('your own page has none of it', (tester) async {
      await _boot(tester, (repo) => _page(repo, repo.currentUserId));

      expect(find.byKey(const Key('profile_add_person')), findsNothing);
      expect(find.byKey(const Key('profile_wants_to_add_you')), findsNothing);
    });
  });

  group('Join with a code', () {
    Future<void> type(WidgetTester tester, String text) async {
      await tester.tap(find.byKey(const Key('inbox_use_code')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('join_code_field')), text);
      await tester.pump();
    }

    testWidgets('waits for a code', (tester) async {
      await _boot(tester, (_) => const NotificationsScreen());
      await type(tester, '   ');

      final join = tester.widget<FilledButton>(find.byKey(const Key('join_code_submit')));
      expect(join.onPressed, isNull, reason: 'it used to close and say the code was not valid');
    });

    testWidgets('takes the invitation link it was sent', (tester) async {
      final (controller, _) = await _boot(tester, (_) => const NotificationsScreen());
      final before = controller.rooms.length;

      await type(tester, inviteLink('STUDIO-JOIN'));
      await tester.tap(find.byKey(const Key('join_code_submit')));
      await tester.pumpAndSettle();

      expect(find.text('That invite code is not valid.'), findsNothing);
      expect(find.text('Joined. It is under Your music.'), findsOneWidget);
      expect(controller.rooms.length, before + 1);
    });

    testWidgets("opens somebody's card from their code or their link", (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'ze9w27t0', personId: 'preview-dev', displayName: 'Dev Okonjo');
      await _boot(tester, (_) => const NotificationsScreen(), repository: repository);

      await type(tester, 'https://app.colabroom.com/add/ze9w27t0');
      await tester.tap(find.byKey(const Key('join_code_submit')));
      await tester.pumpAndSettle();
      expect(find.byType(AddPersonScreen), findsOneWidget);
      expect(find.text('Dev Okonjo'), findsWidgets);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await type(tester, 'ZE9W-27T0');
      await tester.tap(find.byKey(const Key('join_code_submit')));
      await tester.pumpAndSettle();
      expect(find.byType(AddPersonScreen), findsOneWidget);
    });
  });

  group('the inbox', () {
    testWidgets('a yes to your ask opens the song', (tester) async {
      await _boot(tester, (_) => const NotificationsScreen(), repository: _TheyAreIn());

      await tester.tap(find.text('Mara is in'));
      await tester.pumpAndSettle();

      expect(find.byType(SongWorkspaceScreen), findsOneWidget);
    });

    testWidgets("saying I'm in offers the song straight away", (tester) async {
      await _boot(tester, (_) => const NotificationsScreen());

      await tester.tap(find.text("I'm in"));
      // Until the snackbar has finished arriving.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(SnackBarAction, 'Open'), findsOneWidget);

      await tester.tap(find.widgetWithText(SnackBarAction, 'Open'));
      await tester.pumpAndSettle();
      expect(find.byType(SongWorkspaceScreen), findsOneWidget);
    });
  });

  test('an invitation code comes out of whatever was pasted', () {
    const code = '0123456789abcdef0123456789abcdef0123';
    expect(inviteCodeFromText(code), code);
    expect(inviteCodeFromText('  $code \n'), code);
    expect(inviteCodeFromText(inviteLink(code)), code);
    expect(inviteCodeFromText('https://app.colabroom.com/?invite=$code'), code);
    expect(inviteCodeFromText('https://app.colabroom.com/lesson/0123456789ab'), isNull);
    expect(inviteCodeFromText('hello there'), isNull);
  });
}
