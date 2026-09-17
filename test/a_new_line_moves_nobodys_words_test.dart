import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writing a new line into a band's song leaves every other line with the
/// person who wrote it.
///
/// Audit, 17 September 2026: the save matched lines to contributions by
/// index. A new first line in a song Taylor and Jess wrote together put
/// Taylor's words in Jess's colour under Jess's name, Jess's words in a new
/// row credited to whoever typed, and Jess's voice note beside Taylor's
/// line. Deleting a line in the middle deleted the last one.
///
/// These drive the real song screen against the in-memory repository, so
/// they cover the whole path: the text, the diff, the positions, the writes
/// and what the editor remembers afterwards.
const _songId = 'song-1';
const _taylorsLine = 'Streetlights blur like a warning in the rain';
const _jesssLine = 'Your frequency keeps calling out my name';

final _words = find.byKey(const Key('continuous_song_document'));

Future<MusicBetaController> _open(WidgetTester tester, {Size size = const Size(390, 844)}) async {
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
      home: const SongWorkspaceScreen(projectId: _songId),
    ),
  ));
  await _settle(tester);
  return controller;
}

/// Past the editor's 700 ms debounce, and long enough for the save and the
/// reload behind it to land.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

List<Contribution> _lines(MusicBetaController controller) =>
    controller.projectById(_songId)!.contributions;

void main() {
  testWidgets('a new first line leaves every line with its writer and colour', (tester) async {
    final controller = await _open(tester);
    final before = _lines(controller);
    expect(before.map((line) => line.authorName), <String>['Taylor', 'Jess'],
        reason: 'the fixture is a song two people wrote');

    await tester.enterText(_words, 'A brand new first line\n$_taylorsLine\n$_jesssLine');
    await _settle(tester);

    final after = _lines(controller);
    expect(after.map((line) => line.body), <String>['A brand new first line', _taylorsLine, _jesssLine]);
    expect(before.map((line) => line.id), isNot(contains(after.first.id)),
        reason: 'the new words are a new contribution');
    for (var i = 0; i < before.length; i += 1) {
      final original = before[i];
      final now = after[i + 1];
      expect(now.id, original.id, reason: '"${original.body}" is still the same line');
      expect(now.body, original.body);
      expect(now.authorId, original.authorId, reason: '"${original.body}" is still ${original.authorName}\'s');
      expect(now.authorName, original.authorName);
      expect(now.colorValue, original.colorValue, reason: 'and still in their colour');
      expect(now.revision, original.revision, reason: 'nothing was written over it');
    }
  });

  testWidgets('a voice note stays beside the words it was recorded for', (tester) async {
    final controller = await _open(tester);
    final jess = _lines(controller)[1];
    final note = await controller.repository.attachVoiceNote(
      project: controller.projectById(_songId)!,
      contribution: jess,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      durationMs: 1200,
    );
    await controller.load();
    await _settle(tester);

    await tester.enterText(_words, 'Somebody else sang this first\n$_taylorsLine\n$_jesssLine');
    await _settle(tester);

    final after = _lines(controller);
    expect(after[2].body, _jesssLine);
    expect(after[2].voiceNote?.id, note.id);
    expect(after.where((line) => line.voiceNote != null), hasLength(1));
  });

  testWidgets('deleting a line in the middle deletes that line, not the last one', (tester) async {
    final controller = await _open(tester);
    await controller.repository.addContribution(
      project: controller.projectById(_songId)!,
      body: 'A third line at the end',
    );
    await controller.load();
    await _settle(tester);
    final before = _lines(controller);
    expect(tester.widget<TextField>(_words).controller!.text, '$_taylorsLine\n$_jesssLine\nA third line at the end');

    await tester.enterText(_words, '$_taylorsLine\nA third line at the end');
    await _settle(tester);

    final after = _lines(controller);
    expect(after.map((line) => line.id), <String>[before[0].id, before[2].id]);
    expect(after.map((line) => line.body), <String>[_taylorsLine, 'A third line at the end']);
  });

  testWidgets('moving a line keeps it the same line', (tester) async {
    final controller = await _open(tester);
    final before = _lines(controller);

    await tester.enterText(_words, '$_jesssLine\n$_taylorsLine');
    await _settle(tester);

    final after = _lines(controller);
    expect(after.map((line) => line.body), <String>[_jesssLine, _taylorsLine]);
    expect(after.map((line) => line.id), <String>[before[1].id, before[0].id]);
    expect(after.map((line) => line.authorName), <String>['Jess', 'Taylor']);
  });

  testWidgets('the dots beside the words follow the lines before the save lands', (tester) async {
    // The rail took contributions[index] too. Typing a new first line put
    // Taylor's colour and label on the new words and Jess's on Taylor's,
    // until the save caught up — and a voice note recorded in that window
    // went to the wrong line.
    final semantics = tester.ensureSemantics();
    final controller = await _open(tester);

    await tester.enterText(_words, 'Not saved yet\n$_taylorsLine\n$_jesssLine');
    await tester.pump();

    expect(find.bySemanticsLabel(RegExp(r'^Line 1, empty line')), findsOneWidget,
        reason: 'unsaved words have no contribution behind them yet');
    expect(find.bySemanticsLabel(RegExp(r'^Line 2, Streetlights')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Line 3, Your frequency')), findsOneWidget);

    await _settle(tester);
    expect(find.bySemanticsLabel(RegExp(r'^Line 1, Not saved yet')), findsOneWidget);
    expect(_lines(controller), hasLength(3));
    semantics.dispose();
  });

  testWidgets('a line somebody else adds while you write is never deleted by your saves', (tester) async {
    final controller = await _open(tester);

    // You start writing. Before your save, a bandmate's line arrives. The
    // editor will not put it on your screen while you are typing.
    await tester.enterText(_words, 'My new opening\n$_taylorsLine\n$_jesssLine');
    await controller.repository.addContribution(
      project: controller.projectById(_songId)!,
      body: 'Their line, from their phone',
    );
    await controller.load();
    await _settle(tester);

    expect(_lines(controller).map((line) => line.body), <String>[
      'My new opening',
      _taylorsLine,
      _jesssLine,
      'Their line, from their phone',
    ]);
    expect(tester.widget<TextField>(_words).controller!.text, isNot(contains('Their line')),
        reason: 'still not on your screen, so still not yours to delete');

    // And your next save, from the same screen, still leaves it alone.
    await tester.enterText(_words, 'My new opening\n$_taylorsLine\n$_jesssLine, still');
    await _settle(tester);

    expect(_lines(controller).map((line) => line.body), <String>[
      'My new opening',
      _taylorsLine,
      '$_jesssLine, still',
      'Their line, from their phone',
    ]);
  });

  testWidgets('a bandmate rewriting a line you did not touch keeps their rewrite', (tester) async {
    final controller = await _open(tester);

    await tester.enterText(_words, 'Written above\n$_taylorsLine\n$_jesssLine');
    await controller.repository.updateContribution(
      contribution: _lines(controller)[1],
      body: 'Jess changed her mind about this line',
    );
    await controller.load();
    await _settle(tester);

    expect(_lines(controller).map((line) => line.body), <String>[
      'Written above',
      _taylorsLine,
      'Jess changed her mind about this line',
    ]);
  });

  testWidgets('each line\'s voice-note target is at least 24 by 24', (tester) async {
    // Audit H4: 24x13 in landscape, where a line is 13 px tall.
    final semantics = tester.ensureSemantics();
    await _open(tester, size: const Size(844, 390));

    for (final label in <String>['Line 1, Streetlights', 'Line 2, Your frequency']) {
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^$label')));
      expect(node.rect.width, greaterThanOrEqualTo(24), reason: label);
      expect(node.rect.height, greaterThanOrEqualTo(24), reason: label);
    }
    semantics.dispose();
  });
}
