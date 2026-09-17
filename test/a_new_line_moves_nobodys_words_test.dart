import 'dart:async';
import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/data/music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';
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

/// A connection slow enough that the writer is still typing when a save
/// lands: every new line waits at [gate] until the test opens it.
class _SlowNewLines extends InMemoryMusicRepository {
  _SlowNewLines() : super.from(InMemoryMusicRepository.seeded());

  final Completer<void> gate = Completer<void>();

  @override
  Future<Contribution> addContribution({
    required SongProject project,
    required String body,
    int colorValue = 0xFFFF8A4C,
    double? position,
  }) async {
    await gate.future;
    return super.addContribution(
      project: project,
      body: body,
      colorValue: colorValue,
      position: position,
    );
  }
}

Future<MusicBetaController> _open(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  MusicRepository? repository,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = MusicBetaController(repository ?? InMemoryMusicRepository.seeded());
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
    await controller.repository.attachVoiceNote(
      project: controller.projectById(_songId)!,
      contribution: _lines(controller)[1],
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      durationMs: 1200,
    );
    await controller.load();
    await _settle(tester);

    await tester.enterText(_words, 'Not saved yet\n$_taylorsLine\n$_jesssLine');
    await tester.pump();

    // The words come from the screen, so what each label says after them is
    // what shows which line it is: only Jess's line has a voice note.
    expect(find.bySemanticsLabel(RegExp(r'^Line 1, Not saved yet\. Voice note unavailable$')),
        findsOneWidget,
        reason: 'unsaved words have no contribution behind them yet, and are still read out');
    expect(find.bySemanticsLabel(RegExp(r'^Line 2, Streetlights.*\. Double tap to record')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Line 3, Your frequency.*\. Has a voice note')), findsOneWidget);

    await _settle(tester);
    expect(find.bySemanticsLabel(RegExp(r'^Line 1, Not saved yet\. Double tap to record')), findsOneWidget);
    expect(_lines(controller), hasLength(3));
    semantics.dispose();
  });

  testWidgets('a blank line is read out as an empty line, not as its stored marker', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = await _open(tester);

    await tester.enterText(_words, '$_taylorsLine\n\n$_jesssLine');
    await _settle(tester);

    expect(_lines(controller).map((line) => line.body), <String>[_taylorsLine, blankStoredLine, _jesssLine]);
    expect(find.bySemanticsLabel(RegExp(r'^Line 2, empty line\. Double tap to record')), findsOneWidget);
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

  testWidgets('writing on while a save adds a line is not refused as somebody else\'s change',
      (tester) async {
    // Review, 17 September 2026. Typing during a save queues the next save
    // straight behind it, before any frame rebuilds the editor. That save
    // used the song as it was when the editor was last built, without the
    // line the first save had just added, so the order check read the
    // writer's own new line as a bandmate's and refused for good.
    final repository = _SlowNewLines();
    final controller = await _open(tester, repository: repository);

    await tester.enterText(_words, 'A brand new first line\n$_taylorsLine\n$_jesssLine');
    await tester.pump(const Duration(milliseconds: 800));
    // The first save is out, waiting on the connection. The writer goes on.
    await tester.enterText(_words, 'A brand new first line\n$_taylorsLine\n$_jesssLine, still going');
    await tester.pump(const Duration(milliseconds: 800));

    repository.gate.complete();
    await _settle(tester);

    expect(_lines(controller).map((line) => line.body), <String>[
      'A brand new first line',
      _taylorsLine,
      '$_jesssLine, still going',
    ]);
    expect(find.textContaining('Not saved'), findsNothing);
    expect(_lines(controller).skip(1).map((line) => line.authorName), <String>['Taylor', 'Jess']);
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

  testWidgets('a tap where two lines\' targets overlap goes to the line under the finger',
      (tester) async {
    // Review, 17 September 2026. The taller targets overlap, and the later
    // one sits on top, so which box a finger lands in says nothing about the
    // line. If the tap were resolved from the box, a voice note meant for
    // one line would be recorded against the next one's words.
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final now = DateTime(2026, 9, 17);
    final song = SongProject(
      id: _songId,
      roomId: 'room-1',
      accountId: 'account-1',
      title: 'Overlap',
      createdAt: now,
      updatedAt: now,
      contributions: <Contribution>[
        for (final (index, words) in <String>['First line', 'Second line', 'Third line'].indexed)
          Contribution(
            id: 'line-$index',
            projectId: _songId,
            authorId: 'writer',
            authorName: 'Writer',
            body: words,
            colorValue: 0xFFFF8A4C,
            createdAt: now,
            position: 1024.0 * (index + 1),
          ),
      ],
    );
    final editor = ContinuousSongEditorController();
    addTearDown(editor.dispose);
    final recordedFor = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: ContinuousSongEditor(
          project: song,
          controller: editor,
          authorColor: AppColors.orange,
          onSaveDocument: (_) async {},
          onVoiceBullet: (line) => recordedFor.add(line.body),
          recordingContributionId: null,
          savingContributionId: null,
          loadingVoiceContributionId: null,
          playingContributionId: null,
        ),
      ),
    ));
    await tester.pump();

    Future<void> tapAt(double y, {required double x}) async {
      await tester.tapAt(Offset(x, y));
      // The tap waits for a frame before it maps the line to a contribution.
      await tester.pump();
      await tester.pump();
    }

    final first = tester.getRect(find.bySemanticsLabel(RegExp(r'^Line 1, First line')));
    final second = tester.getRect(find.bySemanticsLabel(RegExp(r'^Line 2, Second line')));
    final third = tester.getRect(find.bySemanticsLabel(RegExp(r'^Line 3, Third line')));
    // Each target is centred on its line and the lines are the same height,
    // so the boundary between the second and third is halfway between
    // their centres.
    final boundary = (second.center.dy + third.center.dy) / 2;
    expect(third.top, lessThan(boundary - 2), reason: 'the targets overlap here');
    expect(second.bottom, greaterThan(boundary + 2), reason: 'the targets overlap here');
    final x = second.center.dx;

    await tapAt(boundary - 2, x: x);
    expect(recordedFor, <String>['Second line'],
        reason: 'just above the boundary is the second line, though the third line\'s box is on top');

    await tapAt(boundary + 2, x: x);
    expect(recordedFor.last, 'Third line');

    // The first target reaches above its line, to the top of the rail. That
    // used to fall through to the last line of the song.
    await tapAt(first.top + 1, x: x);
    expect(recordedFor.last, 'First line');
    expect(recordedFor, hasLength(3));
    semantics.dispose();
  });
}
