import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:colabroom/features/layers/moment_notes.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/widgets/problem_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The other boxes somebody writes more than a line into.
///
/// The lyric editor was found nameless by the render harness, and the same
/// defect was sitting in every other multi-line field in the app: the only
/// words each one had were `hintText`, and `InputDecorator` stops building
/// the hint the moment there is any text. So a musician who had typed two
/// sentences heard their own two sentences read back with nothing saying
/// what they had typed them into — and the field that opens already filled,
/// the one on their own page, never said what it was at all.
///
/// Every Musician, Same Song, 17 September 2026: somebody who cannot see the
/// screen has to be able to tell what they are writing into. #403 reported
/// the editor; these are the rest of them.
SemanticsData _spoken(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

Future<void> _pump(WidgetTester tester, Widget home, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(390, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: CoLabRoomTheme.dark(), home: home));
}

/// The field inside whatever is on top, once there is writing in it.
Future<SemanticsData> _afterTyping(
  WidgetTester tester,
  Finder field,
  String written,
) async {
  await tester.enterText(field, written);
  await tester.pumpAndSettle();
  return _spoken(tester, field);
}

void main() {
  testWidgets('a problem report says it is the report', (tester) async {
    final semantics = tester.ensureSemantics();

    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showProblemReport(context),
            child: const Text('Report'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    final box = find.byType(TextField);
    final data = await _afterTyping(
      tester,
      box,
      'The recording stopped halfway through the second verse.',
    );
    expect(data.label, 'Your report');
    expect(data.value, contains('second verse'),
        reason: 'the words stay the value; the name is added to them, so it '
            'is one stop on the way through the sheet rather than two');
    expect(data.flagsCollection.isTextField, isTrue);
    expect(data.hasAction(SemanticsAction.setText), isTrue,
        reason: 'the name has to be on the node that does the editing');

    semantics.dispose();
  });

  testWidgets('a note pinned at a moment says it is the note', (tester) async {
    final semantics = tester.ensureSemantics();

    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showMomentNoteSheet(
              context,
              atMs: 0,
              on: const <NoteTarget>[NoteTarget(id: 'layer-1', label: 'Sent')],
            ),
            child: const Text('Pin'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    final data = await _afterTyping(
      tester,
      find.byKey(const Key('moment_note_body')),
      'breathe before mio',
    );
    expect(data.label, 'Note');
    expect(data.value, contains('breathe before mio'));
    expect(data.flagsCollection.isTextField, isTrue);

    semantics.dispose();
  });

  testWidgets('the feedback box on the account screen says what it is',
      (tester) async {
    final semantics = tester.ensureSemantics();

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: const AccountScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    final data = await _afterTyping(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'The join link opened a blank page.',
    );
    expect(data.label, 'Your report');
    expect(data.value, contains('blank page'));

    semantics.dispose();
  });

  testWidgets('what somebody wrote about themselves says what it is',
      (tester) async {
    // The worst of the four, because this one opens already filled for
    // anybody editing what they wrote last time — so the hint is never
    // painted and there were no words about it to hear at all.
    final semantics = tester.ensureSemantics();

    final repository = InMemoryMusicRepository.seeded();
    await repository.setBio('Sing mostly.');

    await _pump(
      tester,
      MusicianProfileScreen(
        profileId: 'preview-user',
        repository: repository,
      ),
      size: const Size(390, 1600),
    );
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    final edit = find.byTooltip('Edit what you said');
    expect(edit, findsOneWidget,
        reason: 'somebody who has already written something is the case '
            'where the field opens with no hint to hear');
    await tester.tap(edit);
    await tester.pumpAndSettle();

    final data = await _afterTyping(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Sing mostly, write when nobody is listening.',
    );
    expect(data.label, 'About you');
    expect(data.value, contains('write when nobody is listening'));

    semantics.dispose();
  });
}
