import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:colabroom/app/deep_link.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/app/workspace_shell.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/features/rooms/room_detail_screen.dart';
import 'package:colabroom/features/shell/join_from_address.dart';
import 'package:colabroom/services/incoming_addresses.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:colabroom/services/moment_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A link opens the app.
///
/// Taylor, 16 September 2026, after the lesson QR code: "could each user
/// have one in their profile? Say you meet someone at a concert ... you
/// could just scan each other's codes." A phone's camera opened every
/// app.colabroom.com code in the browser, on a sign-in page, even with the
/// app installed. So first: the link opens the app, whether it starts the
/// app or arrives while the app is already open.
void main() {
  setUp(IncomingAddresses.reset);
  tearDown(IncomingAddresses.reset);

  group('which addresses are ours', () {
    test('the web hands over paths, a phone whole links', () {
      expect(IncomingAddresses.isOurs(Uri.parse('/song/abc')), isTrue);
      expect(IncomingAddresses.isOurs(Uri.parse(lessonLink('0123456789ab'))), isTrue);
      expect(IncomingAddresses.isOurs(Uri.parse('https://app.colabroom.com/room/r1')), isTrue);
    });

    test("the sign-in callback and other sites are not the shell's", () {
      expect(
        IncomingAddresses.isOurs(Uri.parse('com.colabroom.beta://login-callback?code=x')),
        isFalse,
      );
      expect(IncomingAddresses.isOurs(Uri.parse('http://app.colabroom.com/song/abc')), isFalse);
      expect(IncomingAddresses.isOurs(Uri.parse('https://colabroom.com/song/abc')), isFalse);
      expect(IncomingAddresses.isOurs(Uri.parse('https://evil.example/lesson/0123456789ab')), isFalse);
    });

    test('the sign-in callback is swallowed, and never reaches the shell', () async {
      final opened = <Uri>[];
      void open(Uri address) => opened.add(address);
      IncomingAddresses.attach(open);
      addTearDown(() => IncomingAddresses.detach(open));

      final handled = await IncomingAddresses().didPushRouteInformation(
        RouteInformation(uri: Uri.parse('com.colabroom.beta://login-callback?code=x')),
      );
      // Handled, or the framework pushes it onto a navigator with no routes
      // and throws -- which it did, every time the callback came back to a
      // running app.
      expect(handled, isTrue);
      expect(opened, isEmpty);
      expect(IncomingAddresses.waiting, isNull);
    });
  });

  group('a link from app_links, the way an iPhone hands one over', () {
    test('waits for a shell, then opens; the sign-in callback is left alone', () async {
      final links = StreamController<Uri>();
      addTearDown(links.close);
      IncomingAddresses.install(links: links.stream);

      final launch = Uri.parse(meetingLink('k7m29xqp'));
      links
        ..add(Uri.parse('com.colabroom.beta://login-callback?code=x'))
        ..add(launch);
      await pumpEventQueue();
      expect(IncomingAddresses.waiting, launch, reason: 'nothing could open it yet: signed out, or still loading');

      final opened = <Uri>[];
      void open(Uri address) => opened.add(address);
      IncomingAddresses.attach(open);
      addTearDown(() => IncomingAddresses.detach(open));
      final later = Uri.parse(lessonLink('0123456789ab'));
      links.add(later);
      await pumpEventQueue();
      expect(opened, <Uri>[later]);
    });
  });

  group('a link tapped while signed out', () {
    test('waits, and the next shell starts there', () async {
      final link = Uri.parse('https://app.colabroom.com/song/ladder');
      await IncomingAddresses().didPushRouteInformation(RouteInformation(uri: link));

      expect(IncomingAddresses.waiting, link);
      final stack = DeepLink.stackFor(
        path: DeepLink.initialRoute(WidgetsBinding.instance),
        shell: (tab) => const SizedBox(),
        repository: InMemoryMusicRepository.seeded(),
      );
      expect(stack.length, 2, reason: 'the song on top of the shell');
    });

    test('is taken once', () async {
      final link = Uri.parse(lessonLink('0123456789ab'));
      await IncomingAddresses().didPushRouteInformation(RouteInformation(uri: link));

      expect(IncomingAddresses.takeArrival(), link);
      expect(IncomingAddresses.takeArrival(), isNull,
          reason: 'joining is an action: signing in again must not repeat it');
    });
  });

  group('what the phone claims', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final filter = RegExp(r'<intent-filter android:autoVerify="true">(.*?)</intent-filter>', dotAll: true)
        .firstMatch(manifest)!
        .group(1)!;
    final prefixes =
        RegExp(r'android:pathPrefix="([^"]+)"').allMatches(filter).map((m) => m.group(1)!).toList();

    test('app.colabroom.com, over https, by path', () {
      expect(filter, contains('android:scheme="https"'));
      expect(filter, contains('android:host="${IncomingAddresses.host}"'));
      expect(filter, isNot(contains('android:path=')));
      expect(filter, isNot(contains('android:pathPattern=')));
      expect(prefixes, isNotEmpty);
      for (final prefix in prefixes) {
        expect(prefix, matches(RegExp(r'^/[a-z-]+/$')),
            reason: 'never the root: password resets and account deletion land there, '
                'and only work in a browser');
      }
    });

    // One real address under each prefix. Most prefixes take a code or an id
    // and nothing else; a moment names a room, a song and a place in it, so
    // it is written by the same function the app writes it with.
    String addressUnder(String prefix) => switch (prefix) {
          '/r/' => momentLink(roomId: '0123456789ab', projectId: 'p1', atMs: 108000),
          _ => 'https://${IncomingAddresses.host}${prefix}0123456789ab',
        };

    test('every path it claims is one the app opens', () {
      final repository = InMemoryMusicRepository.seeded();
      for (final prefix in prefixes) {
        final address = Uri.parse(addressUnder(prefix));
        final opens = opensARoom(address) ||
            DeepLink.routeFor(address.toString(), repository: repository) != null;
        expect(opens, isTrue, reason: '$prefix is claimed, so a link there leaves the browser for the app');
      }
    });

    test('every link the app makes is claimed', () {
      for (final link in <String>[
        lessonLink('0123456789ab'),
        inviteLink('AB12-CD34'),
        meetingLink('k7m29xqp'),
        // Every Musician, Same Song, 17 September 2026 (schools, item 1).
        // The first link the app writes with a query on it, and the one that
        // would most quietly have gone to a browser instead of the app.
        momentLink(roomId: 'r1', projectId: 'p1', takeId: 't1', atMs: 108000),
      ]) {
        final address = Uri.parse(link);
        expect(address.host, IncomingAddresses.host);
        expect(prefixes.any((prefix) => address.path.startsWith(prefix)), isTrue,
            reason: '$link would open the browser, not the app');
      }
    });

    test('iPhones are told exactly the same paths', () {
      final association = jsonDecode(File('web/.well-known/apple-app-site-association').readAsStringSync())
          as Map<String, dynamic>;
      final details = ((association['applinks'] as Map<String, dynamic>)['details'] as List<dynamic>).single
          as Map<String, dynamic>;
      // Filled in from the APPLE_TEAM_ID secret by build-web.yml.
      expect(details['appIDs'], <String>['__APPLE_TEAM_ID__.com.colabroom.beta']);
      final paths = <String>{
        for (final component in details['components'] as List<dynamic>) (component as Map<String, dynamic>)['/'] as String,
      };
      expect(paths, <String>{for (final prefix in prefixes) '$prefix*'},
          reason: 'a path only one phone opens is a link that behaves differently on the other');

      final web = File('.github/workflows/build-web.yml').readAsStringSync();
      expect(web, contains('s/__APPLE_TEAM_ID__/'));
      expect(web, contains('include-hidden-files: true'));
    });

    test('the iPhone build asks for the domain, and takes links through app_links', () {
      final ios = File('.github/workflows/build-ios-testflight.yml').readAsStringSync();
      expect(ios, contains('com.apple.developer.associated-domains'));
      expect(ios, contains('applinks:${IncomingAddresses.host}'));
      // The engine's own handling sends a cold-start link back to Safari
      // after three seconds without a first frame.
      expect(ios, contains('plist_set :FlutterDeepLinkingEnabled false bool'));
      expect(ios, contains('force: ENV["NEW_SIGNING_PROFILE"] == "true"'));
    });

    test('the site vouches for this app and its key', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      final applicationId = RegExp(r'applicationId = "([^"]+)"').firstMatch(gradle)!.group(1);
      final statements = jsonDecode(File('web/.well-known/assetlinks.json').readAsStringSync()) as List<dynamic>;
      final statement = statements.single as Map<String, dynamic>;
      final target = statement['target'] as Map<String, dynamic>;

      expect(statement['relation'], contains('delegate_permission/common.handle_all_urls'));
      expect(target['namespace'], 'android_app');
      expect(target['package_name'], applicationId);
      for (final fingerprint in target['sha256_cert_fingerprints'] as List<dynamic>) {
        expect(fingerprint, matches(RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$')));
      }
    });
  });

  group('the whole app', () {
    Future<MusicBetaController> boot(WidgetTester tester, InMemoryMusicRepository repository) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: WorkspaceShell(controller: controller)));
      await tester.pump(const Duration(milliseconds: 200));
      return controller;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('a lesson QR code that starts the app opens the lesson room', (tester) async {
      tester.platformDispatcher.defaultRouteNameTestValue = lessonLink('0123456789ab');
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      // An adult: lesson links are for people 18 and over since 0139, and
      // what happens for everybody else is in
      // lesson_links_are_for_adults_test.dart.
      final repository = InMemoryMusicRepository.seeded()
        ..callStanding = CallStanding.adult
        ..offerLesson(code: '0123456789ab', title: 'Guitar lessons', teacherName: 'Maria');

      final controller = await boot(tester, repository);
      await settle(tester);

      expect(controller.rooms.where((room) => room.name.startsWith('Guitar lessons')), hasLength(1));
      expect(find.byType(RoomDetailScreen), findsOneWidget);
    });

    testWidgets('one scanned while the app is open does the same', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..callStanding = CallStanding.adult
        ..offerLesson(code: '0123456789ab', title: 'Guitar lessons', teacherName: 'Maria');
      final controller = await boot(tester, repository);
      final before = controller.rooms.length;

      // Exactly what Android pushes when the app is already running.
      await IncomingAddresses().didPushRouteInformation(
        RouteInformation(uri: Uri.parse('https://app.colabroom.com/lesson/0123456789ab')),
      );
      await settle(tester);

      expect(controller.rooms.length, before + 1);
      expect(find.byType(RoomDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
