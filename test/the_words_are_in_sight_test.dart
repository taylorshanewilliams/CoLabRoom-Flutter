import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A song opens with its words in sight.
///
/// 17 September 2026, in the audit: every song opened on a phone and on the
/// web showed a black page under the toolbar. The words were there, 91 px
/// above the top edge. The editor filled the whole screen and then added its
/// padding, so there was always a little to scroll, and the workspace
/// scrolled to the end when the song opened. A short song lost its first
/// lines, a new song lost the "Tap anywhere and start writing…" hint, and an
/// empty one looked broken.
///
/// On the same song, a tap into that blank page saved a blank line into it:
/// the editor counted a cursor move as an edit.
class _Counting extends InMemoryMusicRepository {
  _Counting() : super.from(InMemoryMusicRepository.seeded());

  int writes = 0;

  @override
  Future<Contribution> addContribution({
    required SongProject project,
    required String body,
    int colorValue = 0xFFFF8A4C,
    double? position,
  }) {
    writes += 1;
    return super.addContribution(project: project, body: body, colorValue: colorValue, position: position);
  }

  @override
  Future<Contribution> updateContribution({required Contribution contribution, required String body}) {
    writes += 1;
    return super.updateContribution(contribution: contribution, body: body);
  }

  @override
  Future<void> deleteContribution(Contribution contribution) {
    writes += 1;
    return super.deleteContribution(contribution);
  }
}

final _words = find.byKey(const Key('continuous_song_document'));

Future<MusicBetaController> _open(WidgetTester tester, {String? title, int lines = 0}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = MusicBetaController(_Counting());
  await controller.load();
  addTearDown(controller.dispose);
  final song = await controller.createSong(controller.rooms.first, title ?? 'Short one');
  for (var i = 0; i < lines; i += 1) {
    await controller.load();
    await controller.repository.addContribution(project: controller.projectById(song.id)!, body: 'Line number ${i + 1}');
  }
  await controller.load();
  (controller.repository as _Counting).writes = 0;
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

/// Where the top of the words is, against the top of the area that shows them.
double _hiddenAbove(WidgetTester tester) {
  final field = tester.getTopLeft(_words).dy;
  final scrollable = find.ancestor(of: _words, matching: find.byType(Scrollable)).first;
  final visibleTop = tester.getTopLeft(scrollable).dy;
  return visibleTop - field;
}

ScrollPosition _position(WidgetTester tester) {
  final scrollable = find.ancestor(of: _words, matching: find.byType(Scrollable)).first;
  return tester.state<ScrollableState>(scrollable).position;
}

void main() {
  testWidgets('a new song shows where to start writing', (tester) async {
    await _open(tester);

    expect(_hiddenAbove(tester), lessThanOrEqualTo(0),
        reason: 'the hint sits at the top of the words, and it has to be on the screen');
    expect(_position(tester).maxScrollExtent, 0,
        reason: 'nothing to scroll on a song shorter than the screen');
  });

  testWidgets('a short song opens with its first line in sight', (tester) async {
    await _open(tester, lines: 3);

    expect(_position(tester).pixels, 0);
    expect(_hiddenAbove(tester), lessThanOrEqualTo(0));
    expect(find.text('Line number 1\nLine number 2\nLine number 3'), findsOneWidget);
  });

  testWidgets('a long song opens at its start, not its end', (tester) async {
    await _open(tester, lines: 60);

    expect(_position(tester).maxScrollExtent, greaterThan(0), reason: 'sixty lines is longer than a phone');
    expect(_position(tester).pixels, 0);
  });

  testWidgets('a tap into the words and away writes nothing', (tester) async {
    final controller = await _open(tester);

    await tester.tap(_words);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(200, 40));
    await tester.pump(const Duration(seconds: 2));

    expect((controller.repository as _Counting).writes, 0,
        reason: 'a cursor is not an edit, and a blank line is not a song');
  });

  testWidgets('typing into an empty song and deleting it again writes nothing', (tester) async {
    final controller = await _open(tester);

    await tester.enterText(_words, 'maybe');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(_words, '');
    await tester.pump(const Duration(seconds: 2));

    expect((controller.repository as _Counting).writes, 0);
  });

  testWidgets('words that change are still saved', (tester) async {
    final controller = await _open(tester, lines: 2);

    await tester.enterText(_words, 'Line number 1\nA better second line');
    await tester.pump(const Duration(seconds: 2));

    expect((controller.repository as _Counting).writes, greaterThan(0));
  });
}
