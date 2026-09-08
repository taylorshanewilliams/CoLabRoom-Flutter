import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A room with nobody in it, told apart from a broken one.
///
/// Production has four real people and one of them is findable, so the first
/// thing a new invitee sees is an Open Mic with nothing in it. That is not a
/// fault — `discoverable` defaults to false and should — but the screen said
/// "Nobody here yet", which is what an app says when it is broken, and then
/// told them to list themselves without offering anywhere to do it. The one
/// action its own copy named lived on a profile page and behind the filter
/// sheet.
///
/// So the rules worth holding: the empty room says *why* it is empty, it
/// offers the fix when the fix is yours to make, a deliberate tap is never
/// swallowed by the nag guard, and a room containing only you says so instead
/// of returning you to yourself without comment.
class _RealRoom extends InMemoryMusicRepository {
  _RealRoom() : super.from(InMemoryMusicRepository.seeded());

  /// The server's rule, which the preview fake does not have: only people who
  /// turned the switch on come back, and `find_musicians` does not filter you
  /// out of your own search.
  @override
  Future<List<Musician>> findMusicians({
    List<String>? parts,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async {
    final me = await loadMusician(currentUserId);
    return me != null && me.discoverable == true
        ? <Musician>[me]
        : const <Musician>[];
  }
}

/// Listed, and still nothing back — a narrow search in a young room.
class _NobodyMatches extends InMemoryMusicRepository {
  _NobodyMatches() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<Musician>> findMusicians({
    List<String>? parts,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async =>
      const <Musician>[];
}

Future<void> _open(
  WidgetTester tester,
  InMemoryMusicRepository repository,
) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: OpenMicScreen(repository: repository)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('an empty room says nobody has listed themselves', (tester) async {
    await _open(tester, _RealRoom());

    expect(find.text('Nobody has listed themselves yet'), findsOneWidget,
        reason: '"Nobody here yet" is what a broken app says. Nobody is here '
            'because being findable is off until somebody turns it on');
    expect(find.byKey(const Key('open_mic_list_me')), findsOneWidget,
        reason: 'the copy has named this action since it was written and the '
            'screen never offered it');
  });

  testWidgets('listing yourself fills the room, and the room says so',
      (tester) async {
    final repository = _RealRoom();
    await _open(tester, repository);

    await tester.tap(find.byKey(const Key('open_mic_list_me')));
    await _settle(tester);
    expect(find.text('Can they find you too?'), findsOneWidget);

    await tester.tap(find.text('Let them find me'));
    await _settle(tester);

    expect((await repository.loadMusician(repository.currentUserId))!.discoverable,
        isTrue);
    // The room answered: your own card, marked, and a line saying why the
    // only result is you rather than leaving it to look like a bug.
    expect(find.byKey(const Key('open_mic_you_chip')), findsOneWidget);
    expect(find.text('You are the only one listed so far'), findsOneWidget);
    expect(find.text('Nobody has listed themselves yet'), findsNothing);
  });

  testWidgets('a decline does not disarm the button that asks', (tester) async {
    await _open(tester, _RealRoom());

    await tester.tap(find.byKey(const Key('open_mic_list_me')));
    await _settle(tester);
    await tester.tap(find.text('Not now'));
    await _settle(tester);

    // The month-long shelf life exists to stop the *unprompted* ask becoming
    // a nag. Applied to a button somebody pressed on purpose it is a button
    // that does nothing, which is worse than never asking.
    await tester.tap(find.byKey(const Key('open_mic_list_me')));
    await _settle(tester);
    expect(find.text('Can they find you too?'), findsOneWidget);
  });

  testWidgets('the empty room fits a small phone at large text',
      (tester) async {
    // The state that grew: a headline, a paragraph and two buttons where
    // there used to be a headline, a paragraph and one. Overflow stripes are
    // a debug-only assert, so a release build would clip this silently and
    // tell nobody — the same shape as the Home overflow the render harness
    // found on every phone.
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: OpenMicScreen(repository: _RealRoom()))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('open_mic_list_me')), findsOneWidget);
  });

  testWidgets('somebody already listed is not told they are invisible',
      (tester) async {
    final repository = _NobodyMatches();
    await repository.setOpenMicPresence(discoverable: true);
    await _open(tester, repository);

    expect(find.textContaining('You are listed'), findsOneWidget);
    expect(find.byKey(const Key('open_mic_list_me')), findsNothing,
        reason: 'a button that reruns a switch already on is a dead button');
    expect(find.byKey(const Key('open_mic_ask_somebody_not_here')),
        findsOneWidget,
        reason: 'the room cannot help, so the useful move is outside it');
  });
}
