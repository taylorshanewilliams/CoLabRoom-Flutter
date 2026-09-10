import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/workspace/song_analysis_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/widgets/app_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The song sheet and the takes stop being somewhere else.
///
/// Taylor, on the web: "when on a song and you see the options on the right,
/// like song sheet, takes, etc. when you click one it opens that up for
/// screen and feels very stretched and takes you out of the project, can we
/// find a way to have that open in the project so you still feel in the same
/// place".
///
/// Both were routes, which is right on a phone — there is room for one thing
/// and the song has to get out of the way. On a desk it throws away the two
/// things that say where you are, the library and the song's own header, to
/// draw a screen built for 390px across 1500.
Future<(MusicBetaController, String)> _song(WidgetTester tester) async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  return (controller, controller.rooms.first.projects.first.id);
}

Future<void> _pump(
  WidgetTester tester,
  MusicBetaController controller,
  String projectId, {
  required bool embedded,
  Size size = const Size(1100, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongWorkspaceScreen(projectId: projectId, embedded: embedded),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the takes open inside the song, not on top of it',
      (tester) async {
    final (controller, projectId) = await _song(tester);
    await _pump(tester, controller, projectId, embedded: true);

    await tester.tap(find.byKey(const Key('workspace_layers_button')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SongLayersScreen), findsOneWidget);
    expect(
      find.byType(SongWorkspaceScreen),
      findsOneWidget,
      reason: 'the song is still the thing you are in — the panel replaced '
          'the words and nothing else',
    );
    expect(find.text('Midnight Signal'), findsWidgets,
        reason: 'the header goes on naming the song above the panel');
  });

  testWidgets('the song sheet opens the same way', (tester) async {
    final (controller, projectId) = await _song(tester);
    await _pump(tester, controller, projectId, embedded: true);

    await tester.tap(find.byKey(const Key('workspace_analyze_button')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SongAnalysisScreen), findsOneWidget);
    expect(find.byType(SongWorkspaceScreen), findsOneWidget);
  });

  testWidgets('and there is a way back to the words', (tester) async {
    final (controller, projectId) = await _song(tester);
    await _pump(tester, controller, projectId, embedded: true);

    await tester.tap(find.byKey(const Key('workspace_layers_button')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SongLayersScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back to the words'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SongLayersScreen), findsNothing);
    expect(find.byType(SongWorkspaceScreen), findsOneWidget);
  });

  testWidgets('the mark in the corner goes home', (tester) async {
    // It was drawn, placed in the corner and wired to nothing, and on a desk
    // there was nothing else that meant *out*: the tabs are along the top
    // rather than under a thumb, and a song or a room can sit several routes
    // above them.
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    var wentHome = false;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AppTopBar(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
            tabs: const <String>['Your music', 'Open Mic'],
            onGoHome: () => wentHome = true,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const Key('brand_home_button')));
    await tester.pump();
    expect(wentHome, isTrue);
  });

  testWidgets('on a phone they are still routes', (tester) async {
    final (controller, projectId) = await _song(tester);
    await _pump(tester, controller, projectId,
        embedded: false, size: const Size(390, 844));

    expect(find.byKey(const Key('workspace_layers_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('workspace_layers_button')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // A phone has room for one thing. Pushing is right there, and this is
    // the half of the change that must not move.
    expect(find.byType(SongLayersScreen), findsOneWidget);
    expect(find.byTooltip('Back to the words'), findsNothing,
        reason: 'a pushed route has its own back arrow already');
  });
}
