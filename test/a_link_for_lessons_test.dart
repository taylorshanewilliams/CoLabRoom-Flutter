import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/lessons/lesson_poster.dart';
import 'package:colabroom/features/messages/messages_screen.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:colabroom/widgets/qr_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';

/// A link for lessons.
///
/// Taylor, 16 Sep 2026: teachers "can email out or share a qr code or
/// whatever, and the student could join right into their room." One code
/// for a studio wall, and a room of their own with the teacher for every
/// student who opens it -- never a room shared with other students.
void main() {
  group('the link and the code', () {
    test('the link opens the web app with the lesson on it', () {
      expect(
        lessonLink('A1B2C3D4E5F6'),
        'https://app.colabroom.com/?lesson=a1b2c3d4e5f6&from=lesson',
      );
      expect(lessonCodeFrom(Uri.parse(lessonLink('a1b2c3d4e5f6'))), 'a1b2c3d4e5f6');
      expect(lessonCodeFrom(Uri.parse('https://app.colabroom.com/?lesson=nope')), isNull);
      expect(lessonCodeFrom(Uri.parse('https://app.colabroom.com/?invite=a1b2c3d4e5f6')), isNull);
    });

    test('a code is read however somebody typed or pasted it', () {
      expect(lessonCodeFromText('a1b2-c3d4-e5f6'), 'a1b2c3d4e5f6');
      expect(lessonCodeFromText(' A1B2 C3D4 E5F6 '), 'a1b2c3d4e5f6');
      expect(lessonCodeFromText(lessonLink('a1b2c3d4e5f6')), 'a1b2c3d4e5f6');
      // An invitation's code is much longer and is not a lesson.
      expect(lessonCodeFromText('0123456789abcdef0123456789abcdef0123'), isNull);
      expect(lessonCodeFromText('hello'), isNull);
    });

    test('said the way it is read off a wall', () {
      expect(lessonCodeSaid('a1b2c3d4e5f6'), 'a1b2-c3d4-e5f6');
    });

    test('the poster is a one-page PDF, whatever somebody typed', () async {
      final bytes = await LessonPoster.document(
        title: 'Guitar lessons 🎸',
        code: 'a1b2c3d4e5f6',
        teacher: 'Taylor',
      ).save();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(LessonPoster.printable('Guitar lessons 🎸'), 'Guitar lessons ');
      expect(LessonPoster.printable('José'), 'José');
      // No name, no "with"; and it still lays out on the shorter US page.
      final anonymous = await LessonPoster.document(
        title: '',
        code: 'a1b2c3d4e5f6',
        format: PdfPageFormat.letter,
      ).save();
      expect(anonymous.length, greaterThan(1000));
    });

    test('the QR code is drawn inside its square', () {
      final modules = qrModules(lessonLink('a1b2c3d4e5f6'), 200).toList();
      expect(modules.length, greaterThan(100));
      for (final module in modules) {
        expect(module.left, greaterThanOrEqualTo(0));
        expect(module.top, greaterThanOrEqualTo(0));
        expect(module.left + module.width, lessThanOrEqualTo(200.001));
        expect(module.top + module.height, lessThanOrEqualTo(200.001));
      }
    });
  });

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

  group("the teacher's side", () {
    testWidgets('one question, then the code: QR, typed code, share, copy, off', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await boot(tester, repository, LessonLinkScreen(repository: repository));
      expect(find.text('One code for all your students'), findsOneWidget);
      expect(find.byKey(const Key('lesson_qr')), findsNothing);

      await tester.enterText(find.byKey(const Key('lesson_title')), 'Guitar lessons');
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lesson_qr')), findsOneWidget);
      expect(find.text('Guitar lessons'), findsOneWidget);
      expect(find.text('Nobody has joined yet'), findsOneWidget);
      expect(find.text('a1b2-c3d4-e5f6'), findsOneWidget);
      expect(find.byType(QrCode), findsOneWidget);
      expect(find.byKey(const Key('lesson_poster')), findsOneWidget);

      await tester.tap(find.byKey(const Key('lesson_copy')));
      await tester.pump();
      expect(copied, <String>[lessonLink('a1b2c3d4e5f6')]);
      expect(find.text('Link copied. Paste it into an email or a text.'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('lesson_close')),
        200,
        scrollable: find
            .descendant(of: find.byKey(const Key('lesson_link_list')), matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.byKey(const Key('lesson_close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lesson_close_confirm')));
      await tester.pumpAndSettle();
      expect(await repository.myLessonLink(), isNull);
      expect(find.text('One code for all your students'), findsOneWidget);
    });

    testWidgets('fits a small phone with large text', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.openLessonLink('Beginner guitar and songwriting lessons');
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: 1.3,
            maxScaleFactor: 1.3,
            child: LessonLinkScreen(repository: repository),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('lesson_qr')), findsOneWidget);
    });

    testWidgets('found beside starting a room, in Messages', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, const MessagesScreen());
      await tester.tap(find.byKey(const Key('messages_new')));
      await tester.pumpAndSettle();
      expect(find.text('Teach: a lesson link'), findsOneWidget);
      await tester.tap(find.byKey(const Key('messages_new_lessons')));
      await tester.pumpAndSettle();
      expect(find.byType(LessonLinkScreen), findsOneWidget);
    });
  });

  group("the student's side", () {
    testWidgets('a lesson code in Join with a code makes their room, and only once', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerLesson(code: '0123456789ab', title: 'Guitar lessons', teacherName: 'Maria');
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      Future<void> useCode(String code) async {
        await tester.tap(find.byKey(const Key('inbox_use_code')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, code);
        await tester.tap(find.byKey(const Key('join_code_submit')));
        await tester.pumpAndSettle();
      }

      await useCode('0123-4567-89AB');
      expect(find.text('Your lesson room is ready. It is under Your music.'), findsOneWidget);
      expect(controller.rooms.length, before + 1);
      final room = controller.rooms.firstWhere((each) => each.name.startsWith('Guitar lessons'));
      expect(room.members.map((member) => member.role), containsAll(<RoomRole>[RoomRole.owner, RoomRole.editor]));

      // The whole link pasted in gives back the same room.
      await useCode(lessonLink('0123456789ab'));
      expect(controller.rooms.length, before + 1);
    });

    testWidgets("a teacher's own code says so rather than making a room", (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.openLessonLink('Voice');
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;
      await tester.tap(find.byKey(const Key('inbox_use_code')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'a1b2-c3d4-e5f6');
      await tester.tap(find.byKey(const Key('join_code_submit')));
      await tester.pumpAndSettle();
      expect(controller.rooms.length, before);
      expect(find.textContaining('your own lesson link'), findsOneWidget);
    });
  });
}
