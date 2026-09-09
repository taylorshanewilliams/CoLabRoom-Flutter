import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/shell/app_shell.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desk stops looking like a phone somebody pulled at the corners.
///
/// **The premise of this file moved once and the assertions moved with it.**
///
/// It started by proving the content had an edge: the shell put every screen
/// in an unlimited `Expanded`, so on a 1440px browser every card and line of
/// text built for a 390px phone was drawn across roughly 1300 of them. A cap
/// fixed that, and the note left behind said what would come next — "a real
/// desk layout puts filters beside results and the song sheet beside the
/// takes, and that is per-screen work. But a screen cannot be split until it
/// has an edge."
///
/// That work is now done, and it makes the old assertion wrong rather than
/// merely stale. A page that is one column of phone-shaped cards needs a cap;
/// a page that is a library beside a song does not, because each pane has its
/// own measure and the cap is holding the layout back instead of protecting
/// the reading.
///
/// So what is checked here is the thing that was always actually meant: **no
/// line of text is drawn across a monitor**, wherever the protection happens
/// to live this month.
Future<MusicBetaController> _controller() async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  return controller;
}

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = await _controller();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: SongsScreen(
          displayName: 'Taylor',
          onOpenAccount: () {},
          onOpenNotifications: () {},
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a desk shows the song beside the library', (tester) async {
    await _pump(tester, const Size(1440, 900));

    expect(
      find.byType(SongWorkspaceScreen),
      findsOneWidget,
      reason: 'a desk that lists songs and shows none of them has spent two '
          'thirds of a monitor on a table of contents',
    );
  });

  testWidgets('and opens on one rather than on an empty pane', (tester) async {
    await _pump(tester, const Size(1440, 900));

    // The most recently touched song, chosen for them. "Pick something" is a
    // question, and a screen whose whole content is a question is the exact
    // emptiness this layout was built to answer.
    expect(find.text('Midnight Signal'), findsWidgets);
  });

  testWidgets('a phone gets one thing at a time and every pixel of it',
      (tester) async {
    await _pump(tester, const Size(390, 844));

    expect(
      find.byType(SongWorkspaceScreen),
      findsNothing,
      reason: 'a song on a phone is a route, not a pane — 390px split in two '
          'gives the words less than either half deserves',
    );
  });

  testWidgets('the words keep a measure however wide the pane gets',
      (tester) async {
    // The assertion this file has always really been making. At 1920 the
    // song pane is over 1500 wide, and a line of lyrics drawn across that is
    // the original defect wearing a different layout.
    await _pump(tester, const Size(1920, 1080));

    final editor = find.descendant(
      of: find.byType(SongWorkspaceScreen),
      matching: find.byType(ConstrainedBox),
    );
    expect(editor, findsWidgets);

    final widest = tester
        .widgetList<ConstrainedBox>(editor)
        .map((box) => box.constraints.maxWidth)
        .where((width) => width.isFinite)
        .fold<double>(0, (a, b) => a > b ? a : b);
    expect(
      widest,
      lessThanOrEqualTo(900),
      reason: 'nothing inside the song pane caps its width, so a line of '
          'lyrics is being drawn across the whole monitor again',
    );
  });

  test('the shell still caps an ultrawide', () {
    // Wide enough for two panes, and still an edge on a very large monitor —
    // a page that runs to 3440px has no margin, and no margin reads as a
    // document nobody laid out.
    expect(kDeskColumn, greaterThan(1400),
        reason: 'narrower than this and there is no room for a library '
            'beside a song, which is what the desk layout is');
    expect(kDeskColumn, lessThan(1920));
  });
}
