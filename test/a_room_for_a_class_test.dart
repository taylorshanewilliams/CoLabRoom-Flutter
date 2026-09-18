import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/lesson_link.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/lessons/lesson_poster.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A room for a class.
///
/// Every Musician, Same Song, 17 September 2026, slice 16: a teacher keeps
/// several lesson links, each named for what it opens, and one can be a
/// class. Scanning a class link puts the student in the class room to listen
/// and makes their own two-person lesson room in the same step. They record
/// in their own room, never in front of the class -- refused by the server
/// (0148), and not offered by the app.
void main() {
  Future<MusicBetaController> boot(
    WidgetTester tester,
    InMemoryMusicRepository repository,
    Widget home,
  ) async {
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
    ));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> scrollTo(WidgetTester tester, Key key) => tester.scrollUntilVisible(
        find.byKey(key),
        200,
        scrollable: find
            .descendant(of: find.byKey(const Key('lesson_link_list')), matching: find.byType(Scrollable))
            .first,
      );

  InMemoryMusicRepository adult() => InMemoryMusicRepository.seeded()..callStanding = CallStanding.adult;

  group("the teacher's links", () {
    test('several open at once, each with its own name and code', () async {
      final repository = adult();
      final tuesday = await repository.openLessonLink('Tuesday beginners');
      final jazz = await repository.openLessonLink('Jazz studio');

      final links = await repository.myLessonLinks();
      expect(links.map((link) => link.title), <String>['Tuesday beginners', 'Jazz studio']);
      expect(tuesday.code, isNot(jazz.code));
      // Neither is a class until the teacher says so.
      expect(links.any((link) => link.isClass), isFalse);

      // One at a time: turning the first off leaves the second.
      await repository.closeLessonLink(tuesday.id);
      expect((await repository.myLessonLinks()).map((link) => link.title), <String>['Jazz studio']);
    });

    test("eight is the cap, in the server's sentence", () async {
      final repository = adult();
      for (var n = 1; n <= lessonLinksOpenAtOnce; n++) {
        await repository.openLessonLink('Link $n');
      }
      expect(
        () => repository.openLessonLink('One too many'),
        throwsA(isA<NameConflict>().having((error) => error.message, 'message', lessonLinksAreCapped)),
      );
      // Turning one off makes room for another.
      await repository.closeLessonLink((await repository.myLessonLinks()).first.id);
      await repository.openLessonLink('One more');
      expect((await repository.myLessonLinks()).length, lessonLinksOpenAtOnce);
    });

    testWidgets('the screen lists them by name, opens one onto its code, and makes another', (tester) async {
      final repository = adult();
      await repository.openLessonLink('Tuesday beginners');
      await boot(tester, repository, LessonLinkScreen(repository: repository));

      // The list, not a code: a teacher with links sees which is which.
      expect(find.text('Tuesday beginners'), findsOneWidget);
      expect(find.byKey(const Key('lesson_qr')), findsNothing);
      expect(find.byKey(const Key('lesson_new')), findsOneWidget);

      await tester.tap(find.byKey(const Key('lesson_new')));
      await tester.pumpAndSettle();
      expect(find.text('Another link'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('lesson_title')), 'Jazz studio');
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();

      // Straight onto its code.
      expect(find.byKey(const Key('lesson_qr')), findsOneWidget);
      expect(find.text('Jazz studio'), findsOneWidget);
      expect(find.text('Tuesday beginners'), findsNothing);

      // Back is the list, with both on it.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lesson_qr')), findsNothing);
      expect(find.text('Tuesday beginners'), findsOneWidget);
      expect(find.text('Jazz studio'), findsOneWidget);

      await tester.tap(find.byKey(const Key('lesson_link_row_a1b2c3d4e5f6')));
      await tester.pumpAndSettle();
      expect(find.text('a1b2-c3d4-e5f6'), findsOneWidget);
      expect(find.text('Tuesday beginners'), findsOneWidget);
      expect((await repository.myLessonLinks()).length, 2);
    });

    testWidgets('at eight, the list says so where the ninth would be made', (tester) async {
      final repository = adult();
      for (var n = 1; n <= lessonLinksOpenAtOnce; n++) {
        await repository.openLessonLink('Link $n');
      }
      await boot(tester, repository, LessonLinkScreen(repository: repository));
      expect(find.byKey(const Key('lesson_new')), findsNothing);
      await scrollTo(tester, const Key('lesson_capped'));
      expect(find.text(lessonLinksAreCapped), findsOneWidget);
    });
  });

  group('a class', () {
    test('a link made as a class has a room named for it, owned by the teacher, with nobody else in it yet',
        () async {
      final repository = adult();
      final link = await repository.openLessonLink('Jazz studio', asClass: true);
      expect(link.isClass, isTrue);
      expect(link.classRoomName, 'Jazz studio');

      final controller = MusicBetaController(repository);
      await controller.load();
      final room = controller.roomById(link.classRoomId!);
      expect(room, isNotNull);
      expect(room!.name, 'Jazz studio');
      expect(room.accountId, repository.currentUserId);
      expect(room.members.map((member) => (member.userId, member.role)),
          <(String, RoomRole)>[(repository.currentUserId, RoomRole.owner)]);

      // A plain link beside it is not a class.
      final plain = await repository.openLessonLink('Tuesday beginners');
      expect(plain.isClass, isFalse);
    });

    test('turning the class off leaves the room; turning it on again makes a new one beside it', () async {
      final repository = adult();
      final controller = MusicBetaController(repository);
      final link = await repository.openLessonLink('Jazz studio', asClass: true);
      final firstRoom = link.classRoomId!;

      await repository.setLessonLinkClass(link.id, asClass: false);
      expect((await repository.myLessonLinks()).single.isClass, isFalse);
      await controller.load();
      expect(controller.roomById(firstRoom), isNotNull, reason: 'a room with people in it is theirs');

      await repository.setLessonLinkClass(link.id, asClass: true);
      final again = (await repository.myLessonLinks()).single;
      expect(again.classRoomId, isNot(firstRoom));
      expect(again.classRoomName, 'Jazz studio 2');

      // Saying it twice makes one.
      await repository.setLessonLinkClass(link.id, asClass: true);
      expect((await repository.myLessonLinks()).single.classRoomId, again.classRoomId);
    });

    testWidgets('the form asks; the code page shows which room the poster opens into, and changes it',
        (tester) async {
      final repository = adult();
      await boot(tester, repository, LessonLinkScreen(repository: repository));

      await tester.enterText(find.byKey(const Key('lesson_title')), 'Jazz studio');
      await tester.tap(find.byKey(const Key('lesson_class_switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();

      expect((await repository.myLessonLinks()).single.isClass, isTrue);
      await scrollTo(tester, const Key('lesson_class'));
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('lesson_class'))).value, isTrue);
      expect(find.textContaining('lands in Jazz studio with the whole class'), findsOneWidget);

      await tester.tap(find.byKey(const Key('lesson_class')));
      await tester.pumpAndSettle();
      expect((await repository.myLessonLinks()).single.isClass, isFalse);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('lesson_class'))).value, isFalse);

      // And the list says which links are classes.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Nobody has joined yet'), findsOneWidget);
      expect(find.text('Class · Nobody has joined yet'), findsNothing);
    });

    test('the poster names the class', () async {
      expect(LessonPoster.scanSentence(), contains('just the two of us'));
      expect(
        LessonPoster.scanSentence(className: 'Jazz studio'),
        'Everybody who scans joins Jazz studio with the whole class, to listen, '
        'and gets their own room with me for what they record.',
      );
      // A name the built-in font cannot draw is said the way every other
      // printed name is, rather than breaking the page.
      expect(LessonPoster.scanSentence(className: 'Jazz 🎷'), contains('Jazz ?'));
      final bytes = await LessonPoster.document(
        title: 'Jazz studio',
        code: 'a1b2c3d4e5f6',
        teacher: 'Taylor',
        className: 'Jazz studio',
      ).save();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group("the student's side", () {
    InMemoryMusicRepository classOffered() => adult()
      ..offerLesson(code: '0123456789ab', title: 'Jazz studio', teacherName: 'Maria', classTitle: 'Jazz studio');

    testWidgets('a class link lands in the class room to listen, and in a room of their own, in one step',
        (tester) async {
      final repository = classOffered();
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      Future<void> useCode(String code) async {
        await tester.tap(find.byKey(const Key('inbox_use_code')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, code);
        await tester.pump();
        await tester.tap(find.byKey(const Key('join_code_submit')));
        await tester.pumpAndSettle();
      }

      await useCode('0123-4567-89AB');
      expect(find.text('Your lesson room is ready. It is under Your music.'), findsOneWidget);
      expect(controller.rooms.length, before + 2);

      final me = repository.currentUserId;
      final classRoom = controller.rooms.firstWhere((room) => room.name == 'Jazz studio');
      final own = controller.rooms.firstWhere((room) => room.name == 'Jazz studio · Taylor');
      expect(classRoom.members.firstWhere((member) => member.userId == me).role, RoomRole.viewer);
      expect(classRoom.members.firstWhere((member) => member.role == RoomRole.owner).displayName, 'Maria');
      expect(classRoom.canEditSongs(me), isFalse);
      expect(own.members.length, 2);
      expect(own.members.firstWhere((member) => member.userId == me).role, RoomRole.editor);
      expect(own.canEditSongs(me), isTrue);

      // The class room is not a lesson room: a take there is not "sent to
      // Maria", and nobody is ever offered one.
      expect(await repository.isLessonRoom(classRoom.id), isFalse);
      expect(await repository.isLessonRoom(own.id), isTrue);

      // Again, with the whole link: the same two rooms.
      await useCode(lessonLink('0123456789ab'));
      expect(controller.rooms.length, before + 2);
    });

    testWidgets('in the class room a viewer listens, and is not offered a take', (tester) async {
      final repository = classOffered();
      final own = await repository.joinLessonLink('0123456789ab');
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      final classRoom = controller.rooms.firstWhere((room) => room.name == 'Jazz studio');

      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Widget takes(String roomId) => BetaScope(
            controller: controller,
            child: MaterialApp(
              theme: CoLabRoomTheme.dark(),
              home: SongLayersScreen(
                roomId: roomId,
                projectId: 'song-1',
                songTitle: 'Autumn Leaves',
                layerService: _NoTakes(),
                analysisService: _NoAnalysis(),
              ),
            ),
          );

      await tester.pumpWidget(takes(classRoom.id));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('layers_record_button')), findsNothing);
      expect(find.text('You can listen in this room, not record.'), findsOneWidget);
      expect(find.text('Recorded it elsewhere? Add a file'), findsNothing);

      // In their own room the same person is an editor, and records.
      await tester.pumpWidget(takes(own));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('layers_record_button')), findsOneWidget);
      expect(find.text('You can listen in this room, not record.'), findsNothing);
    });
  });
}

class _NoTakes extends SongLayerService {
  _NoTakes() : super(client: null);

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => const <SharedLayer>[];

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _NoAnalysis extends SongAnalysisService {
  _NoAnalysis() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async => const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
}
