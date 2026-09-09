import 'package:colabroom/app/routes.dart';
import 'package:colabroom/services/browser_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every place in the app that deserves an address, and the fact that the
/// address survives the trip.
///
/// A phone app needs none of this: you are wherever the last tap put you and
/// nobody types a screen's name. Thirty-odd anonymous `Navigator.push` calls
/// are the right shape for a phone and the reason the web build felt like a
/// phone in a browser — **addressable state is most of what separates them.**
///
/// The table is written to be read as well as written, because the next step
/// is a parser turning these into real deep links, and a parser that
/// re-derives the shapes from string literals scattered through the app is
/// how the two halves drift apart. [AppRoutes.match] is that reading, and it
/// is tested against the same builders the pushes use.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every address the app writes is one it can read back', () {
    final cases = <String, RouteTarget>{
      AppRoutes.home: const RouteTarget(RoutePlace.home),
      AppRoutes.openMic: const RouteTarget(RoutePlace.openMic),
      AppRoutes.listen: const RouteTarget(RoutePlace.listen),
      AppRoutes.song('abc'): const RouteTarget(RoutePlace.song, 'abc'),
      AppRoutes.songSheet('abc'): const RouteTarget(RoutePlace.songSheet, 'abc'),
      AppRoutes.songTakes('abc'): const RouteTarget(RoutePlace.songTakes, 'abc'),
      AppRoutes.songLive('abc'): const RouteTarget(RoutePlace.songLive, 'abc'),
      AppRoutes.songLyrics('abc'):
          const RouteTarget(RoutePlace.songLyrics, 'abc'),
      AppRoutes.songHistory('abc'):
          const RouteTarget(RoutePlace.songHistory, 'abc'),
      AppRoutes.heard('xy'): const RouteTarget(RoutePlace.heard, 'xy'),
      AppRoutes.musician('me'): const RouteTarget(RoutePlace.musician, 'me'),
      AppRoutes.room('r1'): const RouteTarget(RoutePlace.room, 'r1'),
      AppRoutes.setlist('s1'): const RouteTarget(RoutePlace.setlist, 's1'),
      AppRoutes.account: const RouteTarget(RoutePlace.account),
      AppRoutes.notifications: const RouteTarget(RoutePlace.notifications),
      AppRoutes.help: const RouteTarget(RoutePlace.help),
      AppRoutes.whatYouGet: const RouteTarget(RoutePlace.whatYouGet),
      AppRoutes.notificationSettings:
          const RouteTarget(RoutePlace.notificationSettings),
      AppRoutes.blocked: const RouteTarget(RoutePlace.blocked),
      AppRoutes.latency: const RouteTarget(RoutePlace.latency),
    };

    for (final entry in cases.entries) {
      expect(AppRoutes.match(entry.key), entry.value,
          reason: '${entry.key} did not read back as ${entry.value}');
    }
  });

  test('every place in the table is reachable by some address', () {
    final reached =
        <RoutePlace>{for (final p in RoutePlace.values) p}..removeAll(<RoutePlace>{
        for (final path in <String>[
          AppRoutes.home,
          AppRoutes.openMic,
          AppRoutes.listen,
          AppRoutes.song('a'),
          AppRoutes.songSheet('a'),
          AppRoutes.songTakes('a'),
          AppRoutes.songLive('a'),
          AppRoutes.songLyrics('a'),
          AppRoutes.songHistory('a'),
          AppRoutes.heard('a'),
          AppRoutes.musician('a'),
          AppRoutes.room('a'),
          AppRoutes.setlist('a'),
          AppRoutes.account,
          AppRoutes.notifications,
          AppRoutes.help,
          AppRoutes.whatYouGet,
          AppRoutes.notificationSettings,
          AppRoutes.blocked,
          AppRoutes.latency,
        ])
          AppRoutes.match(path)!.place,
      });

    expect(reached, isEmpty,
        reason: 'a place with no address is a screen the parser will never '
            'be able to restore');
  });

  test('nonsense is not a place', () {
    expect(AppRoutes.match('/song'), isNull);
    expect(AppRoutes.match('/nowhere'), isNull);
    expect(AppRoutes.match('/settings/teleport'), isNull);
    expect(AppRoutes.match('/song/abc/oscillate'), isNull);
  });

  test('a named route keeps its address instead of being slugified', () async {
    final sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, (call) async {
      sent.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.navigation, null);
    });

    final history = BrowserHistory(onWeb: true);
    final first = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    history.didPush(first, null);
    history.didPush(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.song('ladder-of-life')),
        builder: (_) => const SizedBox(),
      ),
      first,
    );

    final last = sent.lastWhere((c) => c.method == 'routeInformationUpdated');
    expect(last.arguments['uri'], '/song/ladder-of-life',
        reason: 'slugifying an address would turn /song/abc into -song-abc '
            'and lose the only real path in the app');
  });
}
