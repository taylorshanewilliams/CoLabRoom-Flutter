import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/deep_link.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/app/routes.dart';
import 'package:colabroom/app/workspace_shell.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:colabroom/features/meeting/add_person_screen.dart';
import 'package:colabroom/features/meeting/your_code_screen.dart';
import 'package:colabroom/features/messages/messages_screen.dart';
import 'package:colabroom/services/incoming_addresses.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:colabroom/widgets/qr_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A code for meeting in person.
///
/// Taylor, 16 September 2026: "could each user have one in their profile?
/// say you meet someone at a concert, or open mic night, or anywhere, you
/// could just scan each other's codes and become friends in the app."
///
/// Opening somebody's code shows whose it is and adds nobody. Adding is a
/// request; the second yes -- adding them back, or scanning theirs -- is what
/// connects two people.
void main() {
  setUp(IncomingAddresses.reset);
  tearDown(IncomingAddresses.reset);

  group('the code', () {
    test('a link opens their card', () {
      expect(meetingLink('k7m29xqp'), 'https://app.colabroom.com/add/k7m29xqp');
      expect(meetingCodeFrom(Uri.parse(meetingLink('k7m29xqp'))), 'k7m29xqp');
      expect(AppRoutes.match(AppRoutes.meet('k7m29xqp')), const RouteTarget(RoutePlace.meet, 'k7m29xqp'));
      expect(AppRoutes.match(AppRoutes.yourCode), const RouteTarget(RoutePlace.yourCode));
    });

    test('is read however it was typed over a band', () {
      expect(meetingCodeFromText('K7M2-9XQP'), 'k7m29xqp');
      expect(meetingCodeFromText(' k7m2 9xqp '), 'k7m29xqp');
      expect(meetingCodeFromText(meetingLink('k7m29xqp')), 'k7m29xqp');
      // Letters people read as digits are those digits.
      expect(meetingCodeFromText('k7m2-9xqO'), 'k7m29xq0');
      expect(meetingCodeFromText('k7mI-9xqL'), 'k7m19xq1');
      expect(meetingCodeFromText('hello'), isNull);
      expect(meetingCodeFromText('0123456789ab'), isNull, reason: 'a lesson code is not a person');
      expect(meetingCodeFromText('k7m2-9xqu'), isNull, reason: 'u is not in the alphabet');
    });

    test('said the way it is read out', () {
      expect(meetingCodeSaid('k7m29xqp'), 'k7m2-9xqp');
    });
  });

  Future<MusicBetaController> boot(WidgetTester tester, InMemoryMusicRepository repository, Widget home) async {
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
    ));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder, Key list) => tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.descendant(of: find.byKey(list), matching: find.byType(Scrollable)).first,
      );

  String? shownCode(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byKey(const Key('meet_code'))).data;

  group('your code', () {
    testWidgets('is a QR code and the code, big', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, YourCodeScreen(repository: repository));

      expect(find.byKey(const Key('meet_qr')), findsOneWidget);
      expect(tester.widget<QrCode>(find.byType(QrCode)).data, meetingLink('k7m29xqp'));
      expect(shownCode(tester), 'k7m2-9xqp');
    });

    testWidgets('somebody who scans it turns up while it is open, and one tap adds them back', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, YourCodeScreen(repository: repository, lookEvery: const Duration(seconds: 1)));
      expect(find.byKey(const Key('meet_waiting_preview-lena')), findsNothing);

      // On the other phone, Lena scans the code and taps Add.
      repository.somebodyAsks(personId: 'preview-lena', displayName: 'Lena', plays: const <String>['Fiddle']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final waiting = find.byKey(const Key('meet_waiting_preview-lena'));
      await scrollTo(tester, waiting, const Key('meet_list'));
      expect(find.descendant(of: waiting, matching: find.text('Lena')), findsOneWidget);

      await tester.tap(find.byKey(const Key('meet_add_back_preview-lena')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('meet_waiting_preview-lena')), findsNothing);
      expect(find.byKey(const Key('meet_connected_preview-lena')), findsOneWidget);
      final lena = (await repository.listConnections()).singleWhere((c) => c.personId == 'preview-lena');
      expect(lena.accepted, isTrue);
    });

    testWidgets('can be changed, after saying what that does', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, YourCodeScreen(repository: repository));

      await tester.tap(find.byKey(const Key('meet_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('meet_change')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your old code stops opening your card'), findsOneWidget);
      await tester.tap(find.byKey(const Key('meet_change_confirm')));
      await tester.pumpAndSettle();

      expect(shownCode(tester), 'p4r8-tv2w');
      expect(tester.widget<QrCode>(find.byType(QrCode)).data, meetingLink('p4r8tv2w'));
    });

    testWidgets('a typed code opens their card, and a wrong one says what a code looks like', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'q8r2mn4p', personId: 'preview-maria', displayName: 'Maria');
      await boot(tester, repository, YourCodeScreen(repository: repository));

      final typed = find.byKey(const Key('meet_typed'));
      await scrollTo(tester, typed, const Key('meet_list'));
      await tester.enterText(typed, 'nope');
      await tester.tap(find.byKey(const Key('meet_open')));
      await tester.pumpAndSettle();
      expect(find.text('Codes look like k7m2-9xqp.'), findsOneWidget);

      await tester.enterText(typed, 'Q8R2-MN4P');
      await tester.tap(find.byKey(const Key('meet_open')));
      await tester.pumpAndSettle();
      expect(find.byType(AddPersonScreen), findsOneWidget);
      expect(find.byKey(const Key('add_person_name')), findsOneWidget);
      expect(find.text('Maria'), findsOneWidget);
    });
  });

  group('a small phone with large text', () {
    Future<void> small(WidgetTester tester, InMemoryMusicRepository repository, Widget screen) async {
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: MediaQuery.withClampedTextScaling(minScaleFactor: 1.3, maxScaleFactor: 1.3, child: screen),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('your code, with somebody waiting on you', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..somebodyAsks(personId: 'preview-long', displayName: 'Alexandria Montgomery-Whitfield', plays: const <String>['Pedal steel', 'Mandolin']);
      await small(tester, repository, YourCodeScreen(repository: repository));
      expect(tester.takeException(), isNull);
      final waiting = find.byKey(const Key('meet_waiting_preview-long'));
      await scrollTo(tester, waiting, const Key('meet_list'));
      expect(tester.takeException(), isNull);
      await scrollTo(tester, find.byKey(const Key('meet_open')), const Key('meet_list'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('their card, with a long name', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'q8r2mn4p', personId: 'preview-long', displayName: 'Alexandria Montgomery-Whitfield', plays: const <String>['Pedal steel', 'Mandolin', 'Voice']);
      await small(tester, repository, AddPersonScreen(code: 'q8r2mn4p', repository: repository));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('add_person_add')), findsOneWidget);
    });
  });

  group('their card', () {
    testWidgets('shows whose it is and adds nobody until you tap', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'q8r2mn4p', personId: 'preview-maria', displayName: 'Maria', plays: const <String>['Voice']);
      await boot(tester, repository, AddPersonScreen(code: 'q8r2-mn4p', repository: repository));

      expect(find.text('Maria'), findsOneWidget);
      expect(find.text('Voice'), findsOneWidget);
      expect((await repository.listConnections()).where((c) => c.personId == 'preview-maria'), isEmpty,
          reason: 'opening a code is not asking');

      await tester.tap(find.text('Add Maria'));
      await tester.pumpAndSettle();

      expect(find.text('Asked'), findsOneWidget);
      expect(find.textContaining('once Maria says yes, or scans your code'), findsOneWidget);
      final maria = (await repository.listConnections()).singleWhere((c) => c.personId == 'preview-maria');
      expect(maria.accepted, isFalse);
      expect(maria.incoming, isFalse);
    });

    testWidgets('somebody who already scanned yours is one tap from connected', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'q8r2mn4p', personId: 'preview-maria', displayName: 'Maria')
        ..somebodyAsks(personId: 'preview-maria', displayName: 'Maria');
      await boot(tester, repository, AddPersonScreen(code: 'q8r2mn4p', repository: repository));

      expect(find.text('Maria already asked to add you.'), findsOneWidget);
      await tester.tap(find.text('Add Maria back'));
      await tester.pumpAndSettle();

      expect(find.text('You and Maria are connected.'), findsOneWidget);
      final maria = (await repository.listConnections()).singleWhere((c) => c.personId == 'preview-maria');
      expect(maria.accepted, isTrue);
    });

    testWidgets('your own code, and a code that opens nobody, say so', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, AddPersonScreen(code: 'k7m2-9xqp', repository: repository));
      expect(find.text('That is your own code. Show it to somebody.'), findsOneWidget);
      expect(find.byKey(const Key('add_person_my_code')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await boot(tester, repository, AddPersonScreen(code: 'zzzz-zzzz', repository: repository));
      expect(find.textContaining('That code does not open anybody'), findsOneWidget);
    });

    testWidgets('somebody you are already connected to says so', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'j3ss1cab', personId: 'preview-jess', displayName: 'Jess');
      await boot(tester, repository, AddPersonScreen(code: 'j3ss1cab', repository: repository));

      expect(find.text('You and Jess are already connected.'), findsOneWidget);
      expect(find.byKey(const Key('add_person_add')), findsNothing);
    });
  });

  group('ways in', () {
    testWidgets('beside the lesson link, in Messages', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, const MessagesScreen());
      await tester.tap(find.byKey(const Key('messages_new')));
      await tester.pumpAndSettle();
      expect(find.text('Meet somebody: your code'), findsOneWidget);
      await tester.tap(find.byKey(const Key('messages_new_meet')));
      await tester.pumpAndSettle();
      expect(find.byType(YourCodeScreen), findsOneWidget);
    });

    testWidgets('on your profile', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, const AccountScreen());
      final row = find.text('Your code, for meeting people');
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(YourCodeScreen), findsOneWidget);
    });

    test('an address opens either screen cold', () {
      final repository = InMemoryMusicRepository.seeded();
      expect(DeepLink.routeFor(meetingLink('k7m29xqp'), repository: repository), isNotNull);
      expect(DeepLink.routeFor(AppRoutes.yourCode, repository: repository), isNotNull);
    });

    Future<MusicBetaController> bootShell(WidgetTester tester, InMemoryMusicRepository repository) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: WorkspaceShell(controller: controller)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return controller;
    }

    testWidgets('a code scanned with the phone camera opens the app on their card', (tester) async {
      tester.platformDispatcher.defaultRouteNameTestValue = meetingLink('q8r2mn4p');
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'q8r2mn4p', personId: 'preview-maria', displayName: 'Maria');

      await bootShell(tester, repository);

      expect(find.byType(AddPersonScreen), findsOneWidget);
      expect(find.text('Add Maria'), findsOneWidget);
      expect(
        (await repository.listConnections()).where((c) => c.personId == 'preview-maria'),
        isEmpty,
        reason: 'a scan opens the card; it never adds by itself',
      );
    });

    testWidgets('and one scanned while the app is open does the same', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerMeetingCode(code: 'q8r2mn4p', personId: 'preview-maria', displayName: 'Maria');
      await bootShell(tester, repository);

      await IncomingAddresses().didPushRouteInformation(
        RouteInformation(uri: Uri.parse('https://app.colabroom.com/add/q8r2mn4p')),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(AddPersonScreen), findsOneWidget);
      expect(find.text('Add Maria'), findsOneWidget);
    });
  });
}
