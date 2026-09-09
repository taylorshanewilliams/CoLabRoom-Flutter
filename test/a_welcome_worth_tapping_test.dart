import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/welcome/interludes.dart';
import 'package:colabroom/features/welcome/welcome_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The four columns Open Mic matches on, and whether anything ever fills them.
///
/// `find_musicians` searches `plays`, `city` and `soundsLike`. Nothing in the
/// app has ever asked for any of them, which is why `BeFound` can say "almost
/// nobody in production is findable… nobody says what they play either". The
/// room a new person walks into has one person in it.
class _Spy extends InMemoryMusicRepository {
  _Spy({this.existing}) : super.from(InMemoryMusicRepository.seeded());

  /// What this account already said, for the tour to fill in.
  final Musician? existing;

  @override
  Future<Musician?> loadMusician(String profileId) async =>
      existing ?? super.loadMusician(profileId);

  bool saved = false;
  bool? discoverable;
  String? city;
  List<String>? plays;
  List<String>? soundsLike;

  @override
  Future<void> setOpenMicPresence({
    required bool discoverable,
    String? city,
    String? locationVisibility,
    List<String>? plays,
    List<String>? soundsLike,
  }) async {
    saved = true;
    this.discoverable = discoverable;
    this.city = city;
    this.plays = plays;
    this.soundsLike = soundsLike;
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i += 1) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _open(
  WidgetTester tester,
  _Spy spy, {
  bool motion = true,
  WelcomeMode mode = WelcomeMode.firstRun,
}) async {
  // Pushed over something, the way the app does it. Making the flow the
  // `home` route instead means popping it leaves an empty navigator with no
  // Scaffold — and then the closing snackbar has nowhere to render, which
  // looks exactly like the app forgetting to show it.
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(disableAnimations: !motion),
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('host_open'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WelcomeFlow(
                    repository: spy,
                    displayName: 'Taylor',
                    mode: mode,
                  ),
                ),
              ),
              child: const Text('host'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('host_open')));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('what somebody taps is what gets saved', (tester) async {
    final spy = _Spy();
    // No motion, so the walk is about the answers rather than about waiting
    // out three interludes.
    await _open(tester, spy, motion: false);

    await tester.tap(find.text("Let's go"));
    await _settle(tester);

    await tester.tap(find.text('Singer'));
    await tester.tap(find.text('Keys'));
    await _settle(tester);
    await tester.tap(find.text('Next'));
    await _settle(tester);

    await tester.enterText(find.byType(TextField), 'Deltona');
    await tester.tap(find.text('Next'));
    await _settle(tester);

    await tester.tap(find.text('indie'));
    await _settle(tester);
    await tester.tap(find.text('Next'));
    await _settle(tester);

    await tester.tap(find.text('Start playing'));
    await _settle(tester);

    expect(spy.saved, isTrue, reason: 'the flow finished without saving');
    // Said once, on the way out, at the only moment it means anything: the
    // flow has just closed and the Account button is on screen.
    expect(
      find.textContaining('Show me around'),
      findsOneWidget,
      reason: 'nothing told them these questions can be reopened, so the '
          'tour is a feature only somebody who goes looking will find',
    );
    expect(spy.plays, containsAll(<String>['vocal', 'keys']),
        reason: 'plays is what find_musicians matches on');
    expect(spy.city, 'Deltona');
    expect(spy.soundsLike, contains('indie'));
    expect(spy.discoverable, isTrue);
  });

  testWidgets('skip saves nothing at all', (tester) async {
    final spy = _Spy();
    await _open(tester, spy, motion: false);

    await tester.tap(find.text('Skip'));
    await _settle(tester);

    expect(spy.saved, isFalse,
        reason: 'somebody who wants to see the app is owed the app, and owes '
            'nothing in return');
  });

  testWidgets('an answer can be taken back', (tester) async {
    final spy = _Spy();
    await _open(tester, spy, motion: false);
    await tester.tap(find.text("Let's go"));
    await _settle(tester);

    await tester.tap(find.text('Drums'));
    await _settle(tester);
    await tester.tap(find.text('Drums'));
    await _settle(tester);

    await tester.tap(find.text('Not yet'));
    await _settle(tester);
    // Skipped past the remaining questions.
    await tester.tap(find.text('Next'));
    await _settle(tester);
    await tester.tap(find.text('Not yet'));
    await _settle(tester);
    await tester.tap(find.text('Start playing'));
    await _settle(tester);

    expect(spy.plays, isEmpty, reason: 'a chip tapped twice is not an answer');
  });

  testWidgets('somebody who asked for less motion gets none of it',
      (tester) async {
    final spy = _Spy();
    await _open(tester, spy, motion: false);

    await tester.tap(find.text("Let's go"));
    await tester.pump();

    expect(find.byType(InterludeCurtain), findsNothing,
        reason: 'the interlude is the best thing here and it is still not '
            'worth making somebody ill');
    expect(find.text('What do you play?'), findsOneWidget,
        reason: 'without the curtain the swap has to happen anyway');
  });

  testWidgets('the interlude covers the swap and then leaves', (tester) async {
    final spy = _Spy();
    await _open(tester, spy);

    await tester.tap(find.text("Let's go"));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(InterludeCurtain), findsOneWidget);

    // Past the far end of the longest interlude.
    await tester.pump(const Duration(milliseconds: 1400));
    await _settle(tester);
    expect(find.byType(InterludeCurtain), findsNothing,
        reason: 'a flow stuck behind its own curtain is unrecoverable');
    expect(find.text('What do you play?'), findsOneWidget);
  });

  testWidgets('every chip is big enough to hit', (tester) async {
    final spy = _Spy();
    await _open(tester, spy, motion: false);
    await tester.tap(find.text("Let's go"));
    await _settle(tester);

    // Material's minimum is 48 and Apple's is 44. The render harness found
    // this app's own workspace toolbar at 38, and 33 on some devices.
    for (final label in <String>['Singer', 'Bass', 'Producer']) {
      final size = tester.getSize(find.ancestor(
        of: find.text(label),
        matching: find.byType(AnimatedContainer),
      ).first);
      expect(size.height, greaterThanOrEqualTo(48),
          reason: '"$label" is ${size.height} tall');
    }
  });

  group('asked for again', () {
    _Spy withProfile() => _Spy(
          existing: const Musician(
            id: 'preview-user',
            displayName: 'Taylor',
            plays: <String>['drums', 'keys'],
            partsRecorded: <String, int>{},
            songsPlayedOn: 0,
            peopleWorkedWith: 0,
            city: 'Deltona',
            discoverable: true,
            soundsLike: <String>['folk', 'indie'],
          ),
        );

    testWidgets('arrives holding what you already said', (tester) async {
      final spy = withProfile();
      await _open(tester, spy, motion: false, mode: WelcomeMode.tour);

      await tester.tap(find.text('Show me'));
      await _settle(tester);
      // Past the first tour card.
      await tester.tap(find.text('Next'));
      await _settle(tester);

      // The chips are already on, which is what turns this from "tell us
      // about yourself" into "here is what we have".
      final drums = tester.widget<AnimatedContainer>(find.ancestor(
        of: find.text('Drums'),
        matching: find.byType(AnimatedContainer),
      ).first);
      final decoration = drums.decoration! as BoxDecoration;
      expect(decoration.color, isNot(AppColors.raised),
          reason: 'Drums is on the profile and arrived unselected');
    });

    testWidgets('keeps an untouched answer rather than clearing it',
        (tester) async {
      final spy = withProfile();
      await _open(tester, spy, motion: false, mode: WelcomeMode.tour);

      // Straight through, changing nothing at all.
      for (final label in <String>['Show me', 'Next', 'Next', 'Next', 'Next',
        'Next', 'Next']) {
        final finder = find.text(label);
        if (finder.evaluate().isEmpty) continue;
        await tester.tap(finder.last);
        await _settle(tester);
      }
      final save = find.text('Save it');
      if (save.evaluate().isNotEmpty) {
        await tester.tap(save);
        await _settle(tester);
      }

      expect(spy.saved, isTrue);
      expect(find.textContaining('Show me around'), findsNothing,
          reason: 'somebody who just used the tour does not need telling '
              'where the tour is');
      expect(spy.plays, containsAll(<String>['drums', 'keys']),
          reason: 'a tour nobody edited must not empty the profile it was '
              'showing — that would be the worst possible outcome of asking '
              'for help');
      expect(spy.city, 'Deltona');
      expect(spy.soundsLike, containsAll(<String>['folk', 'indie']));
    });

    testWidgets('the first run is not given the tour', (tester) async {
      final spy = _Spy();
      await _open(tester, spy, motion: false);
      await tester.tap(find.text("Let's go"));
      await _settle(tester);

      expect(find.text('A song is one place'), findsNothing,
          reason: 'somebody who has not seen the app has nothing to hang a '
              'tour on');
      expect(find.text('What do you play?'), findsOneWidget);
    });
  });
}
