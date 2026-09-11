import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The strip runs left to right, and costs one card of height either way.
///
/// Taylor: "the notifications bar is still just one single line... its just
/// one thing at a time. and not formatted in a pleasant way... what if
/// notifications worked more left to right, seamless and fluid, you could
/// scroll through them that way, one at a time, without leaving the page...
/// clear them all, or clear one at a time, or open one if its exciting."
///
/// Both earlier versions were stacks, and a stack above somebody's songs has
/// one unavoidable property: every extra thing pushes the music further down.
/// So the stack rationed itself — one lead, three rows, a "4 more" — and the
/// rationing is what made it feel like one thing at a time.
List<WaitingItem> _five({
  List<String>? cleared,
  VoidCallback? onNews,
}) {
  final now = DateTime.now();
  void clear(String id) => cleared?.add(id);
  return <WaitingItem>[
    // Deliberately out of order, because the widget is what decides which
    // card you land on.
    WaitingItem(
      id: 's1',
      kind: WaitingKind.sheet,
      line: 'Hold The Line For Me',
      actionLabel: 'Make it',
      onAction: () {},
      onDismiss: () => clear('s1'),
    ),
    WaitingItem(
      id: 'r1',
      kind: WaitingKind.request,
      who: 'Jess Turner',
      at: now.subtract(const Duration(days: 1)),
      line: 'Jess Turner',
      actionLabel: 'See who',
      onAction: () {},
    ),
    WaitingItem(
      id: 'msg',
      kind: WaitingKind.news,
      who: 'Mara',
      about: 'The Long Way Around',
      at: now.subtract(const Duration(minutes: 40)),
      line: 'Mara left a note',
      actionLabel: 'Read it',
      onAction: () {},
      onDismiss: () => clear('msg'),
    ),
    WaitingItem(
      id: 'take',
      kind: WaitingKind.news,
      who: 'Dylan',
      about: 'Midnight Signal',
      at: now.subtract(const Duration(hours: 9)),
      line: 'Dylan added bass',
      actionLabel: 'Hear it',
      audioPath: 'room/project/takes/abc.m4a',
      onAction: onNews ?? () {},
      onDismiss: () => clear('take'),
    ),
    WaitingItem(
      id: 'u1',
      kind: WaitingKind.unfinished,
      line: 'Buried My Fears',
      actionLabel: 'Open',
      onAction: () {},
      onDismiss: () => clear('u1'),
    ),
  ];
}

Future<void> _show(
  WidgetTester tester,
  List<WaitingItem> items, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[WaitingOnYou(items: items)],
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('nothing waiting draws nothing at all', (tester) async {
    await _show(tester, const <WaitingItem>[]);
    expect(find.byKey(const Key('waiting_on_you')), findsNothing);
  });

  testWidgets('five things cost the same height as two', (tester) async {
    await _show(tester, _five().take(2).toList(growable: false));
    final two = tester.getSize(find.byKey(const Key('waiting_on_you'))).height;

    await _show(tester, _five());
    final five = tester.getSize(find.byKey(const Key('waiting_on_you'))).height;

    // The whole reason for turning it sideways. The version before this grew
    // by a row per thing, so four things waiting pushed Your music off the
    // bottom of a phone — which is what forced it to hide most of them behind
    // a "4 more", which is what made it feel like one thing at a time.
    expect(five, two, reason: 'a row of cards must not grow with what is in it');
    expect(
      five,
      lessThan(230),
      reason: 'one card and a row of dots, and no more than that',
    );
  });

  testWidgets('the card you land on is the one you can hear', (tester) async {
    await _show(tester, _five());

    // Sorted by the widget, not by the caller: something you can play beats
    // something you can read, even when the note is more recent. The list
    // handed in has the song sheet chore first.
    expect(find.text('Dylan added bass'), findsOneWidget);
    expect(find.byKey(const Key('waiting_play_take')), findsOneWidget);
  });

  testWidgets('a chore never lands first', (tester) async {
    await _show(tester, _five());
    // "Make the song sheet" is equally true tomorrow. An app that opens on it
    // feels like arriving at work.
    expect(find.text('Hold The Line For Me'), findsNothing);
  });

  testWidgets('one at a time, sideways', (tester) async {
    await _show(tester, _five());
    expect(find.byKey(const Key('waiting_pages')), findsOneWidget);

    final pages = tester.widget<PageView>(
      find.byKey(const Key('waiting_pages')),
    );
    expect(pages.scrollDirection, Axis.horizontal);
    // Never the full width: the card peeking past the right edge is the only
    // thing telling anybody the row goes sideways at all.
    expect(pages.controller!.viewportFraction, lessThan(1.0));
  });

  testWidgets('one card at a time can be cleared', (tester) async {
    final cleared = <String>[];
    await _show(tester, _five(cleared: cleared));

    await tester.tap(find.byKey(const Key('waiting_close_take')));
    await tester.pump();

    expect(cleared, <String>['take']);
  });

  testWidgets('or the lot of them, in one tap', (tester) async {
    final cleared = <String>[];
    await _show(tester, _five(cleared: cleared));

    await tester.tap(find.byKey(const Key('waiting_clear_all')));
    await tester.pump();

    // Everything that can be cleared for good is, and the one thing that
    // cannot — somebody waiting on an answer — is hidden for the session
    // instead. Leaving it on screen would make "Clear all" read as broken.
    expect(cleared..sort(), <String>['msg', 's1', 'take', 'u1']);
    expect(find.text('Jess Turner'), findsNothing);
  });

  testWidgets('a person waiting on an answer is never cleared for good',
      (tester) async {
    final cleared = <String>[];
    final items = _five(cleared: cleared);
    final request = items.firstWhere((i) => i.id == 'r1');

    // The × on a connect request hides it until next time rather than
    // declining it. An × that permanently forgot somebody's request is how
    // you never reply to anybody.
    expect(request.onDismiss, isNull);

    await _show(tester, <WaitingItem>[request]);
    await tester.tap(find.byKey(const Key('waiting_close_r1')));
    await tester.pump();

    expect(find.text('Jess Turner'), findsNothing);
    expect(cleared, isEmpty);
  });

  testWidgets('one thing on its own is a card, not a line', (tester) async {
    // The state Taylor was actually looking at.
    await _show(tester, <WaitingItem>[_five().first]);

    expect(find.byKey(const Key('waiting_pages')), findsNothing);
    expect(find.byKey(const Key('waiting_clear_all')), findsNothing);
    expect(find.byKey(const Key('waiting_close_s1')), findsOneWidget);
    expect(find.byKey(const Key('waiting_do_s1')), findsOneWidget);
  });

  testWidgets('a card never runs the width of a desk', (tester) async {
    await _show(tester, _five(), size: const Size(1280, 900));

    // One card 970 pixels across holding a single sentence is the "phone
    // pulled at the corners" this repo has already fixed twice. Past a point
    // a wider screen should show more cards, not a wider card.
    final card = tester.getSize(find.byKey(const Key('waiting_close_take')));
    expect(card.width, greaterThan(0));
    final pages = tester.widget<PageView>(
      find.byKey(const Key('waiting_pages')),
    );
    expect(
      pages.controller!.viewportFraction * 1280,
      lessThan(WaitingOnYou.cardMax + WaitingOnYou.gutter + 1),
    );
  });

  testWidgets('at big text nothing overflows', (tester) async {
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[WaitingOnYou(items: _five())],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
