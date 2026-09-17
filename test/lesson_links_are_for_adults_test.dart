import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/lesson_link.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/lessons/lesson_poster.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Lesson links are for adults, for now.
///
/// Every Musician, Same Song, 17 September 2026: adult students first, and
/// lesson links for people 18 and over until there is a guardian step to put
/// 13 to 17 behind. A teacher's QR code on a studio wall is scanned by
/// whoever walks past, so it is the one place in this app where a stranger's
/// age had to be somebody's business. The server decides (0139); these are
/// the four answers it can give, on both ends of a link.
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

  Future<void> useCode(WidgetTester tester, String code) async {
    await tester.tap(find.byKey(const Key('inbox_use_code')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, code);
    await tester.pump();
    await tester.tap(find.byKey(const Key('join_code_submit')));
    await tester.pumpAndSettle();
  }

  Future<void> sayBornIn(WidgetTester tester, {required int year, required int month}) async {
    tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('birth_month'))).onChanged!(month);
    tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('birth_year'))).onChanged!(year);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('birth_save')));
    await tester.pumpAndSettle();
  }

  InMemoryMusicRepository lessonOffered({CallStanding? standing}) {
    final repository = InMemoryMusicRepository.seeded()
      ..offerLesson(code: '0123456789ab', title: 'Guitar lessons', teacherName: 'Maria');
    if (standing != null) repository.callStanding = standing;
    return repository;
  }

  group("opening somebody's lesson link", () {
    testWidgets('nobody who has said when they were born is asked again', (tester) async {
      final repository = lessonOffered(standing: CallStanding.adult);
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      await useCode(tester, '0123-4567-89AB');

      expect(find.text('One question first'), findsNothing);
      expect(controller.rooms.length, before + 1);
      expect(find.text('Your lesson room is ready. It is under Your music.'), findsOneWidget);
    });

    testWidgets('an adult who has not is asked, and then it opens', (tester) async {
      final repository = lessonOffered();
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      await useCode(tester, '0123-4567-89AB');
      // The question calls ask, saving the answer calls save.
      expect(find.text('One question first'), findsOneWidget);
      expect(controller.rooms.length, before, reason: 'nothing opens before there is an answer');

      await sayBornIn(tester, year: 1990, month: 5);

      expect(await repository.myCallStanding(), CallStanding.adult);
      expect(controller.rooms.length, before + 1);
      expect(controller.rooms.any((room) => room.name.startsWith('Guitar lessons')), isTrue);
    });

    testWidgets('somebody under 18 is told once, and asked nothing more', (tester) async {
      final repository = lessonOffered();
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      await useCode(tester, '0123-4567-89AB');
      await sayBornIn(tester, year: DateTime.now().year - 16, month: 1);

      expect(await repository.myCallStanding(), CallStanding.minor);
      expect(find.text(lessonLinksAreForAdults), findsOneWidget);
      expect(find.text('One question first'), findsNothing, reason: 'no second try at the question');
      expect(controller.rooms.length, before);
    });

    testWidgets('a 16-year-old who has already said is told straight away', (tester) async {
      final repository = lessonOffered(standing: CallStanding.minor);
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      await useCode(tester, '0123-4567-89AB');

      expect(find.text('One question first'), findsNothing);
      expect(find.text(lessonLinksAreForAdults), findsOneWidget);
      expect(controller.rooms.length, before);
    });

    testWidgets('an account that answered under 13 hears no age at all', (tester) async {
      // 0138's rule, and the FTC's reason for it: nothing a second try could
      // be aimed at.
      final repository = lessonOffered(standing: CallStanding.refused);
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      await useCode(tester, '0123-4567-89AB');

      expect(find.text(lessonLinksClosedOnThisAccount), findsOneWidget);
      expect(find.text(lessonLinksAreForAdults), findsNothing, reason: 'no age to aim a second try at');
      expect(find.text('One question first'), findsNothing);
      expect(controller.rooms.length, before);
    });

    testWidgets('closing the question joins nothing, and says nothing', (tester) async {
      final repository = lessonOffered();
      final controller = await boot(tester, repository, const NotificationsScreen());
      final before = controller.rooms.length;

      await useCode(tester, '0123-4567-89AB');
      expect(find.text('One question first'), findsOneWidget);

      // The way a sheet is closed: back, or a tap outside it.
      Navigator.of(tester.element(find.text('One question first'))).pop();
      await tester.pumpAndSettle();

      expect(controller.rooms.length, before);
      expect(await repository.myCallStanding(), CallStanding.unknown);
      expect(find.text('Your lesson room is ready. It is under Your music.'), findsNothing);
      expect(find.byType(SnackBar), findsNothing, reason: 'nothing happened, so nothing is said');
    });
  });

  group("the teacher's side", () {
    testWidgets('the screen says who the link is for, before and after there is one', (tester) async {
      final repository = InMemoryMusicRepository.seeded()..callStanding = CallStanding.adult;
      await boot(tester, repository, LessonLinkScreen(repository: repository));

      expect(find.text(lessonLinksAreForStudents18AndOver), findsOneWidget);

      await tester.enterText(find.byKey(const Key('lesson_title')), 'Guitar lessons');
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lesson_qr')), findsOneWidget);
      expect(find.text(lessonLinksAreForStudents18AndOver), findsOneWidget);
    });

    test('the poster says it on the wall too', () async {
      final sheet = LessonPoster.sheet(title: 'Guitar', code: 'a1b2c3d4e5f6', teacher: 'Taylor');
      expect(_printed(sheet), contains('For students 18 and over'));

      // And it still lays out on both pages with the line on it.
      for (final format in <PdfPageFormat>[PdfPageFormat.a4, PdfPageFormat.letter]) {
        final bytes = await LessonPoster.document(
          title: 'Guitar',
          code: 'a1b2c3d4e5f6',
          teacher: 'Taylor',
          format: format,
        ).save();
        expect(bytes.length, greaterThan(1000));
      }
    });

    testWidgets('a teacher is asked when they were born, then gets their code', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, LessonLinkScreen(repository: repository));

      await tester.enterText(find.byKey(const Key('lesson_title')), 'Guitar lessons');
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();
      expect(find.text('One question first'), findsOneWidget);
      expect(await repository.myLessonLink(), isNull);

      await sayBornIn(tester, year: 1990, month: 5);

      expect(await repository.myLessonLink(), isNotNull);
      expect(find.byKey(const Key('lesson_qr')), findsOneWidget);
    });

    testWidgets('a teacher under 18 cannot make one, and is told plainly', (tester) async {
      final repository = InMemoryMusicRepository.seeded()..callStanding = CallStanding.minor;
      await boot(tester, repository, LessonLinkScreen(repository: repository));

      await tester.enterText(find.byKey(const Key('lesson_title')), 'Guitar lessons');
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();

      expect(find.text(lessonLinksAreForAdults), findsOneWidget);
      expect(find.byKey(const Key('lesson_qr')), findsNothing);
      expect(await repository.myLessonLink(), isNull);
    });

    testWidgets('closing the question makes no link, and says nothing', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await boot(tester, repository, LessonLinkScreen(repository: repository));

      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('One question first'))).pop();
      await tester.pumpAndSettle();

      expect(await repository.myLessonLink(), isNull);
      expect(find.byType(SnackBar), findsNothing);
      // And the button works again, rather than being left busy.
      expect(tester.widget<FilledButton>(find.byKey(const Key('lesson_make'))).onPressed, isNotNull);
    });
  });

  group('the preview repository says what the server says', () {
    test('every standing, on both ends of a link', () async {
      for (final standing in <CallStanding>[CallStanding.minor, CallStanding.refused]) {
        final repository = lessonOffered(standing: standing);
        final said = standing == CallStanding.minor
            ? lessonLinksAreForAdults
            : lessonLinksClosedOnThisAccount;
        await expectLater(
          repository.joinLessonLink('0123456789ab'),
          throwsA(predicate<Object>((error) => '$error' == said)),
        );
        await expectLater(
          repository.openLessonLink('Guitar lessons'),
          throwsA(predicate<Object>((error) => '$error' == said)),
        );
      }

      final unasked = lessonOffered();
      await expectLater(
        unasked.joinLessonLink('0123456789ab'),
        throwsA(isA<LessonNeedsABirthMonth>()),
      );
      await expectLater(
        unasked.openLessonLink('Guitar lessons'),
        throwsA(isA<LessonNeedsABirthMonth>()),
      );
    });

    test('a link that was turned off says so, whatever the age', () async {
      // The order 0139 keeps: nobody is asked for a birth month to open
      // something that was never going to open.
      final repository = InMemoryMusicRepository.seeded();
      await expectLater(
        repository.joinLessonLink('ffffffffffff'),
        throwsA(predicate<Object>((error) => '$error'.contains('turned off'))),
      );
    });
  });
}

/// Every line of words on a laid-out poster. A pdf Text is a RichText with
/// one span, and the page is a tree of single- and multi-child widgets.
Iterable<String> _printed(pw.Widget widget) {
  final found = <String>[];
  void walk(pw.Widget node) {
    if (node is pw.RichText) {
      final span = node.text;
      if (span is pw.TextSpan && span.text != null) found.add(span.text!);
    }
    final children = switch (node) {
      pw.SingleChildWidget(:final child?) => <pw.Widget>[child],
      pw.MultiChildWidget(:final children) => children,
      _ => const <pw.Widget>[],
    };
    children.forEach(walk);
  }

  walk(widget);
  return found;
}
