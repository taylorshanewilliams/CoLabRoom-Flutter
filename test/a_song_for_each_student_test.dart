import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/lessons/sending_a_song.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A song for each student.
///
/// Every Musician, Same Song, 17 September 2026, slice 19: a teacher picks
/// one of their own songs and sends a copy into the lesson rooms they
/// choose, one copy a room, so each student works on their own copy where
/// only the two of them can hear it (0149). The recording goes only with a
/// song that is ours or public domain (0142); somebody else's song travels
/// as words and chords.
///
/// Three things have to hold. The entry is offered to somebody who teaches,
/// on a song in a room they own, and to nobody else: a song leaving its
/// room is the room owner's decision, as putting it on the Open Mic is
/// (0142). What is sent arrives in each ticked lesson as its own copy,
/// once, however many times it is sent. And the teacher is told in one
/// plain sentence, with the one number this feature ever shows.

const RoomMember _me = RoomMember(
  userId: 'preview-user',
  displayName: 'Taylor',
  role: RoomRole.owner,
  colorValue: 0xFFFF8A4C,
);

MusicRoom _room(
  String id,
  String name, {
  List<RoomMember>? members,
}) {
  return MusicRoom(
    id: id,
    accountId: 'preview-user',
    name: name,
    icon: '♪',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 17),
    members: members ??
        <RoomMember>[
          _me,
          const RoomMember(
            userId: 'student-1',
            displayName: 'Jess',
            role: RoomRole.editor,
            colorValue: 0xFF4C8AFF,
          ),
        ],
  );
}

/// Pumped rather than settled: the workspace joins a cowork stream when it
/// opens, and every other test on this screen pumps for the same reason.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// A teacher with a studio song and two students, or with the song alone.
Future<({InMemoryMusicRepository repository, String songId, List<String> lessons})> _aTeacher({
  bool teaching = true,
  SongOrigin? origin = SongOrigin.ours,
}) async {
  final repository = InMemoryMusicRepository.seeded();
  final studio = (await repository.loadRooms()).firstWhere((room) => room.name == 'Acoustic Ideas');
  final song = await repository.createSong(room: studio, title: 'Caro mio ben');
  await repository.addContribution(project: song, body: 'Caro mio ben');
  await repository.addContribution(project: song, body: 'credimi almen');
  if (origin != null) await repository.setSongOrigin(song.id, origin);
  final lessons = <String>[];
  if (teaching) {
    lessons.add(repository.teachALesson(studentId: 'student-1', studentName: 'Jess').id);
    lessons.add(repository.teachALesson(studentId: 'student-2', studentName: 'Sam').id);
  }
  return (repository: repository, songId: song.id, lessons: lessons);
}

Future<InMemoryMusicRepository> _openTheSong(
  WidgetTester tester, {
  bool teaching = true,
  SongOrigin? origin = SongOrigin.ours,
}) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final teacher = await _aTeacher(teaching: teaching, origin: origin);
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
  return teacher.repository;
}

Future<List<SongProject>> _copiesIn(InMemoryMusicRepository repository, String roomId) async =>
    (await repository.loadRooms()).firstWhere((room) => room.id == roomId).projects;

Future<SongProject> _song(InMemoryMusicRepository repository, String songId) async =>
    (await repository.loadRooms()).expand((room) => room.projects).firstWhere((song) => song.id == songId);

void main() {
  group('who a song can be sent to', () {
    final lessonJess = _room('lesson-jess', 'Guitar lessons · Jess');
    final lessonSam = _room(
      'lesson-sam',
      'Guitar lessons · Sam',
      members: const <RoomMember>[
        _me,
        RoomMember(userId: 'student-2', displayName: 'Sam', role: RoomRole.editor, colorValue: 0xFF7CE0A0),
      ],
    );
    final studio = _room('studio', 'Studio', members: const <RoomMember>[_me]);
    // The other end of a lesson: a room somebody else's link made, where
    // this person is the student.
    final myOwnLesson = _room(
      'my-lesson',
      'Piano lessons · Taylor',
      members: const <RoomMember>[
        RoomMember(userId: 'teacher-2', displayName: 'Maria', role: RoomRole.owner, colorValue: 0xFFFF8A4C),
        RoomMember(userId: 'preview-user', displayName: 'Taylor', role: RoomRole.editor, colorValue: 0xFF4C8AFF),
      ],
    );
    final rooms = <MusicRoom>[studio, lessonSam, lessonJess, myOwnLesson];

    test('the lessons this person teaches, by the name the room has, in order', () {
      expect(
        lessonRoomsToSendTo(
          taught: <String>['lesson-jess', 'lesson-sam', 'my-lesson'],
          rooms: rooms,
          me: 'preview-user',
          songRoom: studio,
        ),
        <({String id, String name})>[
          (id: 'lesson-jess', name: 'Guitar lessons · Jess'),
          (id: 'lesson-sam', name: 'Guitar lessons · Sam'),
        ],
      );
    });

    test('never the room the song is already in', () {
      expect(
        lessonRoomsToSendTo(
          taught: <String>['lesson-jess', 'lesson-sam'],
          rooms: rooms,
          me: 'preview-user',
          songRoom: lessonJess,
        ).map((room) => room.id),
        <String>['lesson-sam'],
      );
    });

    test('a lesson this person is the student of is not one to send into', () {
      // isLessonRoom says yes to both ends of a lesson; only the teacher's
      // end is a place to put a song.
      expect(
        lessonRoomsToSendTo(
          taught: <String>['my-lesson'],
          rooms: rooms,
          me: 'preview-user',
          songRoom: studio,
        ),
        isEmpty,
      );
    });

    test('a lesson whose student has left is not one to send into', () {
      // The lesson row outlives the membership (0129): the room is still
      // the teacher's, there is just nobody in it. Listing it would have
      // every tick beside it refuse the whole send.
      final emptied = _room('lesson-gone', 'Guitar lessons · Left', members: const <RoomMember>[_me]);
      expect(
        lessonRoomsToSendTo(
          taught: <String>['lesson-jess', 'lesson-gone'],
          rooms: <MusicRoom>[...rooms, emptied],
          me: 'preview-user',
          songRoom: studio,
        ).map((room) => room.id),
        <String>['lesson-jess'],
      );
    });

    test('somebody who cannot write on the song is offered nobody', () {
      final listeningIn = _room(
        'band',
        'The Band',
        members: const <RoomMember>[
          RoomMember(userId: 'bandleader', displayName: 'Ray', role: RoomRole.owner, colorValue: 0xFFFF8A4C),
          RoomMember(userId: 'preview-user', displayName: 'Taylor', role: RoomRole.viewer, colorValue: 0xFF4C8AFF),
        ],
      );
      expect(
        lessonRoomsToSendTo(
          taught: <String>['lesson-jess'],
          rooms: rooms,
          me: 'preview-user',
          songRoom: listeningIn,
        ),
        isEmpty,
      );
    });

    test("an editor of somebody else's room is offered nobody for the band's song", () {
      // A song leaving its room is the room owner's decision, the way
      // putting it on the Open Mic is (0142): an editor can write on the
      // band's song, and a co-writer's lines reach only the rooms the
      // owner chose.
      final bandRoom = _room(
        'band',
        'The Band',
        members: const <RoomMember>[
          RoomMember(userId: 'bandleader', displayName: 'Ray', role: RoomRole.owner, colorValue: 0xFFFF8A4C),
          RoomMember(userId: 'preview-user', displayName: 'Taylor', role: RoomRole.editor, colorValue: 0xFF4C8AFF),
        ],
      );
      expect(
        lessonRoomsToSendTo(
          taught: <String>['lesson-jess'],
          rooms: rooms,
          me: 'preview-user',
          songRoom: bandRoom,
        ),
        isEmpty,
      );
    });

    test('nobody who teaches nobody, and nothing before the room is known', () {
      expect(
        lessonRoomsToSendTo(taught: const <String>[], rooms: rooms, me: 'preview-user', songRoom: studio),
        isEmpty,
      );
      expect(
        lessonRoomsToSendTo(taught: <String>['lesson-jess'], rooms: rooms, me: 'preview-user', songRoom: null),
        isEmpty,
      );
      expect(
        lessonRoomsToSendTo(taught: <String>['lesson-jess'], rooms: rooms, me: '', songRoom: studio),
        isEmpty,
      );
    });
  });

  group('what is said', () {
    test('one sentence, with the one number this feature shows', () {
      expect(sentSaid(9), 'Sent to 9 students');
      expect(sentSaid(1), 'Sent to 1 student');
      // Every ticked student already had it: the rooms that received a copy
      // are what is counted, and there were none.
      expect(sentSaid(0), 'Already sent.');
    });

    test("somebody else's song is said to travel without its recording", () {
      expect(sendKeepsTheRecording(SongOrigin.cover),
          "Somebody else's song, so the recording stays here.");
      expect(sendKeepsTheRecording(SongOrigin.ours), isNull);
      expect(sendKeepsTheRecording(SongOrigin.publicDomain), isNull);
    });
  });

  group('the copy', () {
    test('each lesson gets its own copy of the song, named for the student', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      repository.putARecordingOn(teacher.songId);

      final sent = await repository.sendSongToStudents(
        projectId: teacher.songId,
        roomIds: teacher.lessons,
      );
      expect(sent, teacher.lessons);

      final jess = (await _copiesIn(repository, teacher.lessons[0])).single;
      final sam = (await _copiesIn(repository, teacher.lessons[1])).single;
      // Named for the student, because the original already has the title
      // in this account, the way the room is named for them (0129).
      expect(jess.title, 'Caro mio ben · Jess');
      expect(sam.title, 'Caro mio ben · Sam');
      expect(jess.id, isNot(teacher.songId));
      expect(jess.id, isNot(sam.id));

      // The words, in order, each with its writer, under ids of their own.
      expect(jess.contributions.map((line) => line.body), <String>['Caro mio ben', 'credimi almen']);
      final original = await _song(repository, teacher.songId);
      expect(jess.contributions.map((line) => line.authorName), original.contributions.map((line) => line.authorName));
      expect(jess.contributions.map((line) => line.id).toSet().intersection(original.contributions.map((line) => line.id).toSet()), isEmpty);

      // Whose song it is goes with it, and so does the recording: this one
      // is ours.
      expect(jess.songOrigin, SongOrigin.ours);
      expect(jess.hasAudioReference, isTrue);
      expect(jess.analysisState, SongAnalysisState.ready);

      // The original is untouched.
      expect(original.roomId, isNot(jess.roomId));
      expect(original.contributions, hasLength(2));
      expect(original.title, 'Caro mio ben');
    });

    test('the language the teacher said it is sung in goes with the copy', () async {
      // 0165. What a song is sung in decides which way every line on the
      // sheet runs and what each chord sits over (0163), so a copy arriving
      // without it lays an Arabic song out left to right on the student's
      // stand while the teacher's own page runs the other way — and the two
      // of them are then reading different pages of the same song, which is
      // the one thing a shared fact exists to prevent.
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.setSongLanguage(teacher.songId, 'ar');

      await repository.sendSongToStudents(
        projectId: teacher.songId,
        roomIds: <String>[teacher.lessons[0]],
      );
      final copy = (await _copiesIn(repository, teacher.lessons[0])).single;
      expect(copy.language, 'ar', reason: 'the student reads it the way the teacher does');
      // And the original is untouched by the send.
      expect((await _song(repository, teacher.songId)).language, 'ar');
    });

    test('a song nobody has answered for travels without a language', () async {
      // Null copies as null. Nobody has said, so the copy is laid out
      // exactly as this app laid out every song before anybody could say —
      // never guessed at from the words on the way past.
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      expect((await _song(repository, teacher.songId)).language, isNull);

      await repository.sendSongToStudents(
        projectId: teacher.songId,
        roomIds: <String>[teacher.lessons[0]],
      );
      expect((await _copiesIn(repository, teacher.lessons[0])).single.language, isNull);
    });

    test('sending again sends nothing new', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      final again = await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      expect(again, isEmpty);
      expect(await _copiesIn(repository, teacher.lessons[0]), hasLength(1));
      expect(await _copiesIn(repository, teacher.lessons[1]), hasLength(1));
    });

    test('only the students who do not have it yet count', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]]);
      final then = await repository.sendSongToStudents(projectId: teacher.songId, roomIds: teacher.lessons);
      expect(then, <String>[teacher.lessons[1]]);
    });

    test("somebody else's song travels without its recording", () async {
      final teacher = await _aTeacher(origin: SongOrigin.cover);
      final repository = teacher.repository;
      repository.putARecordingOn(teacher.songId);
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]]);
      final copy = (await _copiesIn(repository, teacher.lessons[0])).single;
      expect(copy.contributions, hasLength(2));
      expect(copy.songOrigin, SongOrigin.cover);
      expect(copy.hasAudioReference, isFalse);
      expect(copy.analysisState, isNull);
    });

    test('a song nobody has been asked about travels without its recording too', () async {
      // Null is not an answer. The app asks before it sends; the repository
      // does not assume.
      final teacher = await _aTeacher(origin: null);
      final repository = teacher.repository;
      repository.putARecordingOn(teacher.songId);
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]]);
      expect((await _copiesIn(repository, teacher.lessons[0])).single.hasAudioReference, isFalse);
    });

    test("a band's song this person only edits is not theirs to send", () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      // A room somebody else owns, with this person as an editor. They can
      // write on the band's song; deciding that their students' rooms may
      // have it is the band's owner's decision, as putting it on the Open
      // Mic is (0142), and nothing of it reaches a student.
      await repository.acceptInvite(invite: (await repository.loadInvites()).first);
      final band = (await repository.loadRooms()).firstWhere((room) => room.name == 'Studio Session');
      final bandSong = await repository.createSong(room: band, title: 'The Band Song');
      await repository.addContribution(project: bandSong, body: 'The band wrote this');
      await repository.setSongOrigin(bandSong.id, SongOrigin.ours);
      repository.putARecordingOn(bandSong.id);

      await expectLater(
        repository.sendSongToStudents(projectId: bandSong.id, roomIds: <String>[teacher.lessons[0]]),
        throwsA(isA<NameConflict>().having((e) => e.message, 'message', 'That song is not yours to send.')),
      );
      expect(await _copiesIn(repository, teacher.lessons[0]), isEmpty);
    });

    test('a lesson whose student has left is skipped, not refused', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      final emptied = repository.teachALesson(studentId: 'student-3', studentName: 'Left');
      await repository.removeRoomMember(roomId: emptied.id, userId: 'student-3');

      final sent = await repository.sendSongToStudents(
        projectId: teacher.songId,
        roomIds: <String>[emptied.id, teacher.lessons[0]],
      );
      // The empty lesson took nothing and refused nothing; the other got it.
      expect(sent, <String>[teacher.lessons[0]]);
      expect(await _copiesIn(repository, emptied.id), isEmpty);
    });

    test('sending again finishes a copy whose recording never arrived, and does not count it', () async {
      // Sent before anybody said whose song it was, so it went without its
      // recording; answered and sent again, the recording arrives on the
      // copy the student already has rather than on a second copy. The
      // room is not among those that received a copy now: the student has
      // had the song since the first send, and the sentence says so.
      final teacher = await _aTeacher(origin: null);
      final repository = teacher.repository;
      repository.putARecordingOn(teacher.songId);
      await repository.sendSongToStudents(projectId: teacher.songId, roomIds: <String>[teacher.lessons[0]]);
      expect((await _copiesIn(repository, teacher.lessons[0])).single.hasAudioReference, isFalse);

      await repository.setSongOrigin(teacher.songId, SongOrigin.ours);
      final again = await repository.sendSongToStudents(
        projectId: teacher.songId,
        roomIds: <String>[teacher.lessons[0]],
      );
      expect(again, isEmpty);
      expect(sentSaid(again.length), 'Already sent.');
      final copies = await _copiesIn(repository, teacher.lessons[0]);
      expect(copies, hasLength(1));
      expect(copies.single.hasAudioReference, isTrue);
      expect(copies.single.analysisState, SongAnalysisState.ready);
    });

    test('a room that is not a lesson of theirs refuses the whole send', () async {
      final teacher = await _aTeacher();
      final repository = teacher.repository;
      final band = (await repository.loadRooms()).firstWhere((room) => room.name == 'After Hours Studio');
      await expectLater(
        repository.sendSongToStudents(
          projectId: teacher.songId,
          roomIds: <String>[teacher.lessons[0], band.id],
        ),
        throwsA(isA<NameConflict>().having((e) => e.message, 'message', 'That is not a lesson of yours.')),
      );
      // One wrong room in the list, and nothing was sent.
      expect(await _copiesIn(repository, teacher.lessons[0]), isEmpty);
    });

    test('nobody ticked is refused in words', () async {
      final teacher = await _aTeacher();
      await expectLater(
        teacher.repository.sendSongToStudents(projectId: teacher.songId, roomIds: const <String>[]),
        throwsA(isA<NameConflict>()),
      );
    });
  });

  group('on the song', () {
    testWidgets('a teacher is offered it on a song of theirs', (tester) async {
      await _openTheSong(tester);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      expect(find.text(sendToStudentsLabel), findsOneWidget);
    });

    testWidgets('somebody who teaches nobody is not', (tester) async {
      await _openTheSong(tester, teaching: false);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      expect(find.byKey(const Key('song_send_to_students')), findsNothing);
    });

    testWidgets('the lessons are listed by name, ticked, and sent with one action', (tester) async {
      final repository = await _openTheSong(tester);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_send_to_students')));
      await _settle(tester);

      expect(find.text('Guitar lessons · Jess'), findsOneWidget);
      expect(find.text('Guitar lessons · Sam'), findsOneWidget);
      // Ours: nothing to say about the recording.
      expect(find.byKey(const Key('send_to_students_keeps')), findsNothing);
      // Nobody ticked yet, so nothing to send yet.
      final before = tester.widget<FilledButton>(find.byKey(const Key('send_to_students_do')));
      expect(before.onPressed, isNull);

      final lessons = await repository.lessonRoomsTaught();
      for (final lesson in lessons) {
        await tester.tap(find.byKey(Key('send_to_room_$lesson')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('send_to_students_do')));
      await _settle(tester);

      // Each lesson has its copy, and the teacher was told once, plainly.
      for (final lesson in lessons) {
        expect(await _copiesIn(repository, lesson), hasLength(1));
      }
      expect(find.text('Sent to 2 students'), findsOneWidget);
    });

    testWidgets("a song nobody has been asked about asks whose it is first", (tester) async {
      final repository = await _openTheSong(tester, origin: null);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_send_to_students')));
      await _settle(tester);

      // The question, before the list.
      expect(find.text('Who wrote this song?'), findsOneWidget);
      expect(find.byKey(const Key('send_to_students_do')), findsNothing);
      await tester.tap(find.byKey(const Key('whose_song_cover')));
      await _settle(tester);

      // Answered, and the answer decides what the sheet says will go.
      expect(find.byKey(const Key('send_to_students_do')), findsOneWidget);
      expect(find.byKey(const Key('send_to_students_keeps')), findsOneWidget);
      final song = (await repository.loadRooms())
          .expand((room) => room.projects)
          .firstWhere((song) => song.title == 'Caro mio ben');
      expect(song.songOrigin, SongOrigin.cover);
    });
  });
}
