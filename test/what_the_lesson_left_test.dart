import 'dart:async';
import 'dart:math' as math;

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_marks.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the lesson left.
///
/// Follow me moves a student's song with the teacher's; when it ends, the
/// part they worked on, the speed they got it to and the teacher's note are
/// kept on the student's own account, and Home offers them back with one
/// verb. The lesson is one hour of the week; this is the other 167.
void main() {
  FollowState state({
    bool playing = true,
    bool synced = true,
    int at = 3000,
    double rate = 0.75,
    int sent = 1000000,
    int? loopStart = 3000,
    int? loopEnd = 6000,
  }) =>
      FollowState(
        sheet: true,
        synced: synced,
        playing: playing,
        positionMs: at,
        rate: rate,
        sentAt: sent,
        loopStartMs: loopStart,
        loopEndMs: loopEnd,
      );

  String label(int? start, int? end) => start == null ? 'The whole song' : 'Chorus';

  group('what counts as worked on', () {
    test('playing time goes to the part and speed that were playing', () {
      final log = PracticeLog();
      for (var i = 0; i <= 15; i++) {
        log.heard(state(sent: 1000000 + i * 2000), 1000000 + i * 2000);
      }
      final parts = log.parts(label);
      expect(parts, hasLength(1));
      expect(parts.single.label, 'Chorus');
      expect(parts.single.startMs, 3000);
      expect(parts.single.rate, 0.75);
      expect(parts.single.seconds, 30);
    });

    test('paused time, and a silence longer than a heartbeat, are not practice', () {
      final log = PracticeLog();
      log.heard(state(playing: false, sent: 0), 0);
      log.heard(state(sent: 60000), 60000);
      // A minute of nothing heard: only the cap is counted.
      log.heard(state(sent: 120000), 120000);
      log.pause(120000);
      expect(log.parts(label), isEmpty, reason: '6 seconds is under the threshold');
    });

    test('a run-through at full speed is rehearsal, and keeps nothing', () {
      final log = PracticeLog();
      for (var i = 0; i <= 60; i++) {
        log.heard(state(rate: 1, loopStart: null, loopEnd: null, sent: i * 2000), i * 2000);
      }
      expect(log.parts(label), isEmpty);
    });

    test('the whole song slowed down is practice', () {
      final log = PracticeLog();
      for (var i = 0; i <= 15; i++) {
        log.heard(state(rate: 0.5, loopStart: null, loopEnd: null, sent: i * 2000), i * 2000);
      }
      final part = log.parts(label).single;
      expect(part.label, 'The whole song');
      expect(practiceSaid(part), 'The whole song at ½');
    });

    test('most worked on first, and three at most', () {
      final log = PracticeLog();
      var t = 0;
      void play(int start, int seconds, double rate) {
        for (var i = 0; i < seconds ~/ 2; i++) {
          log.heard(state(loopStart: start, loopEnd: start + 3000, rate: rate, sent: t), t);
          t += 2000;
        }
      }

      play(0, 24, 1);
      play(3000, 60, 0.75);
      play(6000, 40, 0.5);
      play(9000, 30, 0.75);
      log.pause(t);
      final parts = log.parts((start, _) => 'Part ${start! ~/ 3000}');
      expect(parts.map((part) => part.label), <String>['Part 1', 'Part 2', 'Part 3']);
    });

    test('said the way a musician says it', () {
      const chorus = PracticePart(label: 'Chorus 2', rate: 0.75, seconds: 80, startMs: 1, endMs: 2);
      const verse = PracticePart(label: 'Verse 1', rate: 1, seconds: 40, startMs: 3, endMs: 4);
      const bridge = PracticePart(label: 'Bridge', rate: 0.5, seconds: 30, startMs: 5, endMs: 6);
      PracticeMark mark(List<PracticePart> parts) => PracticeMark(
            id: 'm',
            projectId: 'p',
            ledByName: 'Taylor',
            parts: parts,
            updatedAt: DateTime(2026, 9, 16),
          );
      expect(practiceWorked(mark(const <PracticePart>[chorus])), 'Chorus 2 at ¾');
      expect(practiceWorked(mark(const <PracticePart>[chorus, verse])), 'Chorus 2 at ¾ and Verse 1');
      expect(practiceWorked(mark(const <PracticePart>[chorus, verse, bridge])), 'Chorus 2 at ¾ and 2 more');
      expect(practiceWorked(mark(const <PracticePart>[])), isNull);
      expect(worthKeeping(const <PracticePart>[], '  '), isFalse);
      expect(worthKeeping(const <PracticePart>[], 'Slow down'), isTrue);
    });

    test('a part reads back, and a broken one is skipped rather than fatal', () {
      const part = PracticePart(label: 'Chorus', rate: 0.75, seconds: 30, startMs: 3000, endMs: 6000);
      final back = PracticePart.fromJson(part.toJson())!;
      expect(back.startMs, 3000);
      expect(back.rate, 0.75);
      expect(PracticePart.fromJson(<String, dynamic>{'label': '', 'rate': 1}), isNull);
      expect(PracticePart.fromJson(<String, dynamic>{'label': 'x', 'rate': 'fast'}), isNull);
      final whole = PracticePart.fromJson(<String, dynamic>{'label': 'x', 'rate': 1, 'start': 5, 'end': 2})!;
      expect(whole.isLoop, isFalse);
    });

    test('a mark is named with a real UUID', () {
      final id = newPracticeMarkId(math.Random(7));
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id),
        isTrue,
        reason: id,
      );
      expect(newPracticeMarkId(), isNot(newPracticeMarkId()));
    });
  });

  group('how following ends', () {
    test('a leader who stops leaves their note with whoever followed', () async {
      final bus = _Bus();
      final teacher = FollowSession(line: _Line(bus, 't', 'u1', 'Taylor'), userId: 'u1', name: 'Taylor');
      final student = FollowSession(line: _Line(bus, 's', 'u2', 'Jess'), userId: 'u2', name: 'Jess');
      final endings = <FollowEnded>[];
      student.endings.listen(endings.add);
      bus.announce();

      teacher.lead();
      teacher.publish(state(sent: DateTime.now().millisecondsSinceEpoch));
      student.follow();
      teacher.stopLeading(note: '  Keep it slow until the change is clean  ');
      await pumpEventQueue();

      expect(endings, hasLength(1));
      expect(endings.single.byLeader, isTrue);
      expect(endings.single.leaderName, 'Taylor');
      expect(endings.single.leaderUserId, 'u1');
      expect(endings.single.note, 'Keep it slow until the change is clean');
      expect(endings.single.said, 'Taylor stopped leading.');
      teacher.dispose();
      student.dispose();
    });

    test('a note is capped, and taking the song back is not the leader stopping', () async {
      final bus = _Bus();
      final teacher = FollowSession(line: _Line(bus, 't', 'u1', 'Taylor'), userId: 'u1', name: 'Taylor');
      final student = FollowSession(line: _Line(bus, 's', 'u2', 'Jess'), userId: 'u2', name: 'Jess');
      final endings = <FollowEnded>[];
      student.endings.listen(endings.add);
      bus.announce();

      teacher.lead();
      teacher.publish(state(sent: DateTime.now().millisecondsSinceEpoch));
      student.follow();
      student.unfollow();
      await pumpEventQueue();
      expect(endings.single.byLeader, isFalse);
      expect(endings.single.note, isNull);

      student.follow();
      teacher.stopLeading(note: 'x' * 400);
      await pumpEventQueue();
      expect(endings.last.note, hasLength(leaderNoteMax));
      teacher.dispose();
      student.dispose();
    });
  });

  final day = DateTime(2026, 9, 16);
  final project = SongProject(
    id: 'song-lesson',
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: day,
    updatedAt: day,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: 'song-lesson',
        authorId: 'u1',
        authorName: 'Taylor',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: day,
        position: 1,
      ),
    ],
  );
  const sections = <StructureSection>[
    StructureSection(startMs: 0, endMs: 3000, label: 'Verse'),
    StructureSection(startMs: 3000, endMs: 6000, label: 'Chorus'),
  ];
  const bundle = SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-lesson',
      fileId: 'file',
      storagePath: 'room/song-lesson/reference.m4a',
      displayName: 'Weathervane.m4a',
      state: SongAnalysisState.ready,
      durationMs: 6000,
      transcriptText: 'turning in the wind',
      transcriptWords: <TranscriptWord>[
        TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
        TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
        TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
        TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
      ],
      structureSections: sections,
    ),
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[],
  );

  Future<void> sized(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  ChoiceChip chip(WidgetTester tester, String key) => tester.widget<ChoiceChip>(find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(ChoiceChip),
      ));

  group('on the Perform screen', () {
    testWidgets('a followed lesson is kept, with the note, and the phone says where', (tester) async {
      await sized(tester);
      final bus = _Bus();
      final mine = FollowSession(line: _Line(bus, 'me', 'u2', 'Jess'), userId: 'u2', name: 'Jess');
      final teacher = _Line(bus, 'teacher', 'u1', 'Taylor')..arrive();
      final kept = <PracticeMark>[];
      final start = DateTime.now().millisecondsSinceEpoch;
      void beat(int i) => unawaited(teacher.sendFollow(<String, dynamic>{
            'kind': 'lead',
            'device': 'teacher',
            'user': 'u1',
            'name': 'Taylor',
            'since': start,
            'state': state(at: 3000 + i * 1500, sent: start + i * 2000).toJson(),
          }));

      beat(0);
      mine.follow();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: bundle,
          together: mine,
          me: 'u2',
          keepPractice: kept.add,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 1; i <= 15; i++) {
        beat(i);
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The student takes the song back for a moment: kept quietly, same mark.
      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      expect(kept, hasLength(1));
      expect(kept.single.ledByName, 'Taylor');
      expect(kept.single.parts.single.label, 'Chorus');
      final firstId = kept.single.id;

      // Follows again; the teacher plays on, then stops with a note.
      await tester.tap(find.byKey(const Key('together_follow')));
      await tester.pump();
      for (var i = 16; i <= 20; i++) {
        beat(i);
        await tester.pump(const Duration(milliseconds: 20));
      }
      unawaited(teacher.sendFollow(<String, dynamic>{
        'kind': 'end',
        'device': 'teacher',
        'note': 'Keep it slow until the change is clean',
      }));
      await tester.pump();
      // The first sentence ("Taylor stopped leading.") slides away before
      // the one saying where the lesson went comes in.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));

      expect(kept, hasLength(2));
      final mark = kept.last;
      expect(mark.id, firstId, reason: 'one lesson, one mark, however often it is saved');
      expect(mark.note, 'Keep it slow until the change is clean');
      expect(mark.ledBy, 'u1');
      expect(mark.parts.single.rate, 0.75);
      expect(mark.parts.single.seconds, greaterThanOrEqualTo(40));
      expect(find.text('Taylor stopped leading. Chorus at ¾ is on your Home to practise.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      // What the teacher led stays the teacher's, all the way out. Practising
      // on your own keeps a mark of its own now (Every Musician, Same Song,
      // 17 September 2026), and an hour of following must not become one.
      expect(kept, hasLength(2));
      expect(kept.map((each) => each.ledBy), everyElement('u1'));
      expect(kept.map((each) => each.ledByName), everyElement('Taylor'));
      mine.dispose();
    });

    testWidgets('closing Perform while following keeps the lesson, without rebuilding a locked tree', (tester) async {
      await sized(tester);
      final bus = _Bus();
      final mine = FollowSession(line: _Line(bus, 'me', 'u2', 'Jess'), userId: 'u2', name: 'Jess');
      final teacher = _Line(bus, 'teacher', 'u1', 'Taylor')..arrive();
      // Home, in miniature: something on the screen underneath that
      // rebuilds when a mark arrives, the way the real Home does.
      final marks = ValueNotifier<List<PracticeMark>>(const <PracticeMark>[]);
      addTearDown(marks.dispose);
      final start = DateTime.now().millisecondsSinceEpoch;
      void beat(int i) => unawaited(teacher.sendFollow(<String, dynamic>{
            'kind': 'lead',
            'device': 'teacher',
            'user': 'u1',
            'name': 'Taylor',
            'since': start,
            'state': state(at: 3000, sent: start + i * 2000).toJson(),
          }));
      beat(0);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: <Widget>[
                ValueListenableBuilder<List<PracticeMark>>(
                  valueListenable: marks,
                  builder: (_, kept, __) => Text('kept ${kept.length}'),
                ),
                TextButton(
                  onPressed: () {
                    mine.follow();
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => LivePerformanceScreen(
                        project: project,
                        analysis: bundle,
                        together: mine,
                        me: 'u2',
                        keepPractice: (mark) => marks.value = <PracticeMark>[...marks.value, mark],
                      ),
                    ));
                  },
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      for (var i = 1; i <= 15; i++) {
        beat(i);
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tester.tap(find.byKey(const Key('close_live_mode')));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(marks.value, hasLength(1));
      expect(marks.value.single.parts.single.label, 'Chorus');
      expect(find.text('kept 1'), findsOneWidget);
      expect(mine.following, isFalse);
      mine.dispose();
    });

    testWidgets('losing touch mid-lesson keeps one mark, and the note still arrives', (tester) async {
      await sized(tester);
      final bus = _Bus();
      var clock = DateTime.now().millisecondsSinceEpoch;
      final mine = FollowSession(
        line: _Line(bus, 'me', 'u2', 'Jess'),
        userId: 'u2',
        name: 'Jess',
        now: () => clock,
      );
      final teacher = _Line(bus, 'teacher', 'u1', 'Taylor')..arrive();
      final kept = <PracticeMark>[];
      final start = clock;
      void beat(int i) => unawaited(teacher.sendFollow(<String, dynamic>{
            'kind': 'lead',
            'device': 'teacher',
            'user': 'u1',
            'name': 'Taylor',
            'since': start,
            'state': state(at: 3000, sent: start + i * 2000).toJson(),
          }));

      beat(0);
      mine.follow();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: bundle,
          together: mine,
          me: 'u2',
          keepPractice: kept.add,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 1; i <= 12; i++) {
        clock += 2000;
        beat(i);
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The leader's phone goes quiet for twelve seconds.
      clock += 12000;
      mine.checkQuiet();
      await tester.pump();
      expect(mine.following, isFalse);
      expect(kept, hasLength(1), reason: 'what was worked on is kept at once, in case they never come back');
      final firstId = kept.single.id;

      for (var i = 19; i <= 24; i++) {
        clock += 2000;
        beat(i);
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(mine.following, isTrue);

      unawaited(teacher.sendFollow(<String, dynamic>{
        'kind': 'end',
        'device': 'teacher',
        'note': 'Keep it slow until the change is clean',
      }));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(kept.last.id, firstId, reason: 'one lesson, one mark, dropout and all');
      expect(kept.last.note, 'Keep it slow until the change is clean');
      expect(find.text('Taylor stopped leading. Chorus at ¾ is on your Home to practise.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      mine.dispose();
    });

    testWidgets('a run-through that practised nothing keeps nothing', (tester) async {
      await sized(tester);
      final bus = _Bus();
      final mine = FollowSession(line: _Line(bus, 'me', 'u2', 'Jess'), userId: 'u2', name: 'Jess');
      final teacher = _Line(bus, 'teacher', 'u1', 'Taylor')..arrive();
      final kept = <PracticeMark>[];
      final start = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i <= 3; i++) {
        unawaited(teacher.sendFollow(<String, dynamic>{
          'kind': 'lead',
          'device': 'teacher',
          'user': 'u1',
          'name': 'Taylor',
          'since': start,
          'state': state(rate: 1, loopStart: null, loopEnd: null, sent: start + i * 2000).toJson(),
        }));
        if (i == 0) mine.follow();
      }
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle, together: mine, me: 'u2', keepPractice: kept.add),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(teacher.sendFollow(<String, dynamic>{'kind': 'end', 'device': 'teacher'}));
      await tester.pump();
      expect(kept, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      mine.dispose();
    });

    testWidgets('stopping with somebody following asks for a note, and can be taken back', (tester) async {
      await sized(tester);
      final bus = _Bus();
      final mine = FollowSession(line: _Line(bus, 'me', 'u1', 'Taylor'), userId: 'u1', name: 'Taylor');
      final student = _Line(bus, 'student', 'u2', 'Jess')..arrive();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle, together: mine, me: 'u1'),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('together_lead')));
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(student.markFollowing('me'));
      await tester.pump();
      expect(find.text('Leading · 1 following'), findsOneWidget);

      await tester.tap(find.byKey(const Key('together_stop_leading')));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.text('Leave them something to practise from?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('leave_a_note_keep_leading')));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(mine.leading, isTrue);

      await tester.tap(find.byKey(const Key('together_stop_leading')));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await tester.enterText(find.byKey(const Key('leave_a_note_text')), 'Keep it slow');
      await tester.pump();
      expect(find.text('Stop and leave the note'), findsOneWidget);
      await tester.tap(find.byKey(const Key('leave_a_note_stop')));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(mine.leading, isFalse);
      expect(bus.sent.last, <String, dynamic>{'kind': 'end', 'device': 'me', 'note': 'Keep it slow'});

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      mine.dispose();
    });

    testWidgets('opened to practise: on the part, at the speed, waiting for Start', (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: bundle,
          practise: const PracticePart(label: 'Chorus', rate: 0.75, seconds: 60, startMs: 3000, endMs: 6000),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(chip(tester, 'live_rate_0.75').selected, isTrue);
      expect(chip(tester, 'live_loop_1').selected, isTrue);
      expect(find.text('0:03'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });
  });

  testWidgets('Home offers it back: from whom, what, their words, and Practise', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    final song = controller.rooms.expand((room) => room.projects).first;
    await controller.keepPracticeMark(PracticeMark(
      id: 'mark-1',
      projectId: song.id,
      ledBy: 'u1',
      ledByName: 'Taylor',
      note: 'Keep it slow',
      parts: const <PracticePart>[
        PracticePart(label: 'Chorus 2', rate: 0.75, seconds: 80, startMs: 3000, endMs: 6000),
      ],
      updatedAt: DateTime.now(),
    ));
    expect((await repository.myPracticeMarks()).single.note, 'Keep it slow');

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

    final card = find.byKey(const Key('waiting_card_practice-mark-1'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('From Taylor')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text(song.title)), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Chorus 2 at ¾ · “Keep it slow”')), findsOneWidget);

    await tester.tap(find.byKey(const Key('waiting_do_practice-mark-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final perform = tester.widget<LivePerformanceScreen>(find.byType(LivePerformanceScreen));
    expect(perform.project.id, song.id);
    expect(perform.practise?.label, 'Chorus 2');
    expect(perform.practise?.rate, 0.75);
  });
}

/// Every phone on one song, in a test: what one sends, all of them hear.
class _Bus {
  // Lives as long as one test; nothing outlives it to leak into.
  // ignore: close_sinks
  final StreamController<Map<String, dynamic>> messages =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  // ignore: close_sinks
  final StreamController<List<SongDevice>> devices =
      StreamController<List<SongDevice>>.broadcast(sync: true);
  final Map<String, SongDevice> here = <String, SongDevice>{};
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  void announce() => devices.add(here.values.toList(growable: false));
}

class _Line implements FollowLine {
  _Line(this.bus, this.device, this.userId, this.name) {
    bus.here[device] = SongDevice(device: device, userId: userId, displayName: name);
  }

  final _Bus bus;
  @override
  final String device;
  final String userId;
  final String name;

  void arrive() => bus.announce();

  @override
  Stream<Map<String, dynamic>> get followMessages => bus.messages.stream;

  @override
  Stream<List<SongDevice>> get devices => bus.devices.stream;

  @override
  Future<void> sendFollow(Map<String, dynamic> message) async {
    bus.sent.add(message);
    bus.messages.add(message);
  }

  @override
  Future<void> markFollowing(String? following) async {
    bus.here[device] = SongDevice(device: device, userId: userId, displayName: name, following: following);
    bus.announce();
  }
}
