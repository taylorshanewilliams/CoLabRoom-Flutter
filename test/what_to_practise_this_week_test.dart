import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/domain/song_brief.dart';
import 'package:colabroom/features/lessons/sending_a_song.dart';
import 'package:colabroom/features/lessons/what_to_practise.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What to practise, and where it is.
///
/// Every Musician, Same Song, 17 September 2026, slice 20: the brief that
/// rides with a song a teacher sends (0150). A passage, a speed, a few things
/// the teacher is listening for, and when by, in words.
///
/// Four things have to hold. Only the teacher of a lesson can say it, and the
/// student who edits that same room cannot. It lands on the student's Home as
/// one card whose verb opens Perform on that passage at that speed. Nothing
/// anybody reads has a number to be measured by, a date, or a countdown. And
/// nothing anywhere tells the teacher whether it was opened.

final RegExp _digit = RegExp('[0-9]');

const BriefToSend _aBrief = BriefToSend(
  passage: 'Bars 1–16',
  startMs: 0,
  endMs: 32000,
  rate: 0.75,
  listeningFor: <String>['the breath before “credimi”', 'legato through the turn'],
  dueWords: 'before Thursday',
);

/// Pumped rather than settled: the workspace joins a cowork stream when it
/// opens, and every other test on this screen pumps for the same reason.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// A teacher with a studio song and two students, as slice 19's tests make
/// one.
Future<({InMemoryMusicRepository repository, String songId, List<String> lessons})> _aTeacher({
  SongOrigin origin = SongOrigin.ours,
}) async {
  final repository = InMemoryMusicRepository.seeded();
  final studio = (await repository.loadRooms()).firstWhere((room) => room.name == 'Acoustic Ideas');
  final song = await repository.createSong(room: studio, title: 'Caro mio ben');
  await repository.addContribution(project: song, body: 'Caro mio ben');
  await repository.setSongOrigin(song.id, origin);
  return (
    repository: repository,
    songId: song.id,
    lessons: <String>[
      repository.teachALesson(studentId: 'student-1', studentName: 'Jess').id,
      repository.teachALesson(studentId: 'student-2', studentName: 'Sam').id,
    ],
  );
}

Future<SongProject> _copyIn(InMemoryMusicRepository repository, String roomId) async =>
    (await repository.loadRooms()).firstWhere((room) => room.id == roomId).projects.single;

/// This person as the student: a lesson somebody else teaches, with a song
/// in it that the teacher briefed. The in-memory world holds one person at a
/// time, so the teacher's half is done as the teacher and then handed back.
Future<({InMemoryMusicRepository repository, SongProject song, SongBrief brief})> _aStudent({
  BriefToSend brief = _aBrief,
}) async {
  final repository = InMemoryMusicRepository.seeded()
    ..callStanding = CallStanding.adult
    ..offerLesson(code: '0123456789ab', title: 'Voice lessons', teacherName: 'Maria');
  final lessonId = await repository.joinLessonLink('0123456789ab');
  final lesson = (await repository.loadRooms()).firstWhere((room) => room.id == lessonId);

  repository.currentUserId = 'teacher-maria';
  final song = await repository.createSong(room: lesson, title: 'Caro mio ben');
  await repository.setSongBriefs(<String>[song.id], brief);
  repository.currentUserId = 'preview-user';

  return (
    repository: repository,
    song: song,
    brief: (await repository.mySongBriefs()).single,
  );
}

Future<MusicBetaController> _home(WidgetTester tester, InMemoryMusicRepository repository) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  SetAside.resetForTesting();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
  await tester.pump(const Duration(milliseconds: 200));
  return controller;
}

/// What the last pumped brief sheet was closed with.
BriefChoice? _chosen;

Future<void> _pumpBriefSheet(
  WidgetTester tester, {
  required SongToPointAt song,
  BriefToSend? initial,
}) async {
  _chosen = null;
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open_brief'),
          onPressed: () async {
            _chosen = await showBriefSheet(context, song: song, initial: initial);
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open_brief')));
  await tester.pumpAndSettle();
}

const List<StructureSection> _sections = <StructureSection>[
  StructureSection(startMs: 0, endMs: 8000, label: 'Verse'),
  StructureSection(startMs: 8000, endMs: 16000, label: 'Chorus'),
];

/// Eight bars of two seconds each.
const List<int> _downbeats = <int>[0, 2000, 4000, 6000, 8000, 10000, 12000, 14000];

/// Every word on screen that is not the name of a part or a speed. Those are
/// on chips, and they are names of musical things ("Bars 9–12", "70%") rather
/// than anything said about a person.
String _wordsOffTheChips(WidgetTester tester) {
  final onChips = tester
      .widgetList<Text>(find.descendant(of: find.byType(ChoiceChip), matching: find.byType(Text)))
      .toSet();
  return tester
      .widgetList<Text>(find.byType(Text))
      .where((text) => !onChips.contains(text))
      .map((text) => text.data ?? '')
      .join(' | ');
}

void main() {
  group('what is said', () {
    test('the passage, the speed and when by, in one line', () {
      expect(briefToSendSaid(_aBrief), 'Bars 1–16 at ¾ · before Thursday');
      expect(
        briefToSendSaid(const BriefToSend(passage: 'The whole song', rate: 1)),
        'The whole song',
      );
      // When by is the teacher's own words, said as they typed them.
      expect(
        briefToSendSaid(const BriefToSend(passage: 'Chorus', rate: 1, dueWords: '  In time for the lesson ')),
        'Chorus · In time for the lesson',
      );
    });

    test('the student reads whose words they are, and the teacher that they are their own', () async {
      final student = await _aStudent();
      expect(briefFrom(student.brief, me: 'preview-user'), 'From Maria');
      expect(briefFrom(student.brief, me: 'teacher-maria'), 'What you asked for');
    });

    test('a brief for copies the students already had says so instead of "Already sent."', () {
      expect(sentSaid(0, briefed: true),
          'They have the song already. What to practise is on their Home.');
      // A song that went out is the news, brief or no brief.
      expect(sentSaid(2, briefed: true), 'Sent to 2 students');
      expect(sentSaid(0), 'Already sent.');
    });

    test('what Perform opens on is the passage and the speed, with nothing timed', () async {
      final student = await _aStudent();
      final part = student.brief.part;
      expect(part.label, 'Bars 1–16');
      expect(part.startMs, 0);
      expect(part.endMs, 32000);
      expect(part.rate, 0.75);
      expect(part.seconds, 0);
    });
  });

  group('who may say it', () {
    test('each ticked lesson gets the brief on its own copy', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      final took = await repository.briefStudents(
        projectId: teacher.songId,
        roomIds: teacher.lessons,
        brief: _aBrief,
      );
      final jess = await _copyIn(repository, teacher.lessons[0]);
      final sam = await _copyIn(repository, teacher.lessons[1]);
      expect(took.toSet(), <String>{jess.id, sam.id});

      final briefs = await repository.mySongBriefs();
      expect(briefs.map((brief) => brief.projectId).toSet(), <String>{jess.id, sam.id});
      final forJess = briefs.firstWhere((brief) => brief.projectId == jess.id);
      expect(forJess.studentId, 'student-1');
      expect(forJess.teacherId, 'preview-user');
      expect(forJess.passage, 'Bars 1–16');
      expect(forJess.rate, 0.75);
      expect(forJess.listeningFor, _aBrief.listeningFor);
      expect(forJess.dueWords, 'before Thursday');
      // The original is not a copy of itself, and takes nothing.
      expect(briefs.any((brief) => brief.projectId == teacher.songId), isFalse);
    });

    test('a student cannot set a brief, on their own copy or anybody else\'s', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      await repository.briefStudents(projectId: teacher.songId, roomIds: teacher.lessons, brief: _aBrief);
      final jess = await _copyIn(repository, teacher.lessons[0]);
      final sam = await _copyIn(repository, teacher.lessons[1]);

      // Jess edits her lesson room, and can write on the copy in it. She is
      // still not the teacher of that lesson.
      repository.currentUserId = 'student-1';
      const easier = BriefToSend(passage: 'The whole song', rate: 1, dueWords: 'whenever');
      for (final song in <String>[jess.id, sam.id]) {
        await expectLater(
          repository.setSongBriefs(<String>[song], easier),
          throwsA(isA<NameConflict>().having((e) => e.message, 'message', 'That is not a lesson of yours.')),
        );
      }
      // The app's own door finds no copy of a copy, and sets nothing either.
      expect(
        await repository.briefStudents(projectId: jess.id, roomIds: teacher.lessons, brief: easier),
        isEmpty,
      );

      // She reads hers, as it was, and nobody else's.
      final hers = await repository.mySongBriefs();
      expect(hers.single.projectId, jess.id);
      expect(hers.single.passage, 'Bars 1–16');
      expect(hers.single.dueWords, 'before Thursday');
    });

    test('somebody who is neither of them reads nothing', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      await repository.briefStudents(projectId: teacher.songId, roomIds: teacher.lessons, brief: _aBrief);
      repository.currentUserId = 'somebody-else';
      expect(await repository.mySongBriefs(), isEmpty);
    });

    test('one song that is not in a lesson of theirs refuses the lot', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      final jess = await _copyIn(repository, teacher.lessons[0]);
      await expectLater(
        // The studio song is theirs, and is not in a lesson.
        repository.setSongBriefs(<String>[jess.id, teacher.songId], _aBrief),
        throwsA(isA<NameConflict>()),
      );
      expect(await repository.mySongBriefs(), isEmpty);
    });

    test('saying it again replaces what was said, under a new name', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      await repository.briefStudents(
          projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]], brief: _aBrief);
      final first = (await repository.mySongBriefs()).single;

      // The second week of the same piece: the song is not sent again, and
      // the brief still reaches the copy that is already there.
      expect(
        await repository.sendSongToStudents(projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]]),
        isEmpty,
      );
      await repository.briefStudents(
        projectId: teacher.songId,
        roomIds: <String>[teacher.lessons[0]],
        brief: const BriefToSend(passage: 'Bars 17–32', startMs: 32000, endMs: 64000, rate: 0.9),
      );
      final second = (await repository.mySongBriefs()).single;
      expect(second.projectId, first.projectId);
      expect(second.passage, 'Bars 17–32');
      expect(second.listeningFor, isEmpty);
      expect(second.dueWords, isNull);
      // A new name, so a card the student closed last week comes back.
      expect(second.id, isNot(first.id));
    });

    test('a lesson whose student has left is skipped, and a room with no copy takes nothing', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]]);
      await repository.removeRoomMember(roomId: teacher.lessons[0], userId: 'student-1');
      expect(
        await repository.briefStudents(projectId: teacher.songId, roomIds: teacher.lessons, brief: _aBrief),
        isEmpty,
      );
      expect(await repository.mySongBriefs(), isEmpty);
    });

    test('a few short phrases: tidied, and the first five kept', () async {
      final student = await _aStudent(
        brief: const BriefToSend(
          passage: 'Chorus',
          rate: 1,
          listeningFor: <String>['  one   thing ', '', 'two', 'three', 'four', 'five', 'six'],
          dueWords: '   ',
        ),
      );
      expect(student.brief.listeningFor, <String>['one thing', 'two', 'three', 'four', 'five']);
      expect(student.brief.dueWords, isNull);
    });

    test('a brief with no passage, or at no speed, is refused in words', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      final jess = await _copyIn(repository, teacher.lessons[0]);
      await expectLater(
        repository.setSongBriefs(<String>[jess.id], const BriefToSend(passage: '  ', rate: 1)),
        throwsA(isA<NameConflict>()),
      );
      await expectLater(
        repository.setSongBriefs(<String>[jess.id], const BriefToSend(passage: 'Chorus', rate: 0)),
        throwsA(isA<NameConflict>()),
      );
    });
  });

  group('what a brief can point at', () {
    const recording = ReferenceTrack(
      projectId: 'song-1',
      fileId: 'file-1',
      storagePath: 'room/song/analysis/reference.mp3',
      displayName: 'reference.mp3',
      state: SongAnalysisState.ready,
      durationMs: 16000,
      downbeatsMs: _downbeats,
      structureSections: _sections,
    );

    test('parts and bars, where the recording travels with the copy', () {
      for (final origin in <SongOrigin>[SongOrigin.ours, SongOrigin.publicDomain]) {
        final song = whereToPoint(sheet: true, origin: origin, recording: recording);
        expect(song.wholeOnly, isNull);
        expect(song.sections, _sections);
        expect(song.downbeatsMs, _downbeats);
        expect(song.endMs, 16000);
      }
    });

    test("only the whole song for somebody else's, whose recording stays behind", () {
      // The copy of a cover has words and chords and nothing that plays
      // (0149), so Perform there opens whole at its own speed whatever a
      // card said.
      for (final origin in <SongOrigin?>[SongOrigin.cover, null]) {
        final song = whereToPoint(sheet: true, origin: origin, recording: recording);
        expect(song.wholeOnly, contains('The recording stays here'));
        expect(song.sections, isEmpty);
        expect(song.downbeatsMs, isEmpty);
      }
    });

    test('only the whole song before there is a sheet', () {
      expect(
        whereToPoint(sheet: false, origin: SongOrigin.ours, recording: null).wholeOnly,
        contains('no sheet yet'),
      );
      expect(
        whereToPoint(sheet: false, origin: SongOrigin.ours, recording: recording).wholeOnly,
        contains('no sheet yet'),
      );
    });
  });

  group('the sheet a teacher fills in', () {
    testWidgets('bars, a speed, what they are listening for, and when by', (tester) async {
      await _pumpBriefSheet(
        tester,
        song: const SongToPointAt(sections: _sections, downbeatsMs: _downbeats, endMs: 16000),
      );
      // The whole song to begin with, because it is the answer that is
      // never wrong, and at the song's own speed.
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('brief_part_0'))).selected, isTrue);

      await tester.tap(find.byKey(const Key('brief_part_bars')));
      await tester.pump();
      expect(find.text('Bars 1–4'), findsOneWidget);
      await tester.tap(find.byKey(const Key('brief_bar_last_later')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('brief_bar_first_later')));
      await tester.pump();
      expect(find.text('Bars 2–5'), findsOneWidget);

      await tester.tap(find.byKey(const Key('brief_rate_¾')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('brief_phrase')), 'the breath before “credimi”');
      await tester.tap(find.byKey(const Key('brief_phrase_add')));
      await tester.pump();
      expect(find.byKey(const Key('brief_phrase_0')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('brief_due')), 'Before Thursday');
      await tester.ensureVisible(find.byKey(const Key('brief_done')));
      await tester.tap(find.byKey(const Key('brief_done')));
      await tester.pumpAndSettle();

      final brief = _chosen!.brief!;
      expect(brief.passage, 'Bars 2–5');
      // Snapped to the downbeats either side, as Perform's own bars are.
      expect(brief.startMs, 2000);
      expect(brief.endMs, 10000);
      expect(brief.rate, 0.75);
      expect(brief.listeningFor, <String>['the breath before “credimi”']);
      expect(brief.dueWords, 'Before Thursday');
    });

    testWidgets('a part the sheet found, by its name', (tester) async {
      await _pumpBriefSheet(tester, song: const SongToPointAt(sections: _sections));
      // No grid to count on, so no bars are offered.
      expect(find.byKey(const Key('brief_part_bars')), findsNothing);
      await tester.tap(find.byKey(const Key('brief_part_2')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('brief_done')));
      await tester.tap(find.byKey(const Key('brief_done')));
      await tester.pumpAndSettle();
      final brief = _chosen!.brief!;
      expect(brief.passage, 'Chorus');
      expect(brief.startMs, 8000);
      expect(brief.endMs, 16000);
      expect(brief.rate, 1);
    });

    testWidgets('words still in the box when Done is pressed were meant', (tester) async {
      await _pumpBriefSheet(tester, song: const SongToPointAt(sections: _sections));
      await tester.enterText(find.byKey(const Key('brief_phrase')), 'land on the third');
      await tester.ensureVisible(find.byKey(const Key('brief_done')));
      await tester.tap(find.byKey(const Key('brief_done')));
      await tester.pumpAndSettle();
      expect(_chosen!.brief!.listeningFor, <String>['land on the third']);
    });

    testWidgets('a song that opens whole is offered the whole of it and no speed, and told why', (tester) async {
      await _pumpBriefSheet(
        tester,
        song: const SongToPointAt.wholeOnly('The recording stays here, so the whole of it is all there is.'),
      );
      expect(find.byKey(const Key('brief_part_0')), findsOneWidget);
      expect(find.byKey(const Key('brief_part_1')), findsNothing);
      expect(find.byKey(const Key('brief_part_bars')), findsNothing);
      expect(find.text('How fast'), findsNothing);
      expect(find.byKey(const Key('brief_whole_only')), findsOneWidget);
      // The words still work: what to listen for needs no recording.
      await tester.enterText(find.byKey(const Key('brief_due')), 'Before Thursday');
      await tester.ensureVisible(find.byKey(const Key('brief_done')));
      await tester.tap(find.byKey(const Key('brief_done')));
      await tester.pumpAndSettle();
      final brief = _chosen!.brief!;
      expect(brief.passage, 'The whole song');
      expect(brief.startMs, isNull);
      expect(brief.rate, 1);
      expect(brief.dueWords, 'Before Thursday');
    });

    testWidgets('it holds a few phrases and then stops asking, without counting them', (tester) async {
      await _pumpBriefSheet(tester, song: const SongToPointAt(sections: _sections));
      for (final phrase in <String>['breath', 'line', 'vowels', 'the turn', 'the ending']) {
        await tester.enterText(find.byKey(const Key('brief_phrase')), phrase);
        await tester.tap(find.byKey(const Key('brief_phrase_add')));
        await tester.pump();
      }
      expect(find.byKey(const Key('brief_phrase')), findsNothing);
      expect(find.byKey(const Key('brief_phrases_full')), findsOneWidget);
      // One taken off makes room for another.
      await tester.tap(find.byKey(const Key('brief_phrase_remove_0')));
      await tester.pump();
      expect(find.byKey(const Key('brief_phrase')), findsOneWidget);
    });

    testWidgets('coming back to it finds what was said, and can send the song without it', (tester) async {
      await _pumpBriefSheet(
        tester,
        song: const SongToPointAt(sections: _sections, downbeatsMs: _downbeats, endMs: 16000),
        initial: const BriefToSend(
          passage: 'Bars 2–5',
          startMs: 2000,
          endMs: 10000,
          rate: 0.75,
          listeningFor: <String>['the breath'],
          // Not the box's own hint, which is still in the tree behind it.
          dueWords: 'By the weekend',
        ),
      );
      expect(find.text('Bars 2–5'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('brief_rate_¾'))).selected, isTrue);
      expect(find.text('the breath'), findsOneWidget);
      expect(find.text('By the weekend'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('brief_clear')));
      await tester.tap(find.byKey(const Key('brief_clear')));
      await tester.pumpAndSettle();
      expect(_chosen, isNotNull);
      expect(_chosen!.brief, isNull);
    });
  });

  group('no numbers', () {
    testWidgets('nothing on the sheet counts, scores or dates anything', (tester) async {
      await _pumpBriefSheet(tester, song: const SongToPointAt(sections: _sections));
      await tester.enterText(find.byKey(const Key('brief_phrase')), 'the breath before the turn');
      await tester.tap(find.byKey(const Key('brief_phrase_add')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('brief_phrase')), 'a second thing, still being typed');
      await tester.enterText(find.byKey(const Key('brief_due')), 'Before Thursday');
      await tester.pump();

      // Not a digit anywhere off the chips: no "2 of 5", no "12/80" under a
      // box, no date, and no field that wants a number.
      final words = _wordsOffTheChips(tester);
      expect(words, contains('Listening for'));
      expect(words, isNot(matches(_digit)));
      for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.maxLength, isNull, reason: 'a maxLength draws a counter under the box');
        expect(field.keyboardType, isNot(TextInputType.number));
        expect(field.keyboardType, isNot(TextInputType.datetime));
      }
    });

    testWidgets('nor on what either of them reads back', (tester) async {
      const asked = BriefToSend(
        passage: 'Chorus',
        startMs: 8000,
        endMs: 16000,
        rate: 1,
        listeningFor: <String>['the breath before the turn'],
        dueWords: 'before Thursday',
      );
      final student = await _aStudent(brief: asked);
      for (final me in <String>['preview-user', 'teacher-maria']) {
        await tester.pumpWidget(MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(body: BriefReading(brief: student.brief, me: me)),
        ));
        final words = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data ?? '').join(' | ');
        expect(words, contains('the breath before the turn'));
        expect(words, contains('before Thursday'));
        expect(words, isNot(matches(_digit)));
        expect(words, isNot(contains('ago')));
      }
    });

    test('nor in the sentences the teacher is told', () {
      expect(sentSaid(0, briefed: true), isNot(matches(_digit)));
      expect(whatToPractiseLabel, isNot(matches(_digit)));
    });
  });

  group('on the song', () {
    testWidgets('a teacher says what to practise on the way to sending, and each copy carries it', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SongWorkspaceScreen(projectId: teacher.songId),
        ),
      ));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_send_to_students')));
      await _settle(tester);

      // One row, and it does not have to be used.
      expect(find.text(whatToPractiseLabel), findsOneWidget);
      expect(find.text('Optional'), findsOneWidget);
      await tester.tap(find.byKey(const Key('send_what_to_practise')));
      await _settle(tester);

      // No recording here, so the whole song is what there is to point at.
      expect(find.byKey(const Key('brief_whole_only')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('brief_phrase')), 'the breath before “credimi”');
      await tester.enterText(find.byKey(const Key('brief_due')), 'Before Thursday');
      await tester.ensureVisible(find.byKey(const Key('brief_done')));
      await tester.tap(find.byKey(const Key('brief_done')));
      await _settle(tester);

      // Read back on the row in the words the student's card will use.
      expect(find.text('The whole song · Before Thursday'), findsOneWidget);

      for (final lesson in teacher.lessons) {
        await tester.tap(find.byKey(Key('send_to_room_$lesson')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('send_to_students_do')));
      await _settle(tester);
      expect(find.text('Sent to 2 students'), findsOneWidget);

      final briefs = await repository.mySongBriefs();
      expect(briefs, hasLength(2));
      for (final brief in briefs) {
        expect(brief.passage, 'The whole song');
        expect(brief.listeningFor, <String>['the breath before “credimi”']);
        expect(brief.dueWords, 'Before Thursday');
      }
      // The teacher gets no card for what they asked of somebody else.
      expect(briefsAskedOf('preview-user', controller.songBriefs), isEmpty);
    });

    testWidgets('a song can still simply be sent', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final teacher = await _aTeacher();
      final controller = MusicBetaController(teacher.repository);
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SongWorkspaceScreen(projectId: teacher.songId),
        ),
      ));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_send_to_students')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('send_to_room_${teacher.lessons[0]}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_to_students_do')));
      await _settle(tester);
      expect(find.text('Sent to 1 student'), findsOneWidget);
      expect(await teacher.repository.mySongBriefs(), isEmpty);
    });

    testWidgets('the student finds the whole of it on the song, and Practise opens Perform there', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final student = await _aStudent();
      final controller = MusicBetaController(student.repository);
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SongWorkspaceScreen(projectId: student.song.id),
        ),
      ));
      await _settle(tester);

      final line = find.byKey(const Key('song_brief'));
      expect(line, findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('From Maria')), findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('Bars 1–16 at ¾ · before Thursday')),
          findsOneWidget);

      await tester.tap(line);
      await _settle(tester);
      // What the card on Home has no room for.
      expect(find.text('Listening for'), findsOneWidget);
      expect(find.text('the breath before “credimi”'), findsOneWidget);
      expect(find.text('legato through the turn'), findsOneWidget);

      await tester.tap(find.byKey(const Key('brief_reading_practise')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final perform = tester.widget<LivePerformanceScreen>(find.byType(LivePerformanceScreen));
      expect(perform.project.id, student.song.id);
      expect(perform.practise?.label, 'Bars 1–16');
      expect(perform.practise?.startMs, 0);
      expect(perform.practise?.endMs, 32000);
      expect(perform.practise?.rate, 0.75);
    });

    testWidgets('the teacher reads the same words on their copy, and nothing about whether it was opened',
        (tester) async {
      final student = await _aStudent();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(body: BriefReading(brief: student.brief, me: 'teacher-maria')),
      ));
      expect(find.text('What you asked for'), findsOneWidget);
      expect(find.text('Bars 1–16 at ¾'), findsOneWidget);
      expect(find.text('the breath before “credimi”'), findsOneWidget);
      // Practise is the student's verb. What the teacher gets instead is the
      // sentence that says what they will never be shown.
      expect(find.byKey(const Key('brief_reading_practise')), findsNothing);
      expect(find.text('You will not see whether they opened it.'), findsOneWidget);
    });
  });

  group('on Home', () {
    testWidgets('one card: from whom, the song, the passage at the speed, and when by', (tester) async {
      final student = await _aStudent();
      await _home(tester, student.repository);

      final card = find.byKey(Key('waiting_card_brief-${student.brief.id}'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('From Maria')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Caro mio ben')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Bars 1–16 at ¾ · before Thursday')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Practise')), findsOneWidget);

      // Nothing about when it was asked, and nothing counting down to
      // Thursday: the only words about time are the teacher's own.
      final words = tester
          .widgetList<Text>(find.descendant(of: card, matching: find.byType(Text)))
          .map((text) => text.data ?? '')
          .join(' ');
      expect(words, isNot(contains('ago')));
      expect(words, isNot(contains('left')));
      expect(words, isNot(contains('due')));
      expect(words, isNot(contains('today')));
    });

    testWidgets('the card opens Perform at the passage and the speed', (tester) async {
      final student = await _aStudent();
      await _home(tester, student.repository);

      await tester.tap(find.byKey(Key('waiting_do_brief-${student.brief.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final perform = tester.widget<LivePerformanceScreen>(find.byType(LivePerformanceScreen));
      expect(perform.project.id, student.song.id);
      expect(perform.practise?.label, 'Bars 1–16');
      expect(perform.practise?.startMs, 0);
      expect(perform.practise?.endMs, 32000);
      expect(perform.practise?.rate, 0.75);
      // What is practised there is kept as the student's own, like any other
      // practice, and goes to nobody.
      expect(perform.keepPractice, isNotNull);
    });

    testWidgets('practising from it does not put a second card for the same song beside it', (tester) async {
      final student = await _aStudent();
      // What Perform keeps when the student practises the passage: their own
      // mark on the song, with no words on it.
      await student.repository.keepPracticeMark(PracticeMark(
        id: 'mine-1',
        projectId: student.song.id,
        ledBy: 'preview-user',
        ledByName: 'Taylor',
        parts: const <PracticePart>[
          PracticePart(label: 'Bars 1–16', rate: 0.75, seconds: 90, startMs: 0, endMs: 32000),
        ],
        updatedAt: DateTime.now(),
      ));
      await _home(tester, student.repository);
      expect(find.byKey(Key('waiting_card_brief-${student.brief.id}')), findsOneWidget);
      expect(find.byKey(const Key('waiting_card_practice-mine-1')), findsNothing);
    });

    testWidgets('closed, it stays closed, until the teacher says something new', (tester) async {
      final student = await _aStudent();
      final controller = await _home(tester, student.repository);
      await tester.tap(find.byKey(Key('waiting_close_brief-${student.brief.id}')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(Key('waiting_card_brief-${student.brief.id}')), findsNothing);
      await controller.load();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(Key('waiting_card_brief-${student.brief.id}')), findsNothing);

      // Next week's passage, on the same copy.
      student.repository.currentUserId = 'teacher-maria';
      await student.repository.setSongBriefs(
        <String>[student.song.id],
        const BriefToSend(passage: 'Bars 17–32', startMs: 32000, endMs: 64000, rate: 0.9),
      );
      student.repository.currentUserId = 'preview-user';
      await controller.load();
      await tester.pump(const Duration(milliseconds: 200));
      final next = (await student.repository.mySongBriefs()).single;
      final card = find.byKey(Key('waiting_card_brief-${next.id}'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Bars 17–32 at 90%')), findsOneWidget);
    });

    testWidgets('the teacher gets no card for what they asked of a student', (tester) async {
      final teacher = await _aTeacher();
      await teacher.repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      await teacher.repository.briefStudents(
          projectId: teacher.songId, roomIds: teacher.lessons, brief: _aBrief);
      final controller = await _home(tester, teacher.repository);
      expect(controller.songBriefs, hasLength(2));
      for (final brief in controller.songBriefs) {
        expect(find.byKey(Key('waiting_card_brief-${brief.id}')), findsNothing);
      }
    });
  });

  test('a closed practice card is remembered the next time the app opens', () async {
    // It was written and never read back, so a card closed on Monday was
    // there again on Tuesday. For something a teacher asked for, that is a
    // reminder, and this sends none.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SetAside.resetForTesting();
    await SetAside.add(SetAside.practice, 'brief-1');
    SetAside.resetForTesting();
    expect(SetAside.has(SetAside.practice, 'brief-1'), isFalse);
    await SetAside.load();
    expect(SetAside.has(SetAside.practice, 'brief-1'), isTrue);
  });
}
