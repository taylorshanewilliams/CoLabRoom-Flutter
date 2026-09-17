import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/sending_a_take.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/take_lane.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Send a take to your teacher.
///
/// Every Musician, Same Song, 17 September 2026: a lesson link makes a room
/// with exactly two people (0129), and a take is private until it is shared
/// (0057), so a hand-in already worked by construction. What it did not do
/// was say so — a student pressing Share was told the room would be told,
/// which is true and useless when the room is one teacher. These are the
/// words, and the check that a band room still gets the old ones.

MusicRoom _room({
  required String teacherId,
  String teacher = 'Ms. Rivera',
}) {
  return MusicRoom(
    id: 'room-1',
    accountId: teacherId,
    name: 'Guitar lessons · Jess',
    icon: '♪',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 17),
    members: <RoomMember>[
      RoomMember(
        userId: teacherId,
        displayName: teacher,
        role: RoomRole.owner,
        colorValue: 0xFFFF8A4C,
      ),
      const RoomMember(
        userId: 'student-1',
        displayName: 'Jess',
        role: RoomRole.editor,
        colorValue: 0xFF4C8AFF,
      ),
    ],
  );
}

Widget _lane({String shareLabel = 'Share'}) {
  return MaterialApp(
    home: Scaffold(
      body: TakeLane(
        take: Take(
          id: 'take-1',
          path: '/tmp/take-1.m4a',
          label: 'Verse',
          recordedAt: DateTime(2026, 9, 17),
          durationMs: 42000,
        ),
        onToggle: () {},
        onDelete: () {},
        onAdjust: () {},
        onShare: () {},
        shareLabel: shareLabel,
      ),
    ),
  );
}

/// A take of this person's own that nobody has heard yet.
class _OneUnsentTake extends SongLayerService {
  _OneUnsentTake(this.projectId) : super(client: null);

  final String projectId;

  @override
  Future<List<SharedLayer>> listLayers(String forProject) async => <SharedLayer>[
        SharedLayer(
          id: 'take-1',
          projectId: projectId,
          recordedBy: 'preview-user',
          storagePath: 'x/$projectId/layers/take-1.m4a',
          label: 'Caro mio ben',
          part: TakePart.other,
          durationMs: 120000,
          createdAt: DateTime(2026, 9, 17),
        ),
      ];

  @override
  Future<String> ensureLocal(SharedLayer layer) async => '/tmp/${layer.id}.m4a';

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _NoAnalysis extends SongAnalysisService {
  _NoAnalysis() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
}

Future<void> _openTakes(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  required String roomId,
  String projectId = 'song-1',
}) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongLayersScreen(
        roomId: roomId,
        projectId: projectId,
        songTitle: 'Caro mio ben',
        layerService: _OneUnsentTake(projectId),
        analysisService: _NoAnalysis(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

InMemoryMusicRepository _withALessonOffered() {
  return InMemoryMusicRepository.seeded()
    ..offerLesson(
        code: '0123456789ab', title: 'Guitar lessons', teacherName: 'Maria')
    ..callStanding = CallStanding.adult;
}

Widget _asks({String? teacher, required void Function(bool) answered}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              answered(await confirmSharing(context, teacher: teacher)),
          child: const Text('go'),
        ),
      ),
    ),
  );
}

void main() {
  group('who a take is going to', () {
    test('in a lesson room, the teacher, by the name the room already knows',
        () {
      expect(
        teacherToSendTo(
          lessonRoom: true,
          room: _room(teacherId: 'teacher-1'),
          me: 'student-1',
        ),
        'Ms. Rivera',
      );
    });

    test('in a band room, nobody in particular', () {
      expect(
        teacherToSendTo(
          lessonRoom: false,
          room: _room(teacherId: 'teacher-1'),
          me: 'student-1',
        ),
        isNull,
      );
    });

    test('a teacher in their own lesson room shares the ordinary way', () {
      // The room's owner is the teacher, so this is the teacher's own take —
      // a demonstration, played for the student. "Send to yourself" is
      // nonsense, and the band wording is the honest one.
      expect(
        teacherToSendTo(
          lessonRoom: true,
          room: _room(teacherId: 'teacher-1'),
          me: 'teacher-1',
        ),
        isNull,
      );
    });

    test('a room that has not loaded its people yet says nothing', () {
      expect(teacherToSendTo(lessonRoom: true, room: null, me: 'student-1'),
          isNull);
    });

    test('a room made by opening a lesson link knows that it is one', () async {
      final repository = InMemoryMusicRepository.seeded()
        ..offerLesson(
            code: '0123456789ab', title: 'Guitar lessons', teacherName: 'Maria')
        ..callStanding = CallStanding.adult;
      final lesson = await repository.joinLessonLink('0123456789ab');
      final rooms = await repository.loadRooms();
      final band = rooms.firstWhere((room) => room.id != lesson);

      expect(await repository.isLessonRoom(lesson), isTrue);
      expect(await repository.isLessonRoom(band.id), isFalse);

      final room = rooms.firstWhere((room) => room.id == lesson);
      expect(
        teacherToSendTo(
          lessonRoom: true,
          room: room,
          me: repository.currentUserId,
        ),
        'Maria',
      );
    });
  });

  group('on the takes screen', () {
    testWidgets('in a lesson room the take goes to the teacher, by name',
        (tester) async {
      final repository = _withALessonOffered();
      final lesson = await repository.joinLessonLink('0123456789ab');

      await _openTakes(tester, repository, roomId: lesson);

      expect(find.text('Send to Maria'), findsOneWidget);
      expect(find.text('Share'), findsNothing);

      await tester.tap(find.text('Send to Maria'));
      await tester.pumpAndSettle();
      expect(find.text('Send to Maria?'), findsOneWidget);
      expect(find.textContaining('Only Maria will hear this.'), findsOneWidget);

      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();
    });

    testWidgets('a band room is unchanged', (tester) async {
      final repository = _withALessonOffered();
      // Made, and then not used: the account has a lesson link available to
      // it and this song is still in an ordinary room.
      await _openTakes(tester, repository, roomId: 'room-1');

      expect(find.text('Share'), findsOneWidget);
      expect(find.textContaining('Send to'), findsNothing);

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(find.text('Let the room hear this?'), findsOneWidget);

      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();
    });
  });

  group('the words', () {
    testWidgets('a long name shortens rather than running off the lane',
        (tester) async {
      tester.view.physicalSize = const Size(240, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(_lane(
          shareLabel: shareLabelFor('Professor Aleksandra Wiśniewska-Kowalczyk')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('sending it promises one listener', (tester) async {
      bool? said;
      await tester.pumpWidget(
          _asks(teacher: 'Ms. Rivera', answered: (answer) => said = answer));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('Send to Ms. Rivera?'), findsOneWidget);
      expect(find.textContaining('Only Ms. Rivera will hear this.'),
          findsOneWidget);
      expect(find.textContaining('Everybody in the room'), findsNothing);

      await tester.tap(find.text('Send it'));
      await tester.pumpAndSettle();
      expect(said, isTrue);
    });

    testWidgets('sharing in a band room is unchanged', (tester) async {
      bool? said;
      await tester.pumpWidget(_asks(answered: (answer) => said = answer));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('Let the room hear this?'), findsOneWidget);
      expect(find.textContaining('Everybody in the room gets told'),
          findsOneWidget);
      expect(find.textContaining('will hear this'), findsNothing);

      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();
      expect(said, isFalse);
    });
  });
}
