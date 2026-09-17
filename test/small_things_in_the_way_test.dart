import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:colabroom/widgets/app_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small things in the way, from the audit of 17 September 2026.
///
/// None of these stopped anything working. Each was something on Home, the
/// Sets list, the Open Mic or your own profile sitting where it should not:
/// a song row under the record button, a room nobody made on purpose, a
/// sentence cut off halfway, a title off the page's edge, and a link sheet
/// that threw away what you typed to tell you why.
Future<MusicBetaController> _controller() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await SetAside.load();
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _phone(WidgetTester tester,
    {Size size = const Size(360, 740)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A route that has been pushed and has finished arriving.
///
/// One pump starts the transition and the next finishes it; a single long
/// pump only draws its first frame, with the sheet still below the screen.
Future<void> _arrive(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Home the way the shell hosts it: a tab body under a Scaffold whose gold
/// button floats over the bottom-right corner.
Future<void> _home(WidgetTester tester, MusicBetaController controller) async {
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: SongsScreen(
          displayName: 'Taylor',
          onOpenAccount: () {},
          onOpenNotifications: () {},
          onRecord: () {},
        ),
        floatingActionButton: FloatingActionButton(
          key: const Key('record_button'),
          onPressed: () {},
          child: const Icon(Icons.mic_rounded),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Whether the helper under a field can wrap, and did not have to be cut
/// short to fit.
///
/// Both, because the test font is wider than any real one: a sentence that
/// takes one or two lines on a phone takes three here. So the layout is
/// checked on an ordinary phone at ordinary text size, where it still means
/// something, and the setting is checked on its own. Left unset, a helper
/// is one line and an ellipsis, which is how this was found.
void _wholeSentence(WidgetTester tester, Finder helper) {
  expect(helper, findsOneWidget);
  final maxLines = tester.widget<Text>(helper).maxLines;
  expect(maxLines, isNotNull, reason: 'unset means one line and an ellipsis');
  expect(maxLines, greaterThan(1));
  expect(tester.renderObject<RenderParagraph>(helper).didExceedMaxLines,
      isFalse, reason: 'the sentence was cut off');
}

void main() {
  group('the record button', () {
    testWidgets('the end of the song list scrolls clear of it', (tester) async {
      await _phone(tester);
      final controller = await _controller();
      // Enough rooms that the list is longer than the phone, so the last
      // song is the one that ends up in the corner.
      for (var i = 0; i < 8; i++) {
        final room = await controller.createRoom(name: 'Band $i', icon: '♪');
        await controller.createSong(room, 'Last song $i');
      }
      await _home(tester, controller);

      // As far as the list goes: the list's own scroll position, rather than
      // a drag the test font's line heights would have to be guessed for.
      final list = tester.state<ScrollableState>(find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first);
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 100));
      // Laying out the end can change how long the list turns out to be.
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 100));

      final last = find.ancestor(
        of: find.text('Last song 7'),
        matching: find.byType(AppSurface),
      );
      expect(last, findsOneWidget, reason: 'scrolled to the end of the list');
      final row = tester.getRect(last);
      final button = tester.getRect(find.byKey(const Key('record_button')));

      expect(row.overlaps(button), isFalse,
          reason: 'the last song row, its waveform and its chevron, must be '
              'somewhere the gold button is not once the list is at its end');
    });
  });

  group('the Ideas room', () {
    testWidgets('an empty one the record button made stays off Home, and '
        'comes back with its first song', (tester) async {
      await _phone(tester);
      final controller = await _controller();
      // Record, then back out without a sound: the song is swept up and the
      // room it was filed in is left behind, as the shell's _record does.
      final idea = await controller.startIdea();
      expect(await controller.repository.discardIfUntouched(idea.id), isTrue);
      await controller.load();
      expect(
        controller.rooms.where((room) => room.name == 'Ideas'),
        hasLength(1),
        reason: 'the room is kept; only Home stops showing it',
      );

      await _home(tester, controller);

      expect(find.text('Ideas'), findsNothing,
          reason: 'nobody asked for this room, and there is nothing in it');
      expect(find.text('After Hours Studio'), findsWidgets);
      expect(find.text('Acoustic Ideas'), findsOneWidget,
          reason: 'a room somebody made and left empty is still theirs to see');
      expect(find.text('Nothing in here yet'), findsOneWidget);

      // The Rooms segment answers "what rooms do I have" the same way.
      await tester.tap(find.text('Rooms'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ideas'), findsNothing);
      expect(find.text('Acoustic Ideas'), findsOneWidget);
      await tester.tap(find.text('Songs'));
      await tester.pump(const Duration(milliseconds: 300));

      // A take that stays.
      await controller.startIdea(title: 'Hummed on the bus');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Ideas'), findsWidgets,
          reason: 'with a song in it, it is a place like any other');
      expect(find.text('Hummed on the bus'), findsWidgets);
    });

    test('only the one the app made, only while it is empty and yours alone',
        () {
      final now = DateTime(2026, 9, 17);
      const me = RoomMember(
        userId: 'me',
        displayName: 'Taylor',
        role: RoomRole.owner,
        colorValue: 0xFFFF8A4C,
      );
      const jess = RoomMember(
        userId: 'jess',
        displayName: 'Jess',
        role: RoomRole.editor,
        colorValue: 0xFF4CC9F0,
      );
      MusicRoom room({
        String name = 'Ideas',
        String icon = '💡',
        String owner = 'me',
        List<RoomMember> members = const <RoomMember>[me],
        List<SongProject> projects = const <SongProject>[],
      }) =>
          MusicRoom(
            id: 'room',
            accountId: owner,
            name: name,
            icon: icon,
            createdAt: now,
            updatedAt: now,
            members: members,
            projects: projects,
          );
      final song = SongProject(
        id: 'song',
        roomId: 'room',
        accountId: 'me',
        title: 'Idea 1',
        createdAt: now,
        updatedAt: now,
      );

      expect(isUnusedIdeasRoom(room(), me: 'me'), isTrue);
      expect(isUnusedIdeasRoom(room(projects: <SongProject>[song]), me: 'me'),
          isFalse, reason: 'a song in it makes it a place');
      expect(isUnusedIdeasRoom(room(icon: '♪'), me: 'me'), isFalse,
          reason: 'named Ideas by hand, from New > Room');
      expect(isUnusedIdeasRoom(room(name: 'Acoustic Ideas'), me: 'me'), isFalse);
      expect(
          isUnusedIdeasRoom(room(members: const <RoomMember>[me, jess]), me: 'me'),
          isFalse,
          reason: 'somebody else is in it');
      expect(isUnusedIdeasRoom(room(owner: 'jess'), me: 'me'), isFalse,
          reason: 'not yours to have made');
    });
  });

  group('sets', () {
    testWidgets('the New set dialog says the whole of its sentence',
        (tester) async {
      await _phone(tester, size: const Size(390, 844));
      final controller = await _controller();
      await _home(tester, controller);

      await tester.tap(find.byKey(const Key('songs_new_button')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Set'));
      await _arrive(tester);

      // It used to stop at "You’ll pick the songs and their or…".
      _wholeSentence(
          tester, find.text('You’ll pick the songs and their order next.'));
    });

    testWidgets('an empty Sets list has a way to make one', (tester) async {
      await _phone(tester);
      final controller = await _controller();
      expect(controller.setlists, isEmpty);
      await _home(tester, controller);

      await tester.tap(find.text('Sets'));
      await tester.pump(const Duration(milliseconds: 300));

      final make = find.byKey(const Key('sets_empty_new'));
      expect(make, findsOneWidget,
          reason: 'the empty state described a set and offered no way to '
              'make one');
      await tester.tap(make);
      await _arrive(tester);

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget,
          reason: 'the same dialog the New menu opens');
      expect(find.descendant(of: dialog, matching: find.text('New set')),
          findsOneWidget);
      expect(find.text('You’ll pick the songs and their order next.'),
          findsOneWidget);
    });
  });

  testWidgets('the lesson link field says the whole of its sentence',
      (tester) async {
    await _phone(tester, size: const Size(390, 844));
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LessonLinkScreen(repository: InMemoryMusicRepository.seeded()),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    _wholeSentence(tester,
        find.text('Each student\'s room is called this, with their name.'));
  });

  testWidgets('the Open Mic title starts on the same edge as Your music',
      (tester) async {
    await _phone(tester);
    final controller = await _controller();
    await _home(tester, controller);
    final yourMusic = tester.getTopLeft(find.text('Your music')).dx;

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: OpenMicScreen(repository: InMemoryMusicRepository.seeded()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getTopLeft(find.text('Open Mic')).dx, yourMusic,
        reason: 'the two tab titles sit on one gutter; on a phone the Open '
            'Mic one used to be centred with its buttons instead');
  });

  group('linking something you made', () {
    Future<InMemoryMusicRepository> openSheet(WidgetTester tester) async {
      await _phone(tester, size: const Size(390, 844));
      final repository = InMemoryMusicRepository.seeded();
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
      expect(find.text('Link something you made'), findsOneWidget);
      return repository;
    }

    testWidgets('a link it cannot take keeps the sheet, the text and the '
        'reason together', (tester) async {
      final repository = await openSheet(tester);
      final before = (await repository.loadShowcase(repository.currentUserId))
          .length;

      const typed = 'https://evil.example/open.spotify.com/track/1';
      await tester.enterText(find.byKey(const Key('link_url_field')), typed);
      await tester.pump();
      await tester.tap(find.byKey(const Key('link_add_button')));
      await _arrive(tester);

      expect(find.text('Link something you made'), findsOneWidget,
          reason: 'the sheet stays open to be corrected');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('link_url_field')))
            .controller!
            .text,
        typed,
        reason: 'what was typed is still there to fix',
      );
      final reason = find.descendant(
        of: find.byKey(const Key('link_url_field')),
        matching: find.textContaining('Links can point to'),
      );
      expect(reason, findsOneWidget, reason: 'the reason sits under the field');
      _wholeSentence(tester, reason);
      expect(find.byType(SnackBar), findsNothing,
          reason: 'not in a snackbar behind the sheet');
      expect(
          (await repository.loadShowcase(repository.currentUserId)).length,
          before);

      // Fixing it is typing, and the complaint goes when the words change.
      await tester.enterText(find.byKey(const Key('link_url_field')),
          'https://soundcloud.com/taylor/a-song');
      await tester.pump();
      expect(find.textContaining('Links can point to'), findsNothing,
          reason: 'a reason about the old words is not one about these');

      await tester.tap(find.byKey(const Key('link_add_button')));
      await _arrive(tester);
      await _arrive(tester);

      expect(find.text('Link something you made'), findsNothing,
          reason: 'a link it takes closes the sheet');
      expect(
          (await repository.loadShowcase(repository.currentUserId)).length,
          before + 1);
    });
  });
}
