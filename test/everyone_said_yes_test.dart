import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/workspace/audience_dial.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Everyone on it says yes before it goes out.
///
/// Every Musician, Same Song, 17 September 2026, and the decision the audit
/// left as CO2: a room owner could put a band song on the Open Mic and every
/// shared take on it became public on their say-so, with nobody asked and
/// nobody told. Now everybody with a part on it is asked, in one plain
/// notification answered in one tap; the song waits until they have all
/// answered; anybody can pull their own part afterwards; and the owner sees
/// who has answered in words, never a count.
///
/// The seeded song has Jess's bass on it, which is why Taylor's press alone
/// puts nothing up. The fake can be either of them in turn, so both ends of
/// the question are read from one repository.
void main() {
  group('the repository', () {
    test('the owner presses, the bandmate is asked, and nothing goes up',
        () async {
      final repo = InMemoryMusicRepository.seeded();
      await repo.putOnOpenMic('song-1');

      final audience = (await repo.songAudience('song-1'))!;
      expect(audience.onOpenMic, isFalse);
      expect(audience.reach, isNot(SongReach.anyone));
      // In words, and the owner's own yes is recorded by the act.
      expect(audience.answers.map((a) => a.inWords),
          <String>['Jess has not answered yet']);
      expect(audience.waitingOn, <String>['Jess']);
      expect(audience.myAnswer, PartAnswer.yes);

      // One plain notification, to Jess, saying what it is about.
      final asked = repo.told.where((t) => t.to == 'preview-jess').toList();
      expect(asked, hasLength(1));
      expect(asked.single.notification.type, NotificationType.partQuestion);
      expect(asked.single.notification.title,
          'Taylor wants to put Midnight Signal in front of everybody');
      expect(asked.single.notification.body,
          startsWith('With your bass on it.'));
      expect(asked.single.notification.projectId, 'song-1');

      // Pressing again nags nobody.
      await repo.putOnOpenMic('song-1');
      expect(repo.told.where((t) => t.to == 'preview-jess'), hasLength(1));
      expect((await repo.songAudience('song-1'))!.onOpenMic, isFalse);
    });

    test('the yes is theirs, and the song goes up on the next press',
        () async {
      final repo = InMemoryMusicRepository.seeded();
      await repo.putOnOpenMic('song-1');

      repo.currentUserId = 'preview-jess';
      final questions = await repo.partQuestionsForMe();
      expect(questions, hasLength(1));
      expect(questions.single.projectId, 'song-1');
      expect(questions.single.parts, <String>['bass']);
      expect(questions.single.askedByName, 'Taylor');
      expect(questions.single.headline,
          'Taylor wants to put Midnight Signal in front of everybody');

      await repo.answerForMyPart('song-1', yes: true);
      expect(await repo.partQuestionsForMe(), isEmpty);

      // The owner is told, in words.
      final owner = repo.told.where((t) => t.to == 'preview-user').toList();
      expect(owner, hasLength(1));
      expect(owner.single.notification.type, NotificationType.projectUpdate);
      expect(owner.single.notification.title, 'Jess said yes');
      expect(owner.single.notification.body,
          'Midnight Signal can go out with their bass on it.');

      // Nothing went up on the yes alone: the owner decides the moment.
      repo.currentUserId = 'preview-user';
      var audience = (await repo.songAudience('song-1'))!;
      expect(audience.onOpenMic, isFalse);
      expect(audience.answers.map((a) => a.inWords), <String>['Jess said yes']);

      await repo.putOnOpenMic('song-1');
      audience = (await repo.songAudience('song-1'))!;
      expect(audience.onOpenMic, isTrue);
      expect(audience.reach, SongReach.anyone);
    });

    test("the owner's answer touches only the owner's part", () async {
      final repo = await _upWithJessOnIt();
      await repo.answerForMyPart('song-1', yes: false);

      final audience = (await repo.songAudience('song-1'))!;
      expect(audience.myAnswer, PartAnswer.no);
      expect(audience.answers.single.answer, PartAnswer.yes);
      // Jess's part alone keeps it up.
      expect(audience.onOpenMic, isTrue);
    });

    test('pulling a part takes it off, and the song stays up without it',
        () async {
      final repo = await _upWithJessOnIt();
      repo.currentUserId = 'preview-jess';
      await repo.answerForMyPart('song-1', yes: false);

      final owner = repo.told
          .where((t) => t.to == 'preview-user')
          .map((t) => t.notification)
          .toList();
      expect(owner.last.title, 'Jess is leaving their part out');
      expect(owner.last.body, 'Midnight Signal is still up, without their bass.');

      repo.currentUserId = 'preview-user';
      final audience = (await repo.songAudience('song-1'))!;
      expect(audience.onOpenMic, isTrue);
      expect(audience.answers.map((a) => a.inWords),
          <String>['Jess is leaving their part out']);
    });

    test('a song with nothing left to hear comes down', () async {
      final repo = InMemoryMusicRepository.seeded();
      final room = (await repo.loadRooms()).first;
      final song = await repo.createSong(room: room, title: 'Only Jess');
      repo.recordTake(song.id, part: 'vocal', by: 'preview-jess');

      await repo.putOnOpenMic(song.id);
      repo.currentUserId = 'preview-jess';
      await repo.answerForMyPart(song.id, yes: true);
      repo.currentUserId = 'preview-user';
      await repo.putOnOpenMic(song.id);
      expect((await repo.songAudience(song.id))!.onOpenMic, isTrue);

      repo.currentUserId = 'preview-jess';
      await repo.answerForMyPart(song.id, yes: false);
      repo.currentUserId = 'preview-user';
      expect((await repo.songAudience(song.id))!.onOpenMic, isFalse);
      expect(
        repo.told.last.notification.body,
        'Nothing was left to hear on Only Jess, so it came down.',
      );
    });

    test('a take shared onto a song already out asks its own player',
        () async {
      final repo = await _upWithJessOnIt();
      repo.recordTake('song-1', part: 'keys', by: 'preview-jess');

      final asked = repo.told
          .where((t) => t.to == 'preview-jess')
          .map((t) => t.notification)
          .toList();
      expect(asked.last.type, NotificationType.partQuestion);
      expect(asked.last.title, 'Your keys on Midnight Signal');

      // Waiting again, and the song is still up: the bass is out there, the
      // keys stay with the room until Jess says so.
      final audience = (await repo.songAudience('song-1'))!;
      expect(audience.onOpenMic, isTrue);
      expect(audience.answers.single.answer, PartAnswer.waiting);

      repo.currentUserId = 'preview-jess';
      final questions = await repo.partQuestionsForMe();
      expect(questions.single.parts, <String>['keys']);
    });

    test('nobody else can answer for you, and an editor cannot put it up',
        () async {
      final repo = InMemoryMusicRepository.seeded();
      await repo.putOnOpenMic('song-1');

      repo.currentUserId = 'preview-nobody';
      await expectLater(
        repo.answerForMyPart('song-1', yes: true),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', '22023')),
      );

      repo.currentUserId = 'preview-jess';
      await expectLater(
        repo.putOnOpenMic('song-1'),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', '42501')),
      );
    });

    test('this build knows the word, and the words are plain', () {
      expect(notificationTypeFromSql('part_question'),
          NotificationType.partQuestion);
      expect(PartAnswer.fromWireName('yes'), PartAnswer.yes);
      expect(PartAnswer.fromWireName('no'), PartAnswer.no);
      expect(PartAnswer.fromWireName(null), PartAnswer.waiting);
      expect(PartAnswer.fromWireName('maybe'), PartAnswer.waiting);

      expect(PartQuestion.partsInWords(<String>['bass']), 'bass');
      expect(PartQuestion.partsInWords(<String>['bass', 'vocal']),
          'bass and vocal');
      expect(PartQuestion.partsInWords(<String>['bass', 'keys', 'vocal']),
          'bass, keys and vocal');
      expect(PartQuestion.partsInWords(<String>['other']), 'part');
      expect(PartQuestion.partsInWords(<String>[]), 'part');

      expect(namesInASentence(<String>['Jess']), 'Jess');
      expect(namesInASentence(<String>['Jess', 'Dev']), 'Jess and Dev');
      expect(namesInASentence(<String>['Jess', 'Dev', 'Mara']),
          'Jess, Dev and Mara');
    });
  });

  group('the inbox', () {
    testWidgets('the question is a card, answered in one tap', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await repo.putOnOpenMic('song-1');
      repo.currentUserId = 'preview-jess';

      final controller = MusicBetaController(repo);
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: const NotificationsScreen(),
        ),
      ));
      await _pump(tester);

      expect(
        find.text('Taylor wants to put Midnight Signal in front of everybody'),
        findsOneWidget,
      );
      expect(find.textContaining('With your bass on it.'), findsOneWidget);
      // No deadline, no tally, no bar: not a digit on the card.
      expect(
        find.descendant(
          of: find.byKey(const Key('part_question_song-1')),
          matching: find.textContaining(RegExp(r'\d')),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('part_question_yes')));
      await _pump(tester);

      expect(find.byKey(const Key('part_question_song-1')), findsNothing);
      expect(find.text('Your part goes out with Midnight Signal.'),
          findsOneWidget);
      expect((await repo.partQuestionsForMe()), isEmpty);
    });

    testWidgets('leaving a part out is a real answer', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await repo.putOnOpenMic('song-1');
      repo.currentUserId = 'preview-jess';

      final controller = MusicBetaController(repo);
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: const NotificationsScreen(),
        ),
      ));
      await _pump(tester);

      await tester.tap(find.byKey(const Key('part_question_no')));
      await _pump(tester);

      expect(find.byKey(const Key('part_question_song-1')), findsNothing);
      // The owner hears no rather than nothing, and can still put it up
      // without this part.
      expect(
        repo.told.last.notification.title,
        'Jess is leaving their part out',
      );
      repo.currentUserId = 'preview-user';
      await repo.putOnOpenMic('song-1');
      expect((await repo.songAudience('song-1'))!.onOpenMic, isTrue);
    });
  });

  group('the sheet', () {
    testWidgets('says who has answered in words, never a count',
        (tester) async {
      SongAudienceChoice? picked;
      await _openDial(
        tester,
        audience: _audience(
          answers: const <PersonsAnswer>[
            PersonsAnswer(id: 'a', name: 'Jess', answer: PartAnswer.waiting),
            PersonsAnswer(id: 'b', name: 'Dev', answer: PartAnswer.yes),
            PersonsAnswer(id: 'c', name: 'Mara', answer: PartAnswer.no),
          ],
          myAnswer: PartAnswer.yes,
        ),
        onPicked: (choice) => picked = choice,
      );

      expect(find.text('Jess has not answered yet'), findsOneWidget);
      expect(find.text('Dev said yes'), findsOneWidget);
      expect(find.text('Mara is leaving their part out'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\d of \d')), findsNothing);

      // Your own part comes off from the same place.
      expect(find.text('Take my part off it'), findsOneWidget);
      await tester.tap(find.byKey(const Key('audience_my_part')));
      await tester.pumpAndSettle();
      expect(picked, SongAudienceChoice.takeMyPartOff);
    });

    testWidgets('a pulled part can go back on, and an unasked one has no button',
        (tester) async {
      SongAudienceChoice? picked;
      await _openDial(
        tester,
        audience: _audience(myAnswer: PartAnswer.no),
        onPicked: (choice) => picked = choice,
      );
      expect(find.text('Put my part on it'), findsOneWidget);
      await tester.tap(find.byKey(const Key('audience_my_part')));
      await tester.pumpAndSettle();
      expect(picked, SongAudienceChoice.putMyPartOn);

      await _openDial(tester, audience: _audience(), onPicked: (_) {});
      expect(find.byKey(const Key('audience_my_part')), findsNothing);
      expect(find.text('EVERYONE ON IT'), findsNothing);
    });
  });

  group('the workspace', () {
    testWidgets('a press that waits says who it is waiting on',
        (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = InMemoryMusicRepository.seeded();
      final controller = MusicBetaController(repo);
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: const SongWorkspaceScreen(projectId: 'song-1'),
        ),
      ));
      await _pump(tester);

      await tester.tap(find.byKey(const Key('song_audience_dial')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('audience_open_mic_toggle')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('whose_song_ours')));
      await _pump(tester);
      expect(find.text('Put Midnight Signal on the Open Mic?'), findsOneWidget);
      await tester.tap(find.text('Put it up'));
      await _pump(tester);

      expect(
        find.text('Asked Jess. It goes up once everybody on it has answered.'),
        findsOneWidget,
      );
      expect(find.text('Midnight Signal is on the Open Mic.'), findsNothing);
      expect((await repo.songAudience('song-1'))!.onOpenMic, isFalse);
    });
  });
}

/// The seeded song, up, with Jess's bass on it by her own yes.
Future<InMemoryMusicRepository> _upWithJessOnIt() async {
  final repo = InMemoryMusicRepository.seeded();
  await repo.putOnOpenMic('song-1');
  repo.currentUserId = 'preview-jess';
  await repo.answerForMyPart('song-1', yes: true);
  repo.currentUserId = 'preview-user';
  await repo.putOnOpenMic('song-1');
  expect((await repo.songAudience('song-1'))!.onOpenMic, isTrue);
  return repo;
}

SongAudience _audience({
  List<PersonsAnswer> answers = const <PersonsAnswer>[],
  PartAnswer? myAnswer,
}) =>
    SongAudience(
      reach: SongReach.anyone,
      listeners: const <SongListener>[],
      onOpenMic: true,
      roomName: 'The Basement',
      roomIcon: '🎸',
      answers: answers,
      myAnswer: myAnswer,
    );

Future<void> _openDial(
  WidgetTester tester, {
  required SongAudience audience,
  required void Function(SongAudienceChoice?) onPicked,
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            onPicked(await showAudienceSheet(
              context,
              audience: audience,
              songTitle: 'Midnight Signal',
            ));
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Pumped rather than settled: the workspace joins a cowork stream when it
/// opens, and the inbox's snackbars have their own timers.
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
