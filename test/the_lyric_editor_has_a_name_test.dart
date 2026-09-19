import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/lyric_import_flow.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The biggest control in the app says what it is.
///
/// #403 found it while teaching the render harness to see a silent drawing:
/// the words of a song are edited in one enormous multi-line `TextField`, and
/// the only thing it ever said about itself was `hintText` — which
/// `InputDecorator` stops building the moment there is any text in the field.
/// So on every song that already had words, VoiceOver and TalkBack read the
/// whole song out as the node's value and never said what the field was.
///
/// Every Musician, Same Song, 17 September 2026 puts this first: a musician
/// who cannot see the screen has to be able to tell what they are typing
/// into. The name is on the same node as the words, so it is one stop on the
/// way through the screen rather than two.
final Finder _words = find.byKey(const Key('continuous_song_document'));

SemanticsData _spoken(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

Future<MusicBetaController> _openSong(
  WidgetTester tester, {
  int lines = 0,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  final song = await controller.createSong(controller.rooms.first, 'Named song');
  for (var i = 0; i < lines; i += 1) {
    await controller.load();
    await controller.repository.addContribution(
      project: controller.projectById(song.id)!,
      body: 'Line number ${i + 1}',
    );
  }
  await controller.load();

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongWorkspaceScreen(projectId: song.id),
    ),
  ));
  for (var i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  return controller;
}

void main() {
  testWidgets('an empty song announces the editor as Lyrics', (tester) async {
    final semantics = tester.ensureSemantics();

    await _openSong(tester);

    // "Lyrics, tap anywhere and start writing…": the name first, and the hint
    // after it while there is still nothing in the field. The hint is a
    // painted `Text` rather than a semantics hint, so it folds into the name
    // — which is the right thing to hear, and it goes away by itself as soon
    // as there are words.
    final data = _spoken(tester, _words);
    expect(data.label, startsWith('Lyrics'));
    expect(data.flagsCollection.isTextField, isTrue,
        reason: 'the name has to arrive with the role, not instead of it');

    semantics.dispose();
  });

  testWidgets('a song with words in it still announces Lyrics', (tester) async {
    // The case that was broken. The hint is the first thing an
    // `InputDecorator` stops building once there is text, so a song with
    // three lines in it used to be a text field with a value and no name at
    // all.
    final semantics = tester.ensureSemantics();

    await _openSong(tester, lines: 3);

    final data = _spoken(tester, _words);
    expect(data.label, 'Lyrics');
    expect(data.value, contains('Line number 1'),
        reason: 'the words are still the value; the name is added to them');
    expect(data.flagsCollection.isTextField, isTrue);

    semantics.dispose();
  });

  testWidgets('naming it leaves the editing actions where they were',
      (tester) async {
    // A name put on a node above the field would be a second stop for a
    // screen reader and would carry none of the field's actions. This is the
    // check that the name and the field are one thing.
    final semantics = tester.ensureSemantics();

    await _openSong(tester, lines: 2);
    await tester.tap(_words);
    await tester.pump(const Duration(milliseconds: 200));

    final data = _spoken(tester, _words);
    expect(data.label, 'Lyrics');
    expect(data.hasAction(SemanticsAction.setSelection), isTrue);
    expect(data.hasAction(SemanticsAction.setText), isTrue);

    semantics.dispose();
  });

  testWidgets('the imported lyrics are named on the way in', (tester) async {
    // Both dialogs of the import flow are big multi-line fields whose only
    // words were a hint or nothing at all, sitting under a title that names
    // the dialog rather than the field.
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showLyricImportFlow(context),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste lyrics'));
    await tester.pumpAndSettle();

    final pasted = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(pasted, 'First lyric line\nSecond lyric line');
    await tester.pumpAndSettle();
    final pastedData = _spoken(tester, pasted);
    expect(pastedData.label, 'Lyrics',
        reason: 'the pasting field keeps its name once there is text in it');
    // The name and the words on the same node. Without this the test would
    // pass just as well on the shape that must not ship: an empty "Lyrics"
    // field a reader stops on first, with the real, still-unnamed one under
    // it. `tester.getSemantics` walks up to the first node it finds, so only
    // the value proves which node the name landed on.
    expect(pastedData.value, contains('First lyric line'));

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    final reviewed = find.byType(TextField);
    final reviewedData = _spoken(tester, reviewed);
    expect(reviewedData.label, 'Lyrics',
        reason: 'the review field never had any words of its own at all');
    expect(reviewedData.value, contains('First lyric line'));

    semantics.dispose();
  });
}
