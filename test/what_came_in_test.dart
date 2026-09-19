import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/sent_take.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/lessons/what_came_in.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Listen to what came in, and answer at the moment.
///
/// Every Musician, Same Song, 17 September 2026, build-order slice 22: the
/// teacher's listening desk. A hand-in has worked since 0057 and 0129, and
/// until now a teacher with nine students opened nine rooms to hear it.
///
/// Four things have to hold. The desk is what students sent and nothing
/// else -- not a draft, not the teacher's own demonstration in the lesson
/// room, not a take in a band room -- and it is in arrival order, so the
/// one that came in last is the last. A row says who played it and what the
/// song is, and says nothing else: there is no date on the screen because
/// there is no date in the answer. The keys are the pass: Space plays, N
/// pins a note at the playhead, Enter moves on -- and a phone, which has no
/// N, can still answer, at a moment that is a place in the song and not a
/// place in the take's file. And it is reachable, from the lesson link
/// screen whether or not a link is open, and from Home when something has
/// arrived.

/// A player a test can press Space at.
///
/// The real one is [NowPlaying], which reaches for a platform audio player
/// a widget test has not got. This one remembers what it was asked to do,
/// which is the whole of what the keys are supposed to do.
class _AFakePlayer extends ChangeNotifier implements ListeningToTakes {
  String? _path;
  bool _playing = false;
  int _atMs = 0;

  /// Every take this was asked to start, in order.
  final List<String> started = <String>[];

  @override
  Future<void> toggle(SentTake take) async {
    if (_path == take.storagePath) {
      _playing = !_playing;
      notifyListeners();
      return;
    }
    await play(take);
  }

  @override
  Future<void> play(SentTake take) async {
    _path = take.storagePath;
    _playing = true;
    _atMs = 0;
    started.add(take.takeId);
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  String? get playingPath => _path;

  @override
  bool get playing => _playing;

  @override
  int get atMs => _atMs;

  /// The playhead, moved to where the teacher is listening.
  void listeningAt(int ms) {
    _atMs = ms;
    notifyListeners();
  }
}

/// A teacher with two lessons, and one take sent from each.
///
/// Jaylen's came first, so it is the top of the pass and Maya's is the end
/// of it. Both lessons also hold something that is not a hand-in.
Future<({
  InMemoryMusicRepository repository,
  String fromJaylen,
  String fromMaya,
  String herSong,
})> _aStudio() async {
  final repository = InMemoryMusicRepository.seeded();
  final hers = repository.teachALesson(studentId: 'student-maya', studentName: 'Maya');
  final his = repository.teachALesson(studentId: 'student-jaylen', studentName: 'Jaylen');
  final herSong = await repository.createSong(room: hers, title: 'Gymnopédie no 1');
  final hisSong = await repository.createSong(room: his, title: 'Clair de lune');

  final fromJaylen = repository.recordTake(hisSong.id, part: 'piano', by: 'student-jaylen');
  final fromMaya = repository.recordTake(herSong.id, part: 'piano', by: 'student-maya');
  // Recorded and not sent: hers alone, and not a hand-in (0057).
  repository.recordTake(herSong.id, part: 'piano', by: 'student-maya', shared: false);
  // And the teacher's own demonstration in her room, which is not one either.
  repository.recordTake(herSong.id, part: 'piano');

  return (
    repository: repository,
    fromJaylen: fromJaylen,
    fromMaya: fromMaya,
    herSong: herSong.id,
  );
}

Future<_AFakePlayer> _openTheDesk(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  bool onKeyboard = true,
}) async {
  final player = _AFakePlayer();
  addTearDown(player.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: WhatCameInScreen(
      repository: repository,
      listening: player,
      onKeyboard: onKeyboard,
    ),
  ));
  await tester.pumpAndSettle();
  return player;
}

/// What Home's row is given, rather than what a lazy list has built so far.
List<WaitingItem> _cameInCards(WidgetTester tester) => tester
    .widget<WaitingOnYou>(find.byType(WaitingOnYou))
    .items
    .where((item) => item.kind == WaitingKind.cameIn)
    .toList();

Future<MusicBetaController> _openHome(
  WidgetTester tester,
  InMemoryMusicRepository repository,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  SetAside.resetForTesting();
  await SetAside.load();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(390, 1000);
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

void main() {
  group('only what was sent', () {
    test('the desk is the takes students sent, oldest first', () async {
      final studio = await _aStudio();

      final came = await studio.repository.takesSentToMe();

      expect(
        came.map((take) => take.takeId).toList(),
        <String>[studio.fromJaylen, studio.fromMaya],
        reason: 'the pass is not in the order the takes arrived',
      );
      expect(came.last.studentName, 'Maya');
      expect(came.last.songTitle, 'Gymnopédie no 1');
      expect(came.first.studentName, 'Jaylen');
    });

    test('a draft, a teacher\'s own take and a band room are not hand-ins',
        () async {
      final studio = await _aStudio();

      final came = await studio.repository.takesSentToMe();

      // Two takes, from two lessons. The seeded repository already holds a
      // band room with two shared takes on a song in it, and a draft and a
      // demonstration sit in the lesson room beside Maya's hand-in.
      expect(came, hasLength(2));
      expect(
        came.every((take) => take.studentId != 'preview-user'),
        isTrue,
        reason: 'the teacher\'s own playing is in their own hand-in queue',
      );
      expect(
        came.any((take) => take.songTitle == 'Ladder Of Life'),
        isFalse,
        reason: 'a band room\'s takes reached the teaching desk',
      );
    });

    test('a student reads nothing, not even their own', () async {
      final repository = InMemoryMusicRepository.seeded()
        ..callStanding = CallStanding.adult
        ..offerLesson(
          code: '0123456789ab',
          title: 'Guitar lessons',
          teacherName: 'Maria',
        );
      final roomId = await repository.joinLessonLink('0123-4567-89ab');
      final room = (await repository.loadRooms()).firstWhere((each) => each.id == roomId);
      final song = await repository.createSong(room: room, title: 'My first tune');
      repository.recordTake(song.id, part: 'guitar');

      expect(await repository.takesSentToMe(), isEmpty);
    });
  });

  group('the desk itself', () {
    testWidgets('says who played it and what the song is, and nothing else',
        (tester) async {
      final studio = await _aStudio();

      await _openTheDesk(tester, studio.repository);

      expect(find.text('Maya'), findsOneWidget);
      expect(find.text('Jaylen'), findsOneWidget);
      expect(find.text('Gymnopédie no 1'), findsOneWidget);
      expect(find.text('Clair de lune'), findsOneWidget);

      // Jaylen sent first, so his row is above hers: newest last.
      final jaylen = tester.getTopLeft(find.text('Jaylen')).dy;
      final maya = tester.getTopLeft(find.text('Maya')).dy;
      expect(jaylen, lessThan(maya));

      // Nothing on the screen says when any of it happened, and nothing
      // counts it. The server sends no date at all, so there is none to
      // print (Every Musician, Same Song, 17 September 2026).
      expect(find.textContaining('ago'), findsNothing);
      expect(find.textContaining('2 takes'), findsNothing);
    });

    testWidgets('says so plainly when nothing has come in', (tester) async {
      final repository = InMemoryMusicRepository.seeded();

      await _openTheDesk(tester, repository);

      expect(find.byKey(const Key('what_came_in_nothing')), findsOneWidget);
      // And no list of who has not sent anything.
      expect(find.text('Maya'), findsNothing);
    });

    testWidgets('fits a small phone with large text', (tester) async {
      final studio = await _aStudio();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final player = _AFakePlayer();
      addTearDown(player.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.3,
          maxScaleFactor: 1.3,
          child: WhatCameInScreen(
            repository: studio.repository,
            listening: player,
            onKeyboard: true,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Maya'), findsOneWidget);
    });
  });

  group('the pass: Space, N, Enter', () {
    testWidgets('Space plays the one in hand, and pauses it', (tester) async {
      final studio = await _aStudio();
      final player = await _openTheDesk(tester, studio.repository);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(player.started, <String>[studio.fromJaylen],
          reason: 'Space did not start the take at the top of the pass');
      expect(player.playing, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(player.playing, isFalse, reason: 'Space did not pause it again');
      expect(player.started, hasLength(1), reason: 'pausing started it over');
    });

    testWidgets('Enter moves to the next take, playing', (tester) async {
      final studio = await _aStudio();
      final player = await _openTheDesk(tester, studio.repository);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(player.started, <String>[studio.fromJaylen, studio.fromMaya]);

      // The last take is the last: Enter on it stays there rather than
      // starting the queue again.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(player.started, hasLength(2));
    });

    testWidgets('N pins a note at the playhead of the take in hand',
        (tester) async {
      final studio = await _aStudio();
      final player = await _openTheDesk(tester, studio.repository);

      // Listening to Maya's, three quarters of a minute in.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      player.listeningAt(42000);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      // The moment is decided before the sheet opens, and the take stops so
      // the bar stays where it was heard.
      expect(find.text('Note at 0:42'), findsWidgets);
      expect(player.playing, isFalse);

      await tester.enterText(
        find.byKey(const Key('moment_note_body')),
        'you rushed into the turnaround',
      );
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      final notes = await studio.repository.loadMomentNotes(studio.herSong);
      expect(notes, hasLength(1));
      expect(notes.single.atMs, 42000);
      expect(notes.single.layerId, studio.fromMaya);
      expect(notes.single.body, 'you rushed into the turnaround');
    });

    testWidgets('a note lands where it was heard in the song, not in the file',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final hers = repository.teachALesson(
        studentId: 'student-maya',
        studentName: 'Maya',
      );
      final song = await repository.createSong(room: hers, title: 'Gymnopédie no 1');
      // Punched in at the last chorus, with a tenth of a second of latency
      // trimmed off the front: the take begins at 1:30 of the song and at
      // 0:00 of its own file (0045).
      final take = repository.recordTake(
        song.id,
        part: 'piano',
        by: 'student-maya',
        startMs: 90000,
        offsetMs: 120,
      );

      final player = await _openTheDesk(tester, repository);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      // Five seconds into what he can hear.
      player.listeningAt(5000);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      // Which is 1:34 of the song, not 0:05 of it. A note filed at 0:05
      // would open on a bar where the student is not playing at all.
      expect(find.text('Note at 1:34'), findsWidgets);

      await tester.enterText(
        find.byKey(const Key('moment_note_body')),
        'you rushed into the turnaround',
      );
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      final notes = await repository.loadMomentNotes(song.id);
      expect(notes.single.atMs, 94880,
          reason: 'the moment is on the take\'s clock and not the song\'s');
      expect(notes.single.layerId, take);
    });

    testWidgets('and a phone\'s own keyboard is left alone', (tester) async {
      final studio = await _aStudio();
      final player = await _openTheDesk(tester, studio.repository, onKeyboard: false);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(player.started, isEmpty);
      // The takes are still there to tap.
      expect(find.byKey(Key('came_in_${studio.fromMaya}')), findsOneWidget);
      // And so is the hint line's absence: the keys are only said where
      // there are keys.
      expect(find.byKey(const Key('what_came_in_keys')), findsNothing);
    });

    testWidgets('and a phone can answer, with no N to press', (tester) async {
      final studio = await _aStudio();
      final player = await _openTheDesk(
        tester,
        studio.repository,
        onKeyboard: false,
      );

      await tester.tap(find.byKey(Key('came_in_${studio.fromMaya}')));
      await tester.pumpAndSettle();
      player.listeningAt(12000);
      await tester.pumpAndSettle();

      // A teacher between lessons, with the app in their hand. Without this
      // they could hear Maya's take and then have to leave the desk, find
      // her room among nine and find the moment again.
      await tester.tap(find.byKey(Key('came_in_note_${studio.fromMaya}')));
      await tester.pumpAndSettle();

      expect(find.text('Note at 0:12'), findsWidgets);
      expect(player.playing, isFalse, reason: 'the take played on while he typed');

      await tester.enterText(
        find.byKey(const Key('moment_note_body')),
        'lovely, and a shade early',
      );
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      final notes = await studio.repository.loadMomentNotes(studio.herSong);
      expect(notes.single.body, 'lovely, and a shade early');
      expect(notes.single.layerId, studio.fromMaya);
    });

    testWidgets('and the answer is on the row in hand, and only that one',
        (tester) async {
      final studio = await _aStudio();
      await _openTheDesk(tester, studio.repository, onKeyboard: false);

      // One playhead, so one thing to say something about.
      expect(find.byKey(Key('came_in_note_${studio.fromJaylen}')), findsOneWidget);
      expect(find.byKey(Key('came_in_note_${studio.fromMaya}')), findsNothing);
    });

    testWidgets('and a tap plays the row it was on', (tester) async {
      final studio = await _aStudio();
      final player = await _openTheDesk(tester, studio.repository);

      await tester.tap(find.byKey(Key('came_in_${studio.fromMaya}')));
      await tester.pumpAndSettle();

      expect(player.started, <String>[studio.fromMaya]);

      // And the keys follow it: N is about what is playing.
      player.listeningAt(9000);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      expect(find.text('Note at 0:09'), findsWidgets);
    });
  });

  group('getting to it', () {
    testWidgets('the lesson link screen has a way in', (tester) async {
      final studio = await _aStudio();
      studio.repository.callStanding = CallStanding.adult;
      await studio.repository.openLessonLink('Piano lessons');

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LessonLinkScreen(repository: studio.repository),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('lesson_what_came_in')));
      await tester.pumpAndSettle();

      expect(find.byType(WhatCameInScreen), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
    });

    testWidgets('and still has one when every link has been turned off',
        (tester) async {
      final studio = await _aStudio();
      // He took the poster down once his students had all scanned it, so
      // there is no link left and the screen is the "make your first link"
      // form. He still teaches them, and 0151 still lists what they send.
      expect(await studio.repository.myLessonLinks(), isEmpty);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LessonLinkScreen(repository: studio.repository),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('lesson_what_came_in')));
      await tester.pumpAndSettle();

      expect(find.byType(WhatCameInScreen), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
    });

    testWidgets('and says nothing about it to somebody who teaches nobody',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LessonLinkScreen(repository: repository),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lesson_what_came_in')), findsNothing);
    });

    testWidgets('Home says something arrived, once, and opening it answers it',
        (tester) async {
      final studio = await _aStudio();

      await _openHome(tester, studio.repository);

      // One card, not one a take: nine students would be an inbox, and the
      // desk is the list.
      final cards = _cameInCards(tester);
      expect(cards, hasLength(1));
      expect(cards.single.who, 'Maya', reason: 'the card does not name the newest arrival');
      expect(cards.single.line, 'Gymnopédie no 1');
      // Nothing about when, and nothing counted.
      expect(cards.single.detail, isNull);

      cards.single.onAction();
      await tester.pumpAndSettle();

      expect(find.byType(WhatCameInScreen), findsOneWidget);

      // Answered by being opened: the same card waiting afterwards would be
      // the app asking again. Kept on this phone, and nothing reaches the
      // student.
      expect(SetAside.has(SetAside.cameIn, studio.fromMaya), isTrue);
      // Everything that was on the desk, not only the newest: a teacher who
      // has been to the desk has seen all of it. Otherwise Maya deleting
      // hers to re-record would put Jaylen's week-old take back on Home as
      // though it had just arrived.
      expect(SetAside.has(SetAside.cameIn, studio.fromJaylen), isTrue);
    });

    testWidgets('and says nothing to somebody who teaches nobody',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();

      await _openHome(tester, repository);

      expect(_cameInCards(tester), isEmpty);
    });
  });
}
