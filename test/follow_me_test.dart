import 'dart:async';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/follow_me_bar.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Follow me: one person leads, everybody else's song moves with them.
///
/// The first slice of Taylor's lesson rooms (16 Sep 2026). What is shared is
/// where the song is -- playing, where, how fast, the part on repeat, which
/// words -- and nothing moves on anybody's phone until they press Follow.
void main() {
  FollowState state({
    bool sheet = true,
    bool synced = true,
    bool playing = true,
    int at = 10000,
    double rate = 1,
    int sent = 1000000,
    int? loopStart,
    int? loopEnd,
    String? line,
  }) =>
      FollowState(
        sheet: sheet,
        synced: synced,
        playing: playing,
        positionMs: at,
        rate: rate,
        sentAt: sent,
        loopStartMs: loopStart,
        loopEndMs: loopEnd,
        lineKey: line,
      );

  group('where the leader is', () {
    test('paused, exactly where it was left', () {
      expect(followTargetMs(state(playing: false), 1009000), 10000);
    });

    test('playing, moved on by the time since, at the song speed', () {
      expect(followTargetMs(state(), 1001500), 11500);
      expect(followTargetMs(state(rate: 0.5), 1002000), 11000);
    });

    test('round again inside the part on repeat', () {
      final looping = state(at: 9000, loopStart: 8000, loopEnd: 10000);
      expect(followTargetMs(looping, 1000500), 9500);
      expect(followTargetMs(looping, 1001500), 8500);
      expect(followTargetMs(looping, 1003500), 8500);
    });

    test('a message from before it was sent is not time travel', () {
      expect(followTargetMs(state(), 999000), 10000);
    });
  });

  group('what the leader sends', () {
    test('the first word, and every decision, at once', () {
      expect(worthSending(null, state()), isTrue);
      expect(worthSending(state(), state(playing: false, sent: 1000010)), isTrue);
      expect(worthSending(state(), state(rate: 0.75, sent: 1000010)), isTrue);
      expect(
        worthSending(state(), state(loopStart: 8000, loopEnd: 12000, sent: 1000010)),
        isTrue,
      );
    });

    test('a song moving as expected is left to the heartbeat', () {
      final last = state();
      expect(worthSending(last, state(at: 10500, sent: 1000500)), isFalse);
      expect(worthSending(last, state(at: 12000, sent: 1002000)), isTrue);
      final paused = state(playing: false);
      expect(worthSending(paused, state(playing: false, sent: 1004000)), isFalse);
      expect(worthSending(paused, state(playing: false, sent: 1005000)), isTrue);
    });

    test('a seek is sent, but not every place a dragging finger passed', () {
      final last = state();
      expect(worthSending(last, state(at: 40000, sent: 1000100)), isFalse);
      expect(worthSending(last, state(at: 40000, sent: 1000300)), isTrue);
    });

    test('by hand, the line on the anchor is what moves', () {
      final last = state(synced: false, playing: false, at: 0, line: 'l1');
      expect(worthSending(last, state(synced: false, playing: false, at: 0, line: 'l1', sent: 1000400)), isFalse);
      expect(worthSending(last, state(synced: false, playing: false, at: 0, line: 'l2', sent: 1000400)), isTrue);
    });

    test('reads back what it wrote, and refuses what is not a state', () {
      final original = state(rate: 0.75, loopStart: 8000, loopEnd: 12000, line: 'x');
      final back = FollowState.fromJson(original.toJson())!;
      expect(back.positionMs, 10000);
      expect(back.rate, 0.75);
      expect(back.loopStartMs, 8000);
      expect(back.loopEndMs, 12000);
      expect(back.lineKey, 'x');
      expect(back.sameDecisions(original), isTrue);
      expect(FollowState.fromJson(null), isNull);
      expect(FollowState.fromJson(<String, dynamic>{'at': 'soon'}), isNull);
      expect(FollowState.fromJson(<String, dynamic>{'at': 1, 'rate': 0, 'sent': 1}), isNull);
      final backwards = FollowState.fromJson(<String, dynamic>{
        'at': 1,
        'rate': 1,
        'sent': 1,
        'loop': <int>[5000, 4000],
      })!;
      expect(backwards.looping, isFalse);
    });
  });

  group("the leader's clock", () {
    test('the fastest message is the best guess', () {
      final clock = LeaderClock();
      expect(clock.offsetMs, isNull);
      // The leader's clock is 5 s ahead; trips took 120, 40 and 300 ms.
      clock.heard(sentAt: 105000, receivedAt: 100120);
      clock.heard(sentAt: 107000, receivedAt: 102040);
      clock.heard(sentAt: 109000, receivedAt: 104300);
      expect(clock.offsetMs, 4960);
      expect(clock.leaderNow(200000), 204960);
    });

    test('forgets old trips, so a corrected clock is followed', () {
      final clock = LeaderClock(window: 2);
      clock.heard(sentAt: 10000, receivedAt: 0);
      clock.heard(sentAt: 1000, receivedAt: 1000);
      clock.heard(sentAt: 2000, receivedAt: 2000);
      expect(clock.offsetMs, 0);
    });
  });

  test('who is here, in names', () {
    SongDevice phone(String device, String user, String name) =>
        SongDevice(device: device, userId: user, displayName: name);
    expect(whoIsHere(<SongDevice>[phone('a', 'u2', 'Jess')], 'u1'), 'Jess is here');
    expect(
      whoIsHere(<SongDevice>[phone('a', 'u2', 'Jess'), phone('b', 'u3', 'Sam')], 'u1'),
      'Jess and Sam are here',
    );
    expect(
      whoIsHere(<SongDevice>[phone('a', 'u2', 'Jess'), phone('b', 'u3', 'Sam'), phone('c', 'u4', 'Ro')], 'u1'),
      'Jess and 2 others are here',
    );
    expect(whoIsHere(<SongDevice>[phone('a', 'u1', 'Taylor')], 'u1'), 'Also open on your other device');
  });

  group('a session between phones', () {
    late _Bus bus;
    late int now;
    int clock() => now;

    setUp(() {
      bus = _Bus();
      now = 1000000;
    });

    FollowSession phone(String device, String user, String name) => FollowSession(
          line: _Line(bus, device, user, name),
          userId: user,
          name: name,
          now: clock,
        );

    test('a lead reaches the others, and nothing moves until Follow', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      final heard = <FollowState>[];
      student.states.listen(heard.add);

      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      expect(student.leader?.name, 'Taylor');
      expect(student.following, isFalse);
      expect(heard, isEmpty);

      student.follow();
      await pumpEventQueue();
      expect(student.following, isTrue);
      expect(heard, hasLength(1));
      expect(teacher.followers, 1);

      now += 1500;
      expect(student.targetMs(), 11500);

      teacher.dispose();
      student.dispose();
    });

    test("a leader whose clock is ahead is still followed to the moment", () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      teacher.lead();
      // The teacher's phone thinks it is five seconds later than it is.
      teacher.publish(state(sent: now + 5000));
      await pumpEventQueue();
      student.follow();
      expect(student.targetMs(), 10000);
      now += 1000;
      expect(student.targetMs(), 11000);
      teacher.dispose();
      student.dispose();
    });

    test('stopping says so, and the follower keeps the song', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      final notes = <String>[];
      student.notes.listen(notes.add);
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();

      teacher.stopLeading();
      await pumpEventQueue();
      expect(student.leader, isNull);
      expect(student.following, isFalse);
      expect(notes, <String>['Taylor stopped leading.']);
      expect(teacher.followers, 0);
      teacher.dispose();
      student.dispose();
    });

    test('two leaders: the later press wins, and both phones agree', () async {
      final taylor = phone('t', 'u1', 'Taylor');
      final jess = phone('j', 'u2', 'Jess');
      final notes = <String>[];
      taylor.notes.listen(notes.add);

      taylor.lead();
      taylor.publish(state(sent: now));
      now += 1000;
      jess.lead();
      jess.publish(state(sent: now));
      await pumpEventQueue();
      expect(jess.leading, isTrue);
      expect(taylor.leading, isFalse);
      expect(taylor.leader?.name, 'Jess');
      expect(notes, <String>['Jess is leading now.']);

      // Taylor's older heartbeat arriving late changes nothing.
      now += 2500;
      jess.publish(state(at: 12500, sent: now));
      await pumpEventQueue();
      expect(jess.leading, isTrue);
      taylor.dispose();
      jess.dispose();
    });

    test('silence means the leader is gone', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();
      now += FollowSession.quietAfterMs - 1000;
      student.checkQuiet();
      expect(student.following, isTrue);
      now += 2000;
      student.checkQuiet();
      expect(student.leader, isNull);
      expect(student.following, isFalse);
      teacher.dispose();
      student.dispose();
    });

    test('a heartbeat does not start a loop between leader and follower', () async {
      // The first two-phone test, 16 Sep: the follower re-announced itself
      // on every heartbeat, the leader took each re-announcement for an
      // arrival and answered at once, and within a minute the server had
      // stopped carrying the song's messages either way.
      final teacherLine = _Line(bus, 't', 'u1', 'Taylor');
      final studentLine = _Line(bus, 's', 'u2', 'Jess');
      final teacher = FollowSession(line: teacherLine, userId: 'u1', name: 'Taylor', now: clock);
      final student = FollowSession(line: studentLine, userId: 'u2', name: 'Jess', now: clock);
      bus.announce();

      teacher.lead();
      teacher.publish(state(sent: now));
      student.follow();
      final start = bus.sent.length;

      // Five seconds of the leader's screen ticking every 50 ms.
      for (var tick = 1; tick <= 100; tick += 1) {
        now += 50;
        teacher.publish(state(sent: now, at: 10000 + tick * 50));
      }
      await pumpEventQueue();
      final sends = bus.sent.length - start;
      expect(sends, lessThanOrEqualTo(3), reason: 'a heartbeat every two seconds, not every tick');
      expect(studentLine.marks, 1);
      expect(student.following, isTrue);
      expect(teacher.followers, 1);
      teacher.dispose();
      student.dispose();
    });

    test('somebody new arriving is told at once; somebody flickering is not', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final studentLine = _Line(bus, 's', 'u2', 'Jess');
      bus.announce();
      teacher.lead();
      teacher.publish(state(sent: now));
      final start = bus.sent.length;

      // The same phone dropping off presence and coming back.
      bus.here.remove('s');
      bus.announce();
      bus.here['s'] = SongDevice(device: 's', userId: 'u2', displayName: studentLine.name);
      bus.announce();
      now += 300;
      teacher.publish(state(sent: now, at: 10300));
      expect(bus.sent.length, start);

      // A phone never seen on this song.
      _Line(bus, 'r', 'u3', 'Ro').arrive();
      now += 50;
      teacher.publish(state(sent: now, at: 10350));
      expect(bus.sent.length, start + 1);
      teacher.dispose();
    });

    test('a follower who loses touch follows again when the same leader comes back', () async {
      // The second two-phone test, 16 Sep: the follower dropped for a few
      // seconds while the leader's phone was busy, never followed again,
      // and so never received the teacher's note.
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      final notes = <String>[];
      final endings = <FollowEnded>[];
      student.notes.listen(notes.add);
      student.endings.listen(endings.add);
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();

      now += FollowSession.quietAfterMs + 1000;
      student.checkQuiet();
      await pumpEventQueue();
      expect(student.following, isFalse);
      expect(endings.single.byLeader, isTrue);
      expect(endings.single.stopped, isFalse, reason: 'losing touch is not the lesson ending');
      expect(notes.last, 'Lost touch with Taylor. Following again if they come back.');

      now += 20000;
      teacher.publish(state(sent: now, at: 40000));
      await pumpEventQueue();
      expect(student.following, isTrue);
      expect(notes.last, 'Back with Taylor.');
      expect(teacher.followers, 1);
      teacher.dispose();
      student.dispose();
    });

    test('but not once a minute and a half has gone', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();
      now += FollowSession.quietAfterMs + 1000;
      student.checkQuiet();

      now += FollowSession.rejoinWithinMs + 1000;
      teacher.publish(state(sent: now, at: 200000));
      await pumpEventQueue();
      expect(student.leader?.name, 'Taylor');
      expect(student.following, isFalse);
      teacher.dispose();
      student.dispose();
    });

    test('the note still arrives when the leader stops while this phone had lost touch', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      final endings = <FollowEnded>[];
      student.endings.listen(endings.add);
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();
      now += FollowSession.quietAfterMs + 1000;
      student.checkQuiet();

      teacher.stopLeading(note: 'Keep it slow');
      await pumpEventQueue();
      expect(endings, hasLength(2));
      expect(endings.last.stopped, isTrue);
      expect(endings.last.note, 'Keep it slow');
      expect(endings.last.said, 'Taylor stopped leading.');
      teacher.dispose();
      student.dispose();
    });

    test('taking the song back forgets the leader it was waiting for', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();
      now += FollowSession.quietAfterMs + 1000;
      student.checkQuiet();

      student.unfollow();
      now += 5000;
      teacher.publish(state(sent: now, at: 30000));
      await pumpEventQueue();
      expect(student.following, isFalse);
      teacher.dispose();
      student.dispose();
    });

    test('a check that is itself late does not blame the leader', () async {
      final teacher = phone('t', 'u1', 'Taylor');
      final student = phone('s', 'u2', 'Jess');
      teacher.lead();
      teacher.publish(state(sent: now));
      await pumpEventQueue();
      student.follow();

      now += 3000;
      student.checkQuiet();
      // This phone stalls for twelve seconds; the leader's messages are
      // still in the queue behind the check.
      now += 12000;
      student.checkQuiet();
      expect(student.following, isTrue);
      // On time again, and still nothing: that is the leader.
      now += 2000;
      student.checkQuiet();
      expect(student.following, isFalse);
      teacher.dispose();
      student.dispose();
    });

    test('leading your own tablet from your phone', () async {
      final phoneOne = phone('p', 'u1', 'Taylor');
      final tablet = phone('t', 'u1', 'Taylor');
      bus.announce();
      phoneOne.lead();
      phoneOne.publish(state(sent: now));
      await pumpEventQueue();
      expect(tablet.leader?.name, 'Taylor');
      expect(whoIsHere(tablet.others, 'u1'), 'Also open on your other device');
      phoneOne.dispose();
      tablet.dispose();
    });
  });

  group('on the Perform screen', () {
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

    Future<void> boot(WidgetTester tester, FollowSession session) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle, together: session, me: 'u1'),
      ));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> close(WidgetTester tester, List<FollowSession> sessions) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      for (final session in sessions) {
        session.dispose();
      }
    }

    testWidgets('alone there is nothing to lead; somebody arriving offers it', (tester) async {
      final bus = _Bus();
      final mine = FollowSession(line: _Line(bus, 'me', 'u1', 'Taylor'), userId: 'u1', name: 'Taylor');
      await boot(tester, mine);
      expect(find.byKey(const Key('together_row')), findsNothing);

      _Line(bus, 'jess', 'u2', 'Jess').arrive();
      await tester.pump();
      expect(find.byKey(const Key('together_lead')), findsOneWidget);
      expect(find.text('Jess is here'), findsOneWidget);

      await tester.tap(find.byKey(const Key('together_lead')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(mine.leading, isTrue);
      expect(find.text('Leading · nobody following yet'), findsOneWidget);
      final lead = bus.sent.lastWhere((message) => message['kind'] == 'lead');
      final sent = FollowState.fromJson(lead['state'])!;
      expect(sent.sheet, isTrue);
      expect(sent.synced, isTrue);
      expect(sent.playing, isFalse);

      // A decision goes out at once.
      await tester.tap(find.byKey(const Key('live_rate_slower')));
      await tester.pump(const Duration(milliseconds: 120));
      final slower = FollowState.fromJson(
        bus.sent.lastWhere((message) => message['kind'] == 'lead')['state'],
      )!;
      expect(slower.rate, 0.9);

      await tester.tap(find.byKey(const Key('together_stop_leading')));
      await tester.pump();
      expect(mine.leading, isFalse);
      expect(bus.sent.last['kind'], 'end');
      await close(tester, <FollowSession>[mine]);
    });

    testWidgets('following moves the song, and touching it hands it back', (tester) async {
      final bus = _Bus();
      final mine = FollowSession(line: _Line(bus, 'me', 'u1', 'Jess'), userId: 'u1', name: 'Jess');
      final teacher = _Line(bus, 'teacher', 'u2', 'Taylor')..arrive();
      unawaited(teacher.sendFollow(<String, dynamic>{
        'kind': 'lead',
        'device': 'teacher',
        'user': 'u2',
        'name': 'Taylor',
        'since': DateTime.now().millisecondsSinceEpoch,
        'state': state(
          playing: false,
          at: 3500,
          rate: 0.75,
          loopStart: 3000,
          loopEnd: 6000,
          sent: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      }));
      await tester.pump();
      await boot(tester, mine);
      expect(find.byKey(const Key('together_follow')), findsOneWidget);
      expect(find.text('Taylor is leading'), findsOneWidget);

      await tester.tap(find.byKey(const Key('together_follow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(mine.following, isTrue);
      expect(find.text('Following Taylor'), findsOneWidget);
      expect(find.text('0:03'), findsOneWidget);
      ChoiceChip chip(String key) => tester.widget<ChoiceChip>(find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(ChoiceChip),
          ));
      expect(find.text('¾'), findsOneWidget, reason: "the leader's speed is on the student's screen");
      expect(chip('live_loop_1').selected, isTrue);

      // The student makes the words bigger: still following.
      await tester.tap(find.byTooltip('Larger lyrics'));
      await tester.pump();
      expect(mine.following, isTrue);

      // The student presses Start: the song is theirs now.
      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      expect(mine.following, isFalse);
      expect(find.text('You have the song now. Follow again from the bar.'), findsOneWidget);
      expect(find.byKey(const Key('together_follow')), findsOneWidget);
      await close(tester, <FollowSession>[mine]);
    });
  });

  testWidgets('heartbeats do not hold the controls over the words', (tester) async {
    final bus = _Bus();
    final mine = FollowSession(line: _Line(bus, 'me', 'u1', 'Jess'), userId: 'u1', name: 'Jess');
    final teacher = _Line(bus, 'teacher', 'u2', 'Taylor')..arrive();
    final since = DateTime.now().millisecondsSinceEpoch;
    void beat() => unawaited(teacher.sendFollow(<String, dynamic>{
          'kind': 'lead',
          'device': 'teacher',
          'user': 'u2',
          'name': 'Taylor',
          'since': since,
          'state': FollowState(
            sheet: true,
            synced: true,
            playing: true,
            positionMs: 1000,
            rate: 1,
            sentAt: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        }));
    beat();
    mine.follow();
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LivePerformanceScreen(
        project: SongProject(
          id: 'song-beat',
          roomId: 'room',
          accountId: 'account',
          title: 'Weathervane',
          createdAt: DateTime(2026, 9, 16),
          updatedAt: DateTime(2026, 9, 16),
          contributions: <Contribution>[
            Contribution(
              id: 'line-1',
              projectId: 'song-beat',
              authorId: 'u2',
              authorName: 'Taylor',
              body: 'Turning in the wind',
              colorValue: 0xFFFF8A4C,
              createdAt: DateTime(2026, 9, 16),
              position: 1,
            ),
          ],
        ),
        analysis: const SongAnalysisBundle(
          reference: ReferenceTrack(
            projectId: 'song-beat',
            fileId: 'file',
            storagePath: 'room/song-beat/reference.m4a',
            displayName: 'Weathervane.m4a',
            state: SongAnalysisState.ready,
            durationMs: 60000,
            transcriptText: 'turning in the wind',
            transcriptWords: <TranscriptWord>[
              TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
              TranscriptWord(word: 'wind', startMs: 800, endMs: 2200),
            ],
          ),
          lyricCues: <LyricSyncCue>[],
          chordCues: <ChordCue>[],
        ),
        together: mine,
        me: 'u1',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    double controls() => tester
        .widget<AnimatedOpacity>(find
            .ancestor(of: find.byKey(const Key('live_play_pause')), matching: find.byType(AnimatedOpacity))
            .first)
        .opacity;
    expect(controls(), 1);
    for (var second = 0; second < 3; second += 1) {
      await tester.pump(const Duration(seconds: 2));
      beat();
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(mine.following, isTrue);
    expect(controls(), 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    mine.dispose();
  });

  testWidgets('the banner on the song names the leader and follows', (tester) async {
    var followed = 0;
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: FollowBanner(leaderName: 'Taylor', onFollow: () => followed++),
      ),
    ));
    expect(find.text('Taylor is leading this song'), findsOneWidget);
    await tester.tap(find.byKey(const Key('follow_banner_follow')));
    expect(followed, 1);
  });
}

/// Every phone on one song, in a test: what one sends, all of them hear.
class _Bus {
  // Lives as long as one test; nothing outlives it to leak into.
  // ignore: close_sinks
  final StreamController<Map<String, dynamic>> messages =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
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

  /// Opens the song on this phone, as far as everybody else can see.
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

  /// How many times this phone told presence who it follows.
  int marks = 0;

  /// As the real server delivers it: a presence update reaches everyone
  /// else as this phone leaving and then arriving again.
  @override
  Future<void> markFollowing(String? following) async {
    marks += 1;
    bus.here.remove(device);
    bus.announce();
    bus.here[device] = SongDevice(
      device: device,
      userId: userId,
      displayName: name,
      following: following,
    );
    bus.announce();
  }
}
