import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/the_app_noticed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Does the profile stop reading like a survey?
///
/// The sheet asks four questions of somebody who came here to play music,
/// before they get anything back — and most of what it asks is already known,
/// because every take they have recorded carries a part.
///
/// The two things that matter about the card that replaces it: it offers
/// what the app can actually count, and it never appears on somebody else's
/// page. What the app has worked out about a person is not a thing to show
/// anybody, including them, on a page a stranger can open.
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  const bass = Noticed(
    kind: NoticedKind.plays,
    subject: 'bass',
    detail: 'You have recorded bass on 4 songs.',
    amount: 4,
  );

  testWidgets('it says what it saw, and names the button after it',
      (tester) async {
    await tester.pumpWidget(wrap(TheAppNoticed(
      noticed: const <Noticed>[bass],
      onClaim: (_) {},
      onOpenSettings: () {},
    )));

    expect(find.text('You have recorded bass on 4 songs.'), findsOneWidget);
    // "Add" beside a sentence about bass is a button that could be doing
    // anything.
    expect(find.text('Add bass'), findsOneWidget);
    expect(find.text('One thing we noticed'), findsOneWidget);
  });

  testWidgets('accepting hands back the part, not an index', (tester) async {
    String? claimed;
    await tester.pumpWidget(wrap(TheAppNoticed(
      noticed: const <Noticed>[bass],
      onClaim: (part) => claimed = part,
      onOpenSettings: () {},
    )));

    await tester.tap(find.byKey(const Key('claim_bass')));
    await tester.pump();
    expect(claimed, 'bass');
  });

  testWidgets('the two that are decisions open the sheet instead',
      (tester) async {
    var opened = 0;
    await tester.pumpWidget(wrap(TheAppNoticed(
      noticed: const <Noticed>[
        Noticed(
          kind: NoticedKind.discoverable,
          subject: '',
          detail: 'You have 3 songs on the Open Mic, but nobody can find you.',
          amount: 3,
        ),
        Noticed(
          kind: NoticedKind.soundsLike,
          subject: '',
          detail: 'You have shared music and never said what it sounds like.',
          amount: 3,
        ),
      ],
      onClaim: (_) {},
      onOpenSettings: () => opened += 1,
    )));

    // Being findable and describing your music are choices, not facts the
    // app is entitled to make on somebody's behalf.
    await tester.tap(find.text('Let people find me'));
    await tester.pump();
    await tester.tap(find.text('Say what I sound like'));
    await tester.pump();
    expect(opened, 2);
  });

  testWidgets('nothing noticed draws nothing at all', (tester) async {
    await tester.pumpWidget(wrap(TheAppNoticed(
      noticed: const <Noticed>[],
      onClaim: (_) {},
      onOpenSettings: () {},
    )));
    // Not an empty card saying there is nothing to say. Somebody with a
    // complete profile should see a profile.
    expect(find.textContaining('noticed'), findsNothing);
  });

  testWidgets('a claim in flight says so and cannot be pressed twice',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(TheAppNoticed(
      noticed: const <Noticed>[bass],
      busy: 'bass',
      onClaim: (_) => taps += 1,
      onOpenSettings: () {},
    )));

    expect(find.text('Adding…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('claim_bass')), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0, reason: 'a part could be claimed twice while in flight');
  });
}
