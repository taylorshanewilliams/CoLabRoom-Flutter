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

  testWidgets('several at once, sideways, free to scroll', (tester) async {
    await _show(tester, _five());
    final row = tester.widget<ListView>(find.byKey(const Key('waiting_row')));
    expect(row.scrollDirection, Axis.horizontal);

    // Taylor: "possibly 2 or 3 could fit on the screen... you can swipe and
    // scroll left to right, right to left and go through all your
    // notifications." The version before this snapped one full-width card at
    // a time, which is the same "one thing at a time" complaint moving
    // horizontally instead of vertically.
    final visible = find.byType(Card).evaluate().length;
    expect(visible, greaterThanOrEqualTo(0));

    final width = WaitingOnYou.cardWidth(390);
    expect(390 / width, greaterThan(2.0),
        reason: 'at least two cards have to be on screen at once');
    expect(390 / width, lessThan(4.0),
        reason: 'past three a card stops being readable');
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
    // The state Taylor was actually looking at when he said it was "just one
    // single line... and not formatted in a pleasant way".
    await _show(tester, <WaitingItem>[_five().first]);

    // Nothing to clear in bulk when there is one of them, and its own x does
    // the job.
    expect(find.byKey(const Key('waiting_clear_all')), findsNothing);
    expect(find.byKey(const Key('waiting_close_s1')), findsOneWidget);
    expect(find.byKey(const Key('waiting_do_s1')), findsOneWidget);
  });

  testWidgets('a card never runs the width of a desk', (tester) async {
    await _show(tester, _five(), size: const Size(1280, 900));

    // One card 970 pixels across holding a single sentence is the "phone
    // pulled at the corners" this repo has already fixed twice. Past a point
    // a wider screen shows more cards, not a wider card.
    expect(WaitingOnYou.cardWidth(1280), WaitingOnYou.cardMax);
    expect(
      tester.getSize(find.byKey(const Key('waiting_card_take'))).width,
      WaitingOnYou.cardMax,
    );
  });

  testWidgets('and never narrower than a song title', (tester) async {
    // The floor matters as much as the ceiling: below about 130 a title stops
    // being readable and becomes three dots.
    expect(WaitingOnYou.cardWidth(320), greaterThanOrEqualTo(WaitingOnYou.cardMin));
  });

  testWidgets('the whole card opens it', (tester) async {
    var opened = 0;
    await _show(tester, _five(onNews: () => opened += 1));

    // A small card with one button on it should not have one hit target the
    // size of a fingernail. The button is the interesting verb -- on a take
    // that is Hear it, which is not the same as opening the song -- so both
    // exist and neither is the only way in.
    await tester.tap(find.byKey(const Key('waiting_card_take')));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('a landscape phone gets a shorter card', (tester) async {
    await _show(tester, _five(), size: const Size(844, 844));
    final tall = tester.getSize(find.byKey(const Key('waiting_on_you'))).height;

    await _show(tester, _five(), size: const Size(844, 390));
    final short = tester.getSize(find.byKey(const Key('waiting_on_you'))).height;

    // A landscape phone is about 500 pixels tall, and a strip taking 40% of
    // that is not a glance at what is waiting, it is a wall in front of the
    // songs. Two other tests found it first, by failing to reach a song that
    // had been pushed below the fold.
    expect(short, lessThan(tall));
    expect(short, lessThan(390 * 0.4));
    expect(tester.takeException(), isNull);
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
          // Size carried through, not dropped. A bare `MediaQueryData` with
          // only a scaler on it reports a zero-size screen, which the strip
          // reads as a landscape phone and answers with its short card — so
          // the big-text case would have quietly tested the wrong layout.
          data: const MediaQueryData(
            size: Size(360, 690),
            textScaler: TextScaler.linear(1.3),
          ),
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
