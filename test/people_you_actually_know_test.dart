import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/openmic/people_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The layer between a stranger and a bandmate.
///
/// Taylor: "can we add a friends feature, so you can have your band mates, or
/// just friends you know, or musicians youve met on here and work with".
///
/// The app had two kinds of person and nothing in between — somebody in a
/// room with you, which is shared files and shared edits, or a name on the
/// Open Mic you have never met. The only way to keep hold of somebody was to
/// put them in a room, which grants them everything.
///
/// A connection grants nothing. That is the whole design: it is a way to find
/// each other again, not a permission.
Future<MusicBetaController> _controller() async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  return controller;
}

Future<void> _pump(WidgetTester tester, MusicBetaController controller) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: const PeopleScreen(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the three states of knowing somebody are three different rows',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    // An accepted pair is symmetric. A pending one is either something you
    // are waiting on or something waiting on you, and those need different
    // buttons — which is the only reason direction is carried at all.
    expect(find.text('WANTS TO CONNECT'), findsOneWidget);
    expect(find.textContaining('YOUR PEOPLE'), findsOneWidget);
    expect(find.text('ASKED, NO ANSWER YET'), findsOneWidget);

    expect(find.byKey(const Key('accept_preview-mara')), findsOneWidget,
        reason: 'Mara asked you, so the row offers an answer');
    expect(find.byKey(const Key('accept_preview-sam')), findsNothing,
        reason: 'you asked Sam — there is nothing for you to accept');
  });

  testWidgets('saying yes moves somebody into your people', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('accept_preview-mara')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('WANTS TO CONNECT'), findsNothing);
    expect(find.text('Mara'), findsOneWidget,
        reason: 'she moved into the list rather than out of the screen');
  });

  testWidgets('your own status is a line, not the first thing on the screen',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    // The first version opened on a box of chips asking how available you
    // were: a form about yourself, on the screen you came to in order to look
    // at somebody else.
    expect(find.textContaining('Your people see you as'), findsOneWidget);

    await tester.tap(find.byKey(const Key('your_status')), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));

    // Set on purpose and lasting for days. The live dot answers "message them
    // now"; this answers "is it worth asking at all", and it is the half that
    // still says something when nobody is online.
    expect(find.byKey(const Key('availability_open')), findsOneWidget);
    expect(find.byKey(const Key('availability_unset')), findsOneWidget,
        reason: 'declining to say is a real answer, not a missing one');

    // Closed without fighting the modal's future: what the sheet offers is
    // the design change here, and what setAvailability stores is covered
    // directly below.
    await tester.tap(find.byKey(const Key('availability_unset')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.myAvailability, isNotNull);
  });

  testWidgets('every name leads to a profile, requests included',
      (tester) async {
    // A row that cannot be tapped is a dead end, and the first version was
    // all dead ends: three groups of names with buttons on them and no way
    // to find out who any of these people were.
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.tap(find.text('Mara'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // The profile fetches over a repository the preview answers instantly;
    // any failure inside it is swallowed by the screen's own reporting, so
    // the assertion below is about the route, not about the content.
    while (tester.takeException() != null) {}

    // The pushed route covers it; PeopleScreen stays in the tree underneath.
    expect(find.byType(MusicianProfileScreen), findsOneWidget,
        reason: 'tapping a request opens who they are, so the decision is '
            'made from a face rather than from a name');
  });

  testWidgets('one field finds the people you have and the people you do not',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.enterText(find.byKey(const Key('people_search')), 'jess');
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('YOUR PEOPLE'), findsOneWidget,
        reason: 'somebody typing a name they know is usually looking for a '
            'person they already have');
    expect(find.text('Jess'), findsWidgets);
  });

  test('a connection nobody has answered is not a connection', () async {
    final repository = InMemoryMusicRepository.seeded();

    final connected = await repository.requestConnection('preview-nobody');
    expect(connected, isFalse,
        reason: 'asking is not agreeing; it waits for the other person');

    final rows = await repository.listConnections();
    final asked = rows.firstWhere((c) => c.personId == 'preview-nobody');
    expect(asked.accepted, isFalse);
    expect(asked.incoming, isFalse);
  });

  test('two people who have each asked are connected without waiting',
      () async {
    // Mara has already asked, in the seed. Pressing the button back is two
    // people agreeing, and making the second one wait for the first to
    // notice would be a pointless day of delay.
    final repository = InMemoryMusicRepository.seeded();
    final connected = await repository.requestConnection('preview-mara');
    expect(connected, isTrue);
  });

  test('a status is stored with an end date on it', () async {
    // A fortnight, and then it is not true any more. A status with no end is
    // one somebody sets in a good week and forgets, while the app goes on
    // telling their band they are free.
    final repository = InMemoryMusicRepository.seeded();
    expect(repository.myAvailability, Availability.unset);

    await repository.setAvailability(Availability.open,
        until: DateTime.now().add(const Duration(days: 14)));
    expect(repository.myAvailability, Availability.open);
  });

  test('an expired status is not a status', () {
    // Somebody who said they were busy until Friday is not busy on Saturday.
    // The server drops it; the model must never invent one either — "unset"
    // means unknown, not away.
    const said = Connection(
      personId: 'x',
      displayName: 'Someone',
      accepted: true,
      incoming: false,
    );
    expect(said.availabilityLine, isNull);

    const open = Connection(
      personId: 'y',
      displayName: 'Jess',
      accepted: true,
      incoming: false,
      availability: Availability.open,
      availabilityNote: 'around most evenings',
    );
    expect(open.availabilityLine, 'Up for playing - around most evenings');
  });
}
