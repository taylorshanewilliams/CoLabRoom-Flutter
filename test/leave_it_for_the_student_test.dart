import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/lessons/leaving_practice.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Leave it for the student.
///
/// Every Musician, Same Song, 17 September 2026: Follow me already leaves a
/// mark when a live hour ends (0128), and Home offers it back with one verb.
/// What a teacher could not do was think of it on Wednesday evening. Now they
/// can, in a lesson room of their own (0129) and nowhere else, and what
/// arrives on the student's Home is the practice card that was already there.
///
/// Three things have to hold. The action is offered to a teacher in their own
/// lesson and to nobody else. What they leave reaches the student as a mark
/// led by them. And nothing anybody reads says when.

MusicRoom _room({
  required String ownerId,
  String owner = 'Taylor',
  String studentName = 'Jess',
  List<RoomMember>? members,
}) {
  return MusicRoom(
    id: 'room-1',
    accountId: ownerId,
    name: 'Guitar lessons · Jess',
    icon: '♪',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 17),
    members: members ??
        <RoomMember>[
          RoomMember(
            userId: ownerId,
            displayName: owner,
            role: RoomRole.owner,
            colorValue: 0xFFFF8A4C,
          ),
          RoomMember(
            userId: 'student-1',
            displayName: studentName,
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

SongProject _song() => SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'teacher-1',
      title: 'Caro mio ben',
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 17),
    );

const List<StructureSection> _sections = <StructureSection>[
  StructureSection(startMs: 0, endMs: 1000, label: 'Verse'),
  StructureSection(startMs: 1000, endMs: 2000, label: 'Chorus'),
];

/// What the last pumped sheet was closed with.
PracticeToLeave? _left;

/// The sheet on its own, without a song behind it, opened the way the song
/// opens it.
Future<void> _pumpSheet(
  WidgetTester tester, {
  required bool sheet,
  required List<StructureSection> sections,
}) async {
  _left = null;
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open_leave_practice'),
          onPressed: () async {
            _left = await showLeavePractice(
              context,
              student: 'Jess',
              sections: sections,
              sheet: sheet,
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open_leave_practice')));
  await tester.pumpAndSettle();
}

/// A lesson this person teaches, with one song in it, open on screen.
Future<InMemoryMusicRepository> _openALesson(
  WidgetTester tester, {
  bool teaching = true,
}) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final repository = InMemoryMusicRepository.seeded();
  final String projectId;
  if (teaching) {
    final lesson =
        repository.teachALesson(studentId: 'student-1', studentName: 'Jess');
    projectId = (await repository.createSong(
      room: lesson,
      title: 'Caro mio ben',
    ))
        .id;
  } else {
    projectId = 'song-1';
  }

  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongWorkspaceScreen(projectId: projectId),
    ),
  ));
  await _settle(tester);
  return repository;
}

void main() {
  group('who practice can be left for', () {
    test('in a lesson you teach, the student, by the name the room knows', () {
      expect(
        studentToLeavePracticeFor(
          lessonRoom: true,
          room: _room(ownerId: 'teacher-1'),
          me: 'teacher-1',
        ),
        (id: 'student-1', name: 'Jess'),
      );
    });

    test('in a band room, nobody', () {
      // Four people and none of them is anybody's teacher. The same call here
      // would be one member writing on another member's Home.
      expect(
        studentToLeavePracticeFor(
          lessonRoom: false,
          room: _room(ownerId: 'teacher-1'),
          me: 'teacher-1',
        ),
        isNull,
      );
    });

    test('the student, standing in their own lesson, is offered nothing', () {
      expect(
        studentToLeavePracticeFor(
          lessonRoom: true,
          room: _room(ownerId: 'teacher-1'),
          me: 'student-1',
        ),
        isNull,
      );
    });

    test('once somebody else is in the room, it is a room again', () {
      // The promise is about who is in the room, not about the link that made
      // it: a teacher can invite an accompanist, and by then which of them
      // the lesson belongs to is not a question the membership answers.
      expect(
        studentToLeavePracticeFor(
          lessonRoom: true,
          room: _room(
            ownerId: 'teacher-1',
            members: <RoomMember>[
              const RoomMember(
                userId: 'teacher-1',
                displayName: 'Taylor',
                role: RoomRole.owner,
                colorValue: 0xFFFF8A4C,
              ),
              const RoomMember(
                userId: 'student-1',
                displayName: 'Jess',
                role: RoomRole.editor,
                colorValue: 0xFF4C8AFF,
              ),
              const RoomMember(
                userId: 'accompanist-1',
                displayName: 'Sam',
                role: RoomRole.editor,
                colorValue: 0xFF7CE0A0,
              ),
            ],
          ),
          me: 'teacher-1',
        ),
        isNull,
      );
    });

    test('a room that has not loaded its people yet says nothing', () {
      expect(
        studentToLeavePracticeFor(lessonRoom: true, room: null, me: 'teacher-1'),
        isNull,
      );
    });

    test('a student with no name is still somebody to leave practice for', () {
      // join_lesson_link falls back to "A student"; a room read back without
      // names would otherwise leave a gap in the middle of the menu entry.
      expect(
        studentToLeavePracticeFor(
          lessonRoom: true,
          room: _room(ownerId: 'teacher-1', studentName: '  '),
          me: 'teacher-1',
        )?.name,
        'your student',
      );
    });
  });

  group('what there is to point at', () {
    test('the whole song first, then the parts, numbered as Perform says them',
        () {
      const sections = <StructureSection>[
        StructureSection(startMs: 0, endMs: 1000, label: 'Verse'),
        StructureSection(startMs: 1000, endMs: 2000, label: 'Chorus'),
        StructureSection(startMs: 2000, endMs: 3000, label: 'Verse'),
        StructureSection(startMs: 3000, endMs: 4000, label: 'Chorus'),
      ];
      final targets = practiceTargets(sections);
      expect(
        targets.map((target) => target.label),
        <String>[
          'The whole song',
          'Verse 1',
          'Chorus 1',
          'Verse 2',
          'Chorus 2',
        ],
      );
      expect(targets.first.startMs, isNull);
      expect(targets.last.startMs, 3000);
      expect(targets.last.endMs, 4000);
    });

    test('a song with no sheet still has the whole of it', () {
      expect(practiceTargets(const <StructureSection>[]).single.label,
          'The whole song');
    });
  });

  group('what a speed is a speed of', () {
    // Perform applies a mark's part and speed only when it has a sheet to
    // follow (live_performance_screen's _hasSync). A sheet that offered them
    // anyway would put "Chorus 1 at ½" on a card over a song that opens at
    // the top at 1x, and the teacher would never learn otherwise.
    test('no analysis at all is no sheet', () {
      expect(songHasASheet(_song(), null), isFalse);
    });

    test('an analysis that is not ready is no sheet', () {
      expect(
        songHasASheet(
          _song(),
          const SongAnalysisBundle(
            reference: null,
            lyricCues: <LyricSyncCue>[],
            chordCues: <ChordCue>[],
          ),
        ),
        isFalse,
      );
    });

    testWidgets('with no sheet, no parts and no speeds are offered',
        (tester) async {
      await _pumpSheet(tester, sheet: false, sections: _sections);
      expect(find.byKey(const Key('leave_practice_no_sheet')), findsOneWidget);
      expect(find.byKey(const Key('leave_practice_part_1')), findsNothing);
      for (final rate in <String>['½', '¾', '1×']) {
        expect(find.byKey(Key('leave_practice_rate_$rate')), findsNothing);
      }
      // And the words still work, which is the half of this that always does.
      expect(find.byKey(const Key('leave_practice_note')), findsOneWidget);
    });

    testWidgets('with a sheet, both are', (tester) async {
      await _pumpSheet(tester, sheet: true, sections: _sections);
      expect(find.byKey(const Key('leave_practice_no_sheet')), findsNothing);
      expect(find.byKey(const Key('leave_practice_part_1')), findsOneWidget);
      for (final rate in <String>['½', '¾', '1×']) {
        expect(find.byKey(Key('leave_practice_rate_$rate')), findsOneWidget);
      }
    });

    testWidgets('a song with no sheet leaves the whole of it, at its own speed',
        (tester) async {
      await _pumpSheet(tester, sheet: false, sections: _sections);
      await tester.tap(find.byKey(const Key('leave_practice_do')));
      await tester.pumpAndSettle();
      expect(_left?.part.label, 'The whole song');
      expect(_left?.part.rate, 1.0);
      expect(_left?.part.startMs, isNull);
    });
  });

  group('on the song', () {
    testWidgets('a teacher in their own lesson is offered it, by name',
        (tester) async {
      await _openALesson(tester);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      expect(find.text('Leave practice for Jess'), findsOneWidget);
    });

    testWidgets('in a band room the menu does not mention it', (tester) async {
      await _openALesson(tester, teaching: false);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      expect(find.byKey(const Key('song_leave_practice')), findsNothing);
    });

    testWidgets('a part and a few words reach the student', (tester) async {
      final repository = await _openALesson(tester);
      await tester.tap(find.byKey(const Key('song_options_menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('song_leave_practice')));
      await _settle(tester);

      // The song has no sheet in this fake, so the whole of it at its own
      // speed is all there is to leave — which is the case a teacher hits
      // first, before any recording has been made.
      expect(find.text('Leave practice for Jess'), findsWidgets);
      expect(find.byKey(const Key('leave_practice_no_sheet')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('leave_practice_note')),
          'Keep it slow until the change is clean.');
      await _settle(tester);
      await tester.tap(find.byKey(const Key('leave_practice_do')));
      await _settle(tester);

      final left = repository.practiceLeft.single;
      expect(left.studentId, 'student-1');
      expect(left.label, 'The whole song');
      expect(left.rate, 1.0);
      expect(left.note, 'Keep it slow until the change is clean.');
      expect(left.startMs, isNull);

      // Said back to the teacher in the words the student's card will use,
      // and with no time in it.
      expect(find.text('Left for Jess · The whole song'), findsOneWidget);
    });

    testWidgets('leaving practice again on the same song replaces it',
        (tester) async {
      final repository = await _openALesson(tester);
      for (final note in <String>['Slowly.', 'Both hands now.']) {
        await tester.tap(find.byKey(const Key('song_options_menu')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('song_leave_practice')));
        await _settle(tester);
        await tester.enterText(
            find.byKey(const Key('leave_practice_note')), note);
        await _settle(tester);
        await tester.tap(find.byKey(const Key('leave_practice_do')));
        await _settle(tester);
      }
      // Home shows one card a song. Two rows would leave last week's words
      // sitting on it (0143).
      expect(repository.practiceLeft, hasLength(1));
      expect(repository.practiceLeft.single.note, 'Both hands now.');
    });
  });

  testWidgets('the student gets the card a lesson already leaves',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    final song = controller.rooms.expand((room) => room.projects).first;

    // What 0143 writes, as the student's phone reads it back: their own mark,
    // led by the teacher, with nothing played and nothing timed.
    await controller.keepPracticeMark(PracticeMark(
      id: 'left-1',
      projectId: song.id,
      ledBy: 'teacher-1',
      ledByName: 'Maria',
      note: 'Keep it slow until the change is clean.',
      parts: const <PracticePart>[
        PracticePart(label: 'Chorus 2', rate: 0.75, seconds: 0, startMs: 3000, endMs: 6000),
      ],
      updatedAt: DateTime.now(),
    ));

    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SongsScreen(
            displayName: 'Jess',
            onOpenAccount: () {},
            onOpenNotifications: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    final card = find.byKey(const Key('waiting_card_practice-left-1'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('From Maria')),
        findsOneWidget);
    expect(find.descendant(of: card, matching: find.text(song.title)),
        findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.text(
            'Chorus 2 at ¾ · “Keep it slow until the change is clean.”'),
      ),
      findsOneWidget,
    );

    // Nothing about when, and nothing about how long: the seconds on a part
    // put several of them in order and never reach a screen.
    final words = tester
        .widgetList<Text>(find.descendant(of: card, matching: find.byType(Text)))
        .map((text) => text.data ?? '')
        .join(' ');
    expect(words, isNot(contains('ago')));
    expect(words, isNot(contains('minute')));
    expect(words, isNot(matches(RegExp(r'\d+:\d\d'))));
    expect(words, isNot(matches(RegExp(r'\b\d{1,2} Sep'))));
  });
}
