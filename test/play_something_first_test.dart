import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/welcome/play_later.dart';
import 'package:colabroom/features/welcome/welcome_flow.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The first minute. One invitation to play something, and an honest way
/// out for somebody on a bus -- Taylor: "what if someone wants to check the
/// app out, but is busy and cant record at that moment."
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PlayLater.reset();
    SetAside.resetForTesting();
  });

  Future<Future<WelcomeOutcome?> Function()> open(WidgetTester tester) async {
    WelcomeOutcome? outcome;
    var popped = false;
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const Key('host_open'),
            onPressed: () async {
              outcome = await Navigator.of(context).push<WelcomeOutcome>(
                MaterialPageRoute<WelcomeOutcome>(
                  builder: (_) => WelcomeFlow(
                    repository: InMemoryMusicRepository.seeded(),
                    displayName: 'Taylor',
                  ),
                ),
              );
              popped = true;
            },
            child: const Text('host'),
          ),
        ),
      ),
    ));
    return () async {
      await tester.pumpAndSettle();
      return popped ? (outcome ?? WelcomeOutcome.done) : null;
    };
  }

  testWidgets('the first run asks for a song, not four answers', (tester) async {
    final result = await open(tester);
    await tester.tap(find.byKey(const Key('host_open')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Play something'), findsOneWidget);
    expect(find.byKey(const Key('welcome_record_now')), findsOneWidget);
    expect(find.byKey(const Key('welcome_not_now')), findsOneWidget);
    // None of the questions, and no Skip over a screen with its own way out.
    expect(find.text('What do you play?'), findsNothing);
    expect(find.text('Skip'), findsNothing);

    await tester.tap(find.byKey(const Key('welcome_record_now')));
    expect(await result(), WelcomeOutcome.record);
    expect(PlayLater.skippedThisSession, isFalse);
  });

  testWidgets('"not now" is a real answer, and is remembered for later',
      (tester) async {
    final result = await open(tester);
    await tester.tap(find.byKey(const Key('host_open')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('welcome_not_now')));
    expect(await result(), WelcomeOutcome.later);
    expect(PlayLater.skippedThisSession, isTrue);
    // Not in this session: they asked to look around, so they look around.
    expect(PlayLater.shouldRemind(hasAnyRecording: false), isFalse);
  });

  group('the card on the next launch', () {
    test('appears once the app has been reopened, until there is a recording',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'welcome_record_skipped_at': 1000,
      });
      await PlayLater.load();
      expect(PlayLater.shouldRemind(hasAnyRecording: false), isTrue);
      expect(PlayLater.shouldRemind(hasAnyRecording: true), isFalse);
    });

    test('never appears for somebody who did not say not now', () async {
      await PlayLater.load();
      expect(PlayLater.shouldRemind(hasAnyRecording: false), isFalse);
    });

    test('closing it is remembered on the device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'welcome_record_skipped_at': 1000,
      });
      await SetAside.load();
      await PlayLater.load();
      expect(PlayLater.shouldRemind(hasAnyRecording: false), isTrue);
      await SetAside.add(SetAside.playLater, 'first');
      expect(PlayLater.shouldRemind(hasAnyRecording: false), isFalse);
    });
  });

  testWidgets('the questions are asked before the room, once, and only when '
      'nothing has been answered', (tester) async {
    // A seeded "me" has answers already, so nothing should be asked.
    final repository = InMemoryMusicRepository.seeded();
    late BuildContext hostContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        hostContext = context;
        return const Scaffold(body: SizedBox());
      }),
    ));
    await WelcomeFlow.offerBeforeTheRoom(
      hostContext,
      repository: repository,
      displayName: 'Taylor',
    );
    await tester.pumpAndSettle();
    final me = await repository.loadMusician(repository.currentUserId);
    final answered = me != null &&
        (me.plays.isNotEmpty || (me.city?.isNotEmpty ?? false) || me.soundsLike.isNotEmpty);
    expect(find.text('Before you look around the room.'), answered ? findsNothing : findsOneWidget);
    // Either way, it is marked as offered and will not come back.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('welcome_room_questions_seen_v1'), isTrue);
  });
}
