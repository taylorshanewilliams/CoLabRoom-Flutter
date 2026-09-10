import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/tell_about_song_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Telling somebody, on purpose.
///
/// Taylor: "you could notify indivudual users direcctly to there phone that
/// you uploaded something, changed something, etc...or if you want to notify
/// the whole room, you could do that" — and then: "even a choice of selection
/// which users, or which friends to notify, you could select mulitple maybe".
///
/// Everything the app notified anybody about until now was automatic: a
/// trigger noticing an invite, an ask, a finished analysis. That is not the
/// same as a person deciding somebody should hear this. A band works in
/// bursts — you put a take up on Tuesday and it matters that the bass player
/// knows on Tuesday.
Future<InMemoryMusicRepository> _open(WidgetTester tester) async {
  final repository = InMemoryMusicRepository.seeded();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  final project = controller.rooms.first.projects.first;

  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showTellAboutSong(context, project: project),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  // The sheet animates in and then loads its list. One pump lands mid-way
  // through the route transition, on a spinner.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return repository;
}

void main() {
  testWidgets('the room is the default, because it usually is the answer',
      (tester) async {
    await _open(tester);

    expect(find.byKey(const Key('tell_room')), findsOneWidget);
    expect(find.text('Tell the room'), findsOneWidget,
        reason: 'somebody who has just put a take up usually means the band, '
            'and making them pick a name to say so is a tax on the common '
            'case');
  });

  testWidgets('picking people replaces the room, and unpicking restores it',
      (tester) async {
    await _open(tester);

    // Jess is in the seeded room.
    await tester.tap(find.byKey(const Key('tell_preview-jess')));
    await tester.pump();
    expect(find.text('Tell them'), findsOneWidget);

    // Unticking the last one puts the room back, because an empty list would
    // send to nobody and disable the button with no explanation.
    await tester.tap(find.byKey(const Key('tell_preview-jess')));
    await tester.pump();
    expect(find.text('Tell the room'), findsOneWidget);
  });

  testWidgets('the room sends no list, so it keeps meaning the room',
      (tester) async {
    final repository = await _open(tester);

    await tester.tap(find.byKey(const Key('tell_send')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(repository.toldAbout, hasLength(1));
    expect(repository.toldAbout.single.personIds, isNull,
        reason: 'sending the room as a list of names would freeze the band as '
            'it was the moment somebody pressed the button');
  });

  testWidgets('a note rides along when there is one', (tester) async {
    final repository = await _open(tester);

    await tester.enterText(
        find.byKey(const Key('tell_note')), 'New take on the second verse');
    await tester.pump();
    await tester.tap(find.byKey(const Key('tell_send')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(repository.toldAbout.single.note, 'New take on the second verse');
  });
}
