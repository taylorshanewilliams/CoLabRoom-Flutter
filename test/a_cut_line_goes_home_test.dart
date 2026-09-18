import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/data/music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A line you cut goes back to whoever wrote it.
///
/// Every Musician, Same Song, 17 September 2026: "nobody's words disappear".
/// #343 made a new line in the middle keep every line with its writer; a line
/// taken out was still deleted, and its voice note with it. Now a cut line
/// leaves the song and is kept for its writer, whoever cut it, and the
/// writer finds it under "Your cut lines" (migration 0153).
///
/// These drive the in-memory repository and the real song screen. The
/// repository stands in for cut_line and lines_you_cut; the policy that hides
/// a cut line from everybody is proved in supabase/smoke/10_scenario.sql.
const _songId = 'song-1';
const _taylorsLine = 'Streetlights blur like a warning in the rain';
const _jesssLine = 'Your frequency keeps calling out my name';
const _thirdLine = 'A third line at the end';

final _words = find.byKey(const Key('continuous_song_document'));

/// Counts what the editor writes, so a save can be shown to write nothing
/// about a line that has gone.
class _Counting extends InMemoryMusicRepository {
  _Counting() : super.from(InMemoryMusicRepository.seeded());

  final List<String> added = <String>[];
  int cuts = 0;

  @override
  Future<Contribution> addContribution({
    required SongProject project,
    required String body,
    int colorValue = 0xFFFF8A4C,
    double? position,
  }) {
    added.add(body);
    return super.addContribution(project: project, body: body, colorValue: colorValue, position: position);
  }

  @override
  Future<void> cutLine(Contribution line) {
    cuts += 1;
    return super.cutLine(line);
  }
}

Future<MusicBetaController> _open(WidgetTester tester, {MusicRepository? repository}) async {
  tester.view.physicalSize = const Size(390, 844);
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

Future<SongProject> _project(MusicRepository repository) async =>
    (await repository.loadRooms()).first.projects.single;

List<Contribution> _lines(MusicBetaController controller) =>
    controller.projectById(_songId)!.contributions;

String _text(WidgetTester tester) => tester.widget<TextField>(_words).controller!.text;

void main() {
  group('in the repository', () {
    test('cutting a line keeps the writer\'s copy, voice note and all', () async {
      final repository = InMemoryMusicRepository.seeded();
      var project = await _project(repository);
      final note = await repository.attachVoiceNote(
        project: project,
        contribution: project.contributions.first,
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        durationMs: 900,
      );
      project = await _project(repository);
      final taylors = project.contributions.first;
      expect(taylors.authorId, 'preview-user', reason: 'the fixture\'s first line is the signed-in person\'s');

      await repository.cutLine(taylors);

      project = await _project(repository);
      expect(project.contributions.map((line) => line.id), <String>['line-2'],
          reason: 'a cut line is not part of the song');
      final kept = await repository.linesYouCut(project);
      expect(kept.map((line) => line.id), <String>['line-1']);
      expect(kept.single.body, _taylorsLine);
      expect(kept.single.authorName, 'Taylor');
      expect(kept.single.voiceNote?.id, note.id, reason: 'the voice note is the line\'s, and goes with it');
      expect(await repository.loadVoiceNote(note), Uint8List.fromList(<int>[1, 2, 3, 4]));
    });

    test('a second person\'s cut lines stay private to them', () async {
      final repository = InMemoryMusicRepository.seeded();
      var project = await _project(repository);
      final jesss = project.contributions[1];
      expect(jesss.authorId, isNot('preview-user'));

      // Taylor cuts Jess's line. It leaves the song, and Taylor keeps nothing.
      await repository.cutLine(jesss);
      project = await _project(repository);
      expect(project.contributions.map((line) => line.id), <String>['line-1']);
      expect(await repository.linesYouCut(project), isEmpty,
          reason: 'the person who cut a line is not the person it is kept for');

      // Then their own. Only that one comes back.
      await repository.cutLine(project.contributions.single);
      project = await _project(repository);
      expect(project.contributions, isEmpty);
      final kept = await repository.linesYouCut(project);
      expect(kept.map((line) => line.id), <String>['line-1']);
    });

    test('cutting a line that is already cut changes nothing', () async {
      final repository = InMemoryMusicRepository.seeded();
      var project = await _project(repository);
      final taylors = project.contributions.first;

      await repository.cutLine(taylors);
      await repository.cutLine(taylors);

      project = await _project(repository);
      expect((await repository.linesYouCut(project)).map((line) => line.id), <String>['line-1'],
          reason: 'one line, one copy');
    });
  });

  group('in the editor', () {
    testWidgets('a line taken out of the words is kept for its writer', (tester) async {
      final repository = _Counting();
      final controller = await _open(tester, repository: repository);
      await repository.addContribution(project: controller.projectById(_songId)!, body: _thirdLine);
      await controller.load();
      await _settle(tester);
      expect(_text(tester), '$_taylorsLine\n$_jesssLine\n$_thirdLine');
      repository.added.clear();

      await tester.enterText(_words, '$_jesssLine\n$_thirdLine');
      await _settle(tester);

      expect(_lines(controller).map((line) => line.body), <String>[_jesssLine, _thirdLine]);
      expect(repository.cuts, 1);
      final kept = await controller.linesYouCut(controller.projectById(_songId)!);
      expect(kept.map((line) => line.body), <String>[_taylorsLine]);
    });

    testWidgets('the next save does not bring a cut line back', (tester) async {
      final repository = _Counting();
      final controller = await _open(tester, repository: repository);
      await repository.addContribution(project: controller.projectById(_songId)!, body: _thirdLine);
      await controller.load();
      await _settle(tester);

      await tester.enterText(_words, '$_jesssLine\n$_thirdLine');
      await _settle(tester);
      expect(repository.cuts, 1);
      repository.added.clear();

      // Keep writing. The save after the cut diffs against what the editor
      // now holds, which no longer has the cut line in it; a stale picture
      // would read the same text as another delete, or as a move, and send
      // a write for a row the song no longer shows (#343's diff, and 0153).
      await tester.enterText(_words, '$_jesssLine\n$_thirdLine, and on');
      await _settle(tester);

      expect(_lines(controller).map((line) => line.body), <String>[_jesssLine, '$_thirdLine, and on']);
      expect(_text(tester), isNot(contains(_taylorsLine)));
      expect(repository.cuts, 1, reason: 'nothing was cut again');
      expect(repository.added, isEmpty, reason: 'and nothing was written back');

      // Nor does reopening the song: the reload draws from what the song
      // holds, and a cut line is not in it.
      await controller.load();
      await _settle(tester);
      expect(_lines(controller).map((line) => line.body), <String>[_jesssLine, '$_thirdLine, and on']);
      expect(_text(tester), '$_jesssLine\n$_thirdLine, and on');
      final kept = await controller.linesYouCut(controller.projectById(_songId)!);
      expect(kept.map((line) => line.body), <String>[_taylorsLine], reason: 'one line, one copy, still there');
    });

    testWidgets('Your cut lines shows yours and nobody else\'s', (tester) async {
      final controller = await _open(tester);
      final lines = _lines(controller);
      await controller.repository.cutLine(lines[1]);
      await controller.repository.cutLine(lines[0]);
      await controller.load();
      await _settle(tester);
      expect(_lines(controller), isEmpty);

      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      expect(find.text('Your cut lines'), findsOneWidget);
      expect(find.text('Kept for you, whoever cut them'), findsOneWidget);
      await tester.tap(find.byKey(const Key('song_cut_lines')));
      await _settle(tester);

      expect(find.byKey(const Key('cut_lines_sheet')), findsOneWidget);
      expect(find.byKey(const Key('cut_line_line-1')), findsOneWidget);
      expect(find.text(_taylorsLine), findsOneWidget);
      expect(find.byKey(const Key('cut_line_line-2')), findsNothing,
          reason: 'Jess\'s line is kept for Jess');
      expect(find.text(_jesssLine), findsNothing);
      expect(find.textContaining('Nothing of yours'), findsNothing);
    });

    testWidgets('with nothing cut, the sheet says where a line would wait', (tester) async {
      await _open(tester);

      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_cut_lines')));
      await _settle(tester);

      expect(find.byKey(const Key('cut_lines_sheet')), findsOneWidget);
      expect(find.textContaining('Nothing of yours has been cut from this song.'), findsOneWidget);
    });
  });
}
