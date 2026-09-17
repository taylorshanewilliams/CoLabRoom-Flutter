import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/songs/new_song_flow.dart';
import 'package:colabroom/features/workspace/ask_bar.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The last of the small things, from the same audit of 17 September 2026.
///
/// Three kinds of loose end, all found while fixing something else: a helper
/// sentence that stops at an ellipsis because nothing told it it could wrap; a
/// sentence about a full Room shown to somebody adding a link to their
/// profile; and two controls a thumb has to aim at, 33 and 28 pixels tall
/// where a touch wants 48.
Future<void> _phone(WidgetTester tester,
    {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A route that has been pushed and has finished arriving.
Future<void> _arrive(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<MusicBetaController> _controller([InMemoryMusicRepository? given]) async {
  final controller =
      MusicBetaController(given ?? InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  return controller;
}

/// Whether the helper under a field can wrap, and did not have to be cut short
/// to fit. Same two checks as the New set dialog's: the setting on its own,
/// because the test font is wider than any real one, and the laid-out result
/// on an ordinary phone.
void _wholeSentence(WidgetTester tester, Finder helper) {
  expect(helper, findsOneWidget);
  final maxLines = tester.widget<Text>(helper).maxLines;
  expect(maxLines, isNotNull, reason: 'unset means one line and an ellipsis');
  expect(maxLines, greaterThan(1));
  expect(tester.renderObject<RenderParagraph>(helper).didExceedMaxLines, isFalse,
      reason: 'the sentence was cut off');
}

/// The song workspace, open on the seeded room's first song.
Future<SongProject> _workspace(WidgetTester tester) async {
  await _phone(tester, size: const Size(390, 900));
  final controller = await _controller();
  final project = controller.rooms.expand((room) => room.projects).first;

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongWorkspaceScreen(projectId: project.id),
    ),
  ));
  for (var i = 0; i < 5; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  return project;
}

/// A profile whose showcase is already full, answering the way the database
/// does: 54000, "program limit exceeded", with a message written for whoever
/// reads the logs rather than for the person holding the phone.
class _ShowcaseIsFull extends InMemoryMusicRepository {
  _ShowcaseIsFull() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<void> addShowcaseLink({required String url, String title = ''}) async {
    throw PostgrestException(
      message: 'A profile can show up to eight links.',
      code: '54000',
    );
  }
}

void main() {
  group('helpers say the whole of their sentence', () {
    testWidgets('the Name your song dialog, about the room it is saving to',
        (tester) async {
      final controller = await _controller();
      final room = await controller.createRoom(
          name: 'Wednesday night at the Old Chapel', icon: '♪');
      await _phone(tester);

      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showNewSongFlow(context, controller, initialRoom: room),
                  child: const Text('New song'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('New song'));
      await _arrive(tester);

      expect(find.text('Name your song'), findsOneWidget);
      // It used to stop at "Saving to Wednesday night at the O…", cutting off
      // the one word anybody reads it for.
      _wholeSentence(
          tester, find.text('Saving to Wednesday night at the Old Chapel'));
    });

    testWidgets('the Rename song dialog, about names being unique',
        (tester) async {
      final project = await _workspace(tester);

      await tester.tap(find.text(project.title).first);
      await _arrive(tester);

      expect(find.text('Rename song'), findsOneWidget);
      _wholeSentence(
          tester, find.text('Song names are unique across your account.'));
    });
  });

  group('a limit says what was full', () {
    testWidgets('a ninth link is refused about links, not about Rooms',
        (tester) async {
      await _phone(tester);
      final repository = _ShowcaseIsFull();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: MusicianProfileScreen(
          profileId: repository.currentUserId,
          repository: repository,
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      final add = find.widgetWithText(TextButton, 'Add');
      await tester.scrollUntilVisible(add, 220, maxScrolls: 20);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(add);
      await _arrive(tester);

      await tester.enterText(find.byKey(const Key('link_url_field')),
          'https://soundcloud.com/taylor/a-ninth-song');
      await tester.pump();
      await tester.tap(find.byKey(const Key('link_add_button')));
      await _arrive(tester);

      expect(find.text('You can show up to 8 links.'), findsOneWidget,
          reason: 'the cap the database raised is the one about links');
      expect(find.textContaining('Room'), findsNothing,
          reason: 'nobody adding a link to their profile is asking about a '
              'Room, and this sheet said "That Room is full."');
    });
  });

  group('a thumb can reach them', () {
    testWidgets('every pill on the song toolbar is 48 pixels tall, and still '
        'looks 33', (tester) async {
      await _workspace(tester);

      for (final key in <String>[
        'workspace_layers_button',
        'workspace_record_button',
        'workspace_live_button',
        'workspace_cowork_button',
        'workspace_ask_button',
      ]) {
        final touch = tester.getRect(find.byKey(Key(key)));
        expect(touch.height, greaterThanOrEqualTo(48), reason: key);
        // The pill itself is unchanged: a toolbar of six 48-pixel buttons
        // would take the words' room on a screen that is mostly the song.
        final painted = tester.getRect(find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(DecoratedBox),
        ));
        expect(painted.height, lessThan(40), reason: key);
        // And it is drawn exactly where it was: three pixels of the toolbar's
        // old padding above it, five below, now inside the pill's own box
        // instead of around it.
        expect(painted.top - touch.top, 6.5, reason: key);
        expect(touch.bottom - painted.bottom, 8.5, reason: key);
      }
    });

    testWidgets('Ask answers a tap above the pill', (tester) async {
      final project = await _workspace(tester);

      final ask = find.byKey(const Key('workspace_ask_button'));
      await tester.ensureVisible(ask);
      await tester.pump(const Duration(milliseconds: 250));
      final box = tester.getRect(ask);

      // Two pixels down from the top of the toolbar: inside the 48, outside
      // the pill, and exactly where a thumb aiming at the last pill in a
      // sideways-scrolling row tends to land.
      await tester.tapAt(Offset(box.center.dx, box.top + 2));
      for (var i = 0; i < 5; i += 1) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      expect(find.text('Ask about ${project.title}'), findsOneWidget);
    });

    testWidgets('an ask chip answers a tap above its close button',
        (tester) async {
      await _phone(tester);
      final repository = InMemoryMusicRepository.seeded();
      final ask = await repository.askFor(projectId: 'song-1', part: 'drums');

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AskBar(projectId: 'song-1', repository: repository),
        ),
      ));
      await tester.pumpAndSettle();

      final chip = find.byKey(Key('ask_chip_${ask.id}'));
      final box = tester.getRect(chip);
      expect(box.height, greaterThanOrEqualTo(48));
      // The chip is still a label on a song, not a button: 40 pixels, drawn
      // where it always was, centred in a line that was already 48 tall.
      final painted =
          tester.getRect(find.descendant(of: chip, matching: find.byType(Row)));
      expect(painted.height, lessThanOrEqualTo(40));
      expect(painted.center.dy, box.center.dy);

      // One pixel down from the top of the line, over the close button and
      // three clear of the chip: the button draws 40 pixels of itself and
      // answers for 48.
      await tester.tapAt(Offset(box.right - 16, box.top + 1));
      await tester.pumpAndSettle();

      expect(find.text('Stop asking for drums?'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();

      expect(await repository.loadAsks('song-1'), isEmpty);
      expect(find.text('needs drums'), findsNothing);
    });
  });
}
