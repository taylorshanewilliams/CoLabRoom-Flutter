import 'dart:async';
import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/loop_round.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/take_turns.dart';
import 'package:colabroom/features/layers/take_turns_card.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Take turns on the loop.
///
/// Every Musician, Same Song, 17 September 2026, slice 33: "A beat goes round
/// a room in 16-bar turns. 'Skip me' is always free. It plays back as one
/// conversation." Each person records over the same passage, in order; a
/// turn is an ordinary take; a skip is silent; nobody outside the room can
/// join it or hear it; and the result waits for everybody in it, because
/// every turn is a shared take and 0155 already asks about those.
///
/// The fake is 0159's functions sentence for sentence, and it can be anybody
/// in turn, so every end of a round is read from one repository. The seeded
/// room is Taylor (owner) and Jess; Sam is added where an order of two would
/// not show which way a turn went.

const String _taylor = 'preview-user';
const String _jess = 'preview-jess';
const String _sam = 'preview-sam';
const String _vee = 'preview-vee';
const String _song = 'song-1';

InMemoryMusicRepository _room({bool withSam = true, bool withViewer = false}) {
  final repo = InMemoryMusicRepository.seeded();
  if (withSam) {
    repo.addToRoom(
      'room-1',
      const RoomMember(
        userId: _sam,
        displayName: 'Sam',
        role: RoomRole.editor,
        colorValue: 0xFF45D6A5,
      ),
    );
  }
  if (withViewer) {
    repo.addToRoom(
      'room-1',
      const RoomMember(
        userId: _vee,
        displayName: 'Vee',
        role: RoomRole.viewer,
        colorValue: 0xFFE3B34D,
      ),
    );
  }
  return repo;
}

/// Records a draft on the passage as [who] and hands it in as their turn.
Future<String> _play(
  InMemoryMusicRepository repo,
  String roundId,
  String who, {
  String song = _song,
  int startMs = 8000,
}) async {
  repo.currentUserId = who;
  final take = repo.recordTake(song, part: 'lead', shared: false, startMs: startMs);
  await repo.handInMyTurn(roundId: roundId, layerId: take);
  return take;
}

Future<LoopRound> _read(InMemoryMusicRepository repo, String who,
    {String song = _song}) async {
  repo.currentUserId = who;
  return (await repo.loadLoopRounds(song)).first;
}

List<String> _names(LoopRound round) =>
    <String>[for (final seat in round.seats) seat.name];

Matcher _refused(String message, String code) => throwsA(
      isA<PostgrestException>()
          .having((e) => e.message, 'message', message)
          .having((e) => e.code, 'code', code),
    );

LoopRound _round({
  List<LoopSeat> seats = const <LoopSeat>[],
  String? up,
  bool ended = false,
  int startMs = 8000,
  int endMs = 24000,
  DateTime? startedAt,
}) =>
    LoopRound(
      id: 'round-1',
      projectId: _song,
      startMs: startMs,
      endMs: endMs,
      startedAt: startedAt ?? DateTime(2026, 9, 18, 12),
      seats: seats,
      upId: up,
      ended: ended,
      startedBy: _taylor,
    );

LoopSeat _seat(String id, String name, SeatState state, [String? layer]) =>
    LoopSeat(userId: id, name: name, state: state, layerId: layer);

SharedLayer _layer(
  String id, {
  String who = _taylor,
  String? whoName = 'Taylor',
  int startMs = 8000,
  bool shared = false,
  DateTime? at,
  String label = '',
  int durationMs = 16000,
}) =>
    SharedLayer(
      id: id,
      projectId: _song,
      recordedBy: who,
      recordedByName: whoName,
      storagePath: 'room-1/$_song/layers/$id.m4a',
      label: label,
      part: TakePart.lead,
      startMs: startMs,
      durationMs: durationMs,
      createdAt: at ?? DateTime(2026, 9, 18, 13),
      sharedAt: shared ? DateTime(2026, 9, 18, 13) : null,
    );

Take _take(String id, {bool enabled = true}) => Take(
      id: id,
      path: '/tmp/$id.m4a',
      label: id,
      recordedAt: DateTime(2026, 9, 18),
      enabled: enabled,
    );

Float64List _level(int samples, double level) =>
    Float64List.fromList(List<double>.filled(samples, level));

class _Recorded extends SongLayerService {
  _Recorded(this.layers) : super(client: null);

  final List<SharedLayer> layers;

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => layers;

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

void main() {
  group('the round', () {
    test('turns advance in the order given, one take each', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        // Jess is named twice and sits once, where she was first named.
        order: <String>[_taylor, _jess, _sam, _jess],
      );

      var round = await _read(repo, _taylor);
      expect(_names(round), <String>['Taylor', 'Jess', 'Sam']);
      expect(round.upId, _taylor);
      expect(round.startMs, 8000);
      expect(round.endMs, 24000);

      // Everybody in the order but the person who started it is told once,
      // and told the one thing somebody put in an order needs to know.
      for (final who in <String>[_jess, _sam]) {
        final heard = repo.told.where((t) => t.to == who).toList();
        expect(heard, hasLength(1));
        expect(heard.single.notification.title,
            'Taylor started taking turns on Midnight Signal');
        expect(heard.single.notification.body, contains('Skipping is free'));
      }
      expect(repo.told.where((t) => t.to == _taylor), isEmpty);

      final first = await _play(repo, id, _taylor);
      round = await _read(repo, _taylor);
      expect(round.upId, _jess);
      expect(round.seats.first.state, SeatState.played);
      expect(round.seats.first.layerId, first);

      // The next person is told it is their turn, with nobody's name on it.
      final jessHeard = repo.told
          .where((t) => t.to == _jess)
          .map((t) => t.notification)
          .toList();
      expect(jessHeard.last.title, 'Your turn on Midnight Signal');
      expect(jessHeard.last.actorId, isNull);
      expect(repo.told.where((t) =>
          t.to == _sam && t.notification.title.startsWith('Your turn')), isEmpty);

      await _play(repo, id, _jess);
      expect((await _read(repo, _taylor)).upId, _sam);
      await _play(repo, id, _sam);

      round = await _read(repo, _taylor);
      expect(round.upId, isNull);
      expect(round.played.map((seat) => seat.name), <String>['Taylor', 'Jess', 'Sam']);

      // One turn each: the turn has moved, so a second take is refused.
      repo.currentUserId = _taylor;
      final again = repo.recordTake(_song, part: 'lead', shared: false, startMs: 8000);
      await expectLater(
        repo.handInMyTurn(roundId: id, layerId: again),
        _refused('It is not your turn yet.', '22023'),
      );
    });

    test('a turn handed in out of order stays a draft, and says why', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess],
      );
      repo.currentUserId = _jess;
      final early = repo.recordTake(_song, part: 'bass', shared: false, startMs: 8000);
      await expectLater(
        repo.handInMyTurn(roundId: id, layerId: early),
        // 22023, so the app reads the sentence out rather than "no access".
        _refused('It is not your turn yet.', '22023'),
      );
      final round = await _read(repo, _jess);
      expect(round.upId, _taylor);
      expect(round.played, isEmpty);

      // Nor somebody else's take, nor one from the top of the song.
      repo.currentUserId = _taylor;
      await expectLater(
        repo.handInMyTurn(roundId: id, layerId: early),
        _refused('That take is not yours to hand in.', '42501'),
      );
      final intro = repo.recordTake(_song, part: 'lead', shared: false);
      await expectLater(
        repo.handInMyTurn(roundId: id, layerId: intro),
        _refused('That take is not on these bars.', '22023'),
      );
    });

    test('a skip passes silently', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess, _sam],
      );
      await _play(repo, id, _taylor);
      final before = repo.told.length;

      repo.currentUserId = _jess;
      await repo.skipMyTurn(id);
      // Twice is not an error and says nothing new.
      await repo.skipMyTurn(id);

      // One notification came of it: the next person's turn, in the words
      // they would have had anyway, with nobody's name on it.
      final after = repo.told.sublist(before);
      expect(after, hasLength(1));
      expect(after.single.to, _sam);
      expect(after.single.notification.title, 'Your turn on Midnight Signal');
      expect(after.single.notification.actorId, isNull);
      expect(after.single.notification.body, isNot(contains('Jess')));

      // Nobody else can read the seat again: no mark, no gap, no name.
      final asTaylor = await _read(repo, _taylor);
      expect(_names(asTaylor), <String>['Taylor', 'Sam']);
      expect(asTaylor.upId, _sam);
      expect(asTaylor.seatOf(_jess), isNull);
      expect(_names(await _read(repo, _sam)), <String>['Taylor', 'Sam']);

      // The person who skipped still sees their own.
      final asJess = await _read(repo, _jess);
      expect(asJess.seatOf(_jess)?.state, SeatState.out);
    });

    test('skipping ahead of your turn is free too, and tells nobody', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess, _sam],
      );
      final before = repo.told.length;
      repo.currentUserId = _sam;
      await repo.skipMyTurn(id);
      expect(repo.told.length, before);
      expect((await _read(repo, _taylor)).upId, _taylor);

      await _play(repo, id, _taylor);
      await _play(repo, id, _jess);
      expect((await _read(repo, _taylor)).upId, isNull);
    });

    test('count me back in goes to the end of the order', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_jess, _taylor, _sam],
      );
      repo.currentUserId = _jess;
      await repo.skipMyTurn(id);
      expect((await _read(repo, _jess)).upId, _taylor);

      repo.currentUserId = _jess;
      await repo.joinLoopRound(id);
      // Behind Sam, not back in front of Taylor: nobody's turn is taken out
      // from under them by somebody ahead changing their mind.
      final round = await _read(repo, _taylor);
      expect(_names(round), <String>['Taylor', 'Sam', 'Jess']);
      expect(round.upId, _taylor);

      // Joining when you are already in changes nothing.
      repo.currentUserId = _sam;
      await repo.joinLoopRound(id);
      expect(_names(await _read(repo, _taylor)), <String>['Taylor', 'Sam', 'Jess']);
    });

    test('somebody who was never named can come in, at the end', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
      );
      // Nobody named: the order is whoever started it.
      expect(_names(await _read(repo, _taylor)), <String>['Taylor']);
      await _play(repo, id, _taylor);

      repo.currentUserId = _sam;
      await repo.joinLoopRound(id);
      final round = await _read(repo, _taylor);
      expect(_names(round), <String>['Taylor', 'Sam']);
      expect(round.upId, _sam);
    });

    test('a turn nobody takes passes quietly, and never on their own look',
        () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess, _sam],
      );
      await _play(repo, id, _taylor);
      repo.letTheTurnSit(id, const Duration(days: 4));
      final before = repo.told.length;

      // Jess opens the app to take her turn. It is still hers.
      expect((await _read(repo, _jess)).upId, _jess);
      expect(repo.told.length, before);

      // Anybody else's look passes it, the way a skip does: Sam is told it
      // is his turn, and that is all anybody is told.
      final round = await _read(repo, _taylor);
      expect(round.upId, _sam);
      expect(_names(round), <String>['Taylor', 'Sam']);
      final after = repo.told.sublist(before);
      expect(after, hasLength(1));
      expect(after.single.to, _sam);
      expect(after.single.notification.title, 'Your turn on Midnight Signal');
      expect(after.single.notification.actorId, isNull);

      // One look passes one turn: Sam's clock started when he was told.
      expect((await _read(repo, _taylor)).upId, _sam);

      // Jess can still come back in.
      repo.currentUserId = _jess;
      await repo.joinLoopRound(id);
      expect(_names(await _read(repo, _taylor)), <String>['Taylor', 'Sam', 'Jess']);
    });

    test('a turn that moves because somebody left is not passed over', () async {
      // The turn can move with nobody moving it: whoever was up is made a
      // viewer, or leaves, and the round steps over them. The person it
      // lands on has been told nothing, so their three days start there --
      // otherwise the next look passes a turn they never heard about.
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_jess, _sam, _taylor],
      );
      expect((await _read(repo, _taylor)).upId, _jess);
      final before = repo.told.length;

      repo.addToRoom(
        'room-1',
        const RoomMember(
          userId: _jess,
          displayName: 'Jess',
          role: RoomRole.viewer,
          colorValue: 0xFF7C5CFF,
        ),
      );
      repo.letTheTurnSit(id, const Duration(days: 4));

      final round = await _read(repo, _taylor);
      expect(round.upId, _sam);
      final after = repo.told.sublist(before);
      expect(after, hasLength(1));
      expect(after.single.to, _sam);
      expect(after.single.notification.title, 'Your turn on Midnight Signal');
      expect(after.single.notification.actorId, isNull);

      // And Sam's three days start there: the next look leaves it his.
      expect((await _read(repo, _taylor)).upId, _sam);
      expect(repo.told.length, before + 1);
    });

    test('somebody outside the room is refused, and reads nothing', () async {
      final repo = _room();
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess],
      );

      repo.currentUserId = 'somebody-next-door';
      expect(await repo.loadLoopRounds(_song), isEmpty);
      // The sentence they would get for a round, or a song, that is not
      // there: a refusal never says what is in a room.
      await expectLater(
        repo.startLoopRound(projectId: _song, startMs: 0, endMs: 8000),
        _refused('No such song.', '22023'),
      );
      await expectLater(repo.joinLoopRound(id), _refused('No such round.', '22023'));
      await expectLater(repo.skipMyTurn(id), _refused('No such round.', '22023'));
      await expectLater(repo.endLoopRound(id), _refused('No such round.', '22023'));
      await expectLater(
        repo.handInMyTurn(roundId: id, layerId: 'take-taylor-vocal'),
        _refused('No such round.', '22023'),
      );

      // And cannot be put in an order by somebody inside it.
      repo.currentUserId = _taylor;
      await repo.endLoopRound(id);
      await expectLater(
        repo.startLoopRound(
          projectId: _song,
          startMs: 0,
          endMs: 8000,
          order: <String>[_taylor, 'somebody-next-door'],
        ),
        _refused(
          'Everybody in the order has to be able to record in this room.',
          '22023',
        ),
      );
    });

    test('a viewer hears the round and cannot sit in it', () async {
      final repo = _room(withViewer: true);
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess],
      );
      repo.currentUserId = _vee;
      expect(await repo.loadLoopRounds(_song), hasLength(1));
      await expectLater(
        repo.joinLoopRound(id),
        _refused('Only somebody who can record here can take a turn.', '42501'),
      );
      await expectLater(
        repo.startLoopRound(projectId: _song, startMs: 0, endMs: 8000),
        _refused('Only somebody who can record here can start a round.', '42501'),
      );
      // Nor can anybody give them a turn they could never take.
      repo.currentUserId = _taylor;
      await repo.endLoopRound(id);
      await expectLater(
        repo.startLoopRound(
          projectId: _song,
          startMs: 0,
          endMs: 8000,
          order: <String>[_taylor, _vee],
        ),
        _refused(
          'Everybody in the order has to be able to record in this room.',
          '22023',
        ),
      );
    });

    test('one round at a time, ended by whoever started it or the owner',
        () async {
      final repo = _room();
      repo.currentUserId = _jess;
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_jess, _sam],
      );
      await expectLater(
        repo.startLoopRound(projectId: _song, startMs: 0, endMs: 8000),
        _refused('This song already has a round going.', '22023'),
      );
      await expectLater(
        repo.startLoopRound(projectId: _song, startMs: 8000, endMs: 8000),
        _refused('Choose the bars first.', '22023'),
      );

      repo.currentUserId = _sam;
      await expectLater(
        repo.endLoopRound(id),
        _refused(
          "Only whoever started the round, or the room's owner, can end it.",
          '42501',
        ),
      );
      // The owner can, though Jess started it.
      repo.currentUserId = _taylor;
      await repo.endLoopRound(id);
      expect((await _read(repo, _taylor)).ended, isTrue);
      await expectLater(repo.joinLoopRound(id), _refused('That round is over.', '22023'));

      // A round nobody is waiting on makes way for the next without being
      // ended: everybody in it has played or is sitting out.
      repo.currentUserId = _sam;
      final second = await repo.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 8000,
      );
      await repo.skipMyTurn(second);
      repo.currentUserId = _jess;
      await repo.startLoopRound(projectId: _song, startMs: 0, endMs: 8000);
      final rounds = await repo.loadLoopRounds(_song);
      expect(rounds, hasLength(3));
      expect(rounds.where((round) => !round.ended), hasLength(1));
    });

    test('the result waits for everybody in it', () async {
      // A turn is an ordinary take and handing it in shares it, so 0155's
      // gate counts it without having heard of rounds.
      final repo = _room(withSam: false);
      final room = (await repo.loadRooms()).first;
      final song = await repo.createSong(room: room, title: 'Round The Room');
      final id = await repo.startLoopRound(
        projectId: song.id,
        startMs: 8000,
        endMs: 24000,
        order: <String>[_taylor, _jess],
      );
      await _play(repo, id, _taylor, song: song.id);
      await _play(repo, id, _jess, song: song.id);

      repo.currentUserId = _taylor;
      await repo.putOnOpenMic(song.id);
      var audience = (await repo.songAudience(song.id))!;
      expect(audience.onOpenMic, isFalse);
      expect(audience.waitingOn, <String>['Jess']);

      repo.currentUserId = _jess;
      final asked = await repo.partQuestionsForMe();
      expect(asked.single.projectId, song.id);
      await repo.answerForMyPart(song.id, yes: true);

      repo.currentUserId = _taylor;
      await repo.putOnOpenMic(song.id);
      audience = (await repo.songAudience(song.id))!;
      expect(audience.onOpenMic, isTrue);
    });
  });

  group('the conversation', () {
    test('assembles in the order of the round, not the order it was recorded',
        () {
      final round = _round(
        seats: <LoopSeat>[
          _seat(_taylor, 'Taylor', SeatState.played, 'turn-t'),
          _seat(_sam, 'Sam', SeatState.waiting),
          // Jess came back in at the end, though she recorded before Sam.
          _seat(_jess, 'Jess', SeatState.played, 'turn-j'),
        ],
        up: _sam,
      );
      expect(
        TakeTurns.conversation(round, playable: <String>{'turn-j', 'turn-t'})
            .map((seat) => seat.name),
        <String>['Taylor', 'Jess'],
      );
      // A turn that is not on this phone is left out, and the rest keep
      // their order.
      expect(
        TakeTurns.conversation(round, playable: <String>{'turn-j'})
            .map((seat) => seat.name),
        <String>['Jess'],
      );
      expect(round.turnLayerIds, <String>{'turn-t', 'turn-j'});
    });

    test('lays the turns end to end with no gap, turned down together', () {
      final spliced = TakeTurns.splice(<Float64List>[
        _level(100, 0.1),
        _level(100, 0.2),
        _level(100, 0.3),
      ]);
      expect(spliced.length, 300);
      expect(spliced[0], 0.1);
      expect(spliced[99], 0.1);
      expect(spliced[100], 0.2);
      expect(spliced[200], 0.3);
      expect(spliced[299], 0.3);

      // Too loud for full scale: fitted once, so the quiet player stays as
      // much quieter than the loud one as they played it.
      final loud = TakeTurns.splice(<Float64List>[
        _level(10, 0.5),
        _level(10, 2.0),
      ]);
      expect(loud[10], closeTo(0.99, 1e-9));
      expect(loud[0] / loud[10], closeTo(0.25, 1e-9));
    });

    test('puts a turn over the loop on the passage and nowhere else', () {
      final rate = Multitrack.rate;
      // Three seconds of loop. The turn starts a second in, the way the
      // mixer places it, and runs past the end of a one-second passage.
      final backing = _level(rate * 3, 0.1);
      final turn = Float64List(rate * 3)
        ..fillRange(rate, rate * 3, 0.5);
      final heard = TakeTurns.turnOver(backing, turn, startMs: 1000, endMs: 2000);
      expect(heard.length, rate);
      expect(heard.first, closeTo(0.6, 1e-9));
      expect(heard.last, closeTo(0.6, 1e-9));

      // A turn that stops early is heard stopping, over a loop that goes on.
      final short = Float64List(rate + rate ~/ 2)
        ..fillRange(rate, rate + rate ~/ 2, 0.5);
      final stopped = TakeTurns.turnOver(backing, short, startMs: 1000, endMs: 2000);
      expect(stopped.first, closeTo(0.6, 1e-9));
      expect(stopped.last, closeTo(0.1, 1e-9));
    });

    test('the loop under a turn has nobody else\'s turn in it', () {
      final takes = <Take>[
        _take('reference'),
        _take('rhythm', enabled: false),
        _take('turn-t'),
        _take('turn-j'),
      ];
      final loop = TakeTurns.withoutTurns(takes, <String>{'turn-t', 'turn-j'});
      expect(
        <String, bool>{for (final take in loop) take.id: take.enabled},
        <String, bool>{
          'reference': true,
          // As this person had it: a mute is not undone.
          'rhythm': false,
          'turn-t': false,
          'turn-j': false,
        },
      );
    });

    test('the loop has none of your own goes at this turn in it either', () {
      // A go somebody thought better of is an ordinary take only they can
      // hear, on exactly these bars. Left in, it plays under the next
      // attempt -- down the microphone on a speaker -- and stacks up under
      // every turn of the conversation on their phone and nobody else's.
      final round = _round(
        startedAt: DateTime(2026, 9, 18, 12),
        seats: <LoopSeat>[
          _seat(_jess, 'Jess', SeatState.played, 'turn-j'),
          _seat(_taylor, 'Taylor', SeatState.waiting),
        ],
        up: _taylor,
      );
      final layers = <SharedLayer>[
        _layer('bass', who: _jess, whoName: 'Jess', startMs: 0, shared: true),
        _layer('turn-j',
            who: _jess, whoName: 'Jess', shared: true,
            at: DateTime(2026, 9, 18, 12, 30)),
        _layer('second-go', at: DateTime(2026, 9, 18, 14)),
        _layer('first-go', at: DateTime(2026, 9, 18, 13)),
        // Last week, and the top of the song: not goes at this turn.
        _layer('old', at: DateTime(2026, 9, 11)),
        _layer('intro', startMs: 0, at: DateTime(2026, 9, 18, 15)),
      ];

      // Oldest first, so the last one is the one they just played.
      expect(
        TakeTurns.draftsFor(round, layers, me: _taylor).map((take) => take.id),
        <String>['first-go', 'second-go'],
      );
      expect(TakeTurns.draftFor(round, layers, me: _taylor)?.id, 'second-go');
      expect(
        TakeTurns.quietUnder(round, layers, me: _taylor),
        <String>{'turn-j', 'first-go', 'second-go'},
      );
      // Somebody else's phone knows about the turn and nothing else: a
      // draft is not theirs to hear.
      expect(
        TakeTurns.quietUnder(round, layers, me: _jess),
        <String>{'turn-j'},
      );

      final loop = TakeTurns.withoutTurns(
        <Take>[
          _take('bass'),
          _take('turn-j'),
          _take('second-go'),
          _take('first-go'),
          _take('intro'),
        ],
        TakeTurns.quietUnder(round, layers, me: _taylor),
      );
      expect(
        <String, bool>{for (final take in loop) take.id: take.enabled},
        <String, bool>{
          'bass': true,
          'turn-j': false,
          'second-go': false,
          'first-go': false,
          'intro': true,
        },
      );
    });

    test('says whose turn is sounding', () {
      final track = TurnsTrack(
        path: '/tmp/turns.wav',
        roundId: 'round-1',
        passage: const PracticeLoop(startMs: 8000, endMs: 24000, label: 'Bars 5–12'),
        turns: <LoopSeat>[
          _seat(_taylor, 'Taylor', SeatState.played, 'turn-t'),
          _seat(_jess, 'Jess', SeatState.played, 'turn-j'),
        ],
      );
      expect(track.turnMs, 16000);
      expect(track.turnAt(0)?.name, 'Taylor');
      expect(track.turnAt(15999)?.name, 'Taylor');
      expect(track.turnAt(16000)?.name, 'Jess');
      // The last few milliseconds a player reports past the end are still
      // the last player's.
      expect(track.turnAt(32050)?.name, 'Jess');
    });

    test('the draft is your latest take on the passage since the round began',
        () {
      final round = _round(startedAt: DateTime(2026, 9, 18, 12));
      final layers = <SharedLayer>[
        // From last week, on the same bars. Not for this round.
        _layer('old', at: DateTime(2026, 9, 11)),
        _layer('first-go', at: DateTime(2026, 9, 18, 13)),
        _layer('second-go', at: DateTime(2026, 9, 18, 14)),
        // Somebody else's, the top of the song, and one already shared.
        _layer('theirs', who: _jess, at: DateTime(2026, 9, 18, 15)),
        _layer('intro', startMs: 0, at: DateTime(2026, 9, 18, 15)),
        _layer('out-already', shared: true, at: DateTime(2026, 9, 18, 15)),
        // From the same bar to the end of the song: a take, not a turn.
        _layer('whole-verse', durationMs: 90000, at: DateTime(2026, 9, 18, 16)),
      ];
      expect(TakeTurns.draftFor(round, layers, me: _taylor)?.id, 'second-go');
      expect(
        TakeTurns.draftFor(round, layers,
            me: _taylor, alreadyTurns: <String>{'second-go'})?.id,
        'first-go',
      );
      expect(TakeTurns.draftFor(round, layers, me: null), isNull);
      expect(TakeTurns.draftFor(round, layers, me: _sam), isNull);
    });
  });

  group('the passage', () {
    const sections = <StructureSection>[
      StructureSection(startMs: 0, endMs: 8000, label: 'Intro'),
      StructureSection(startMs: 8000, endMs: 24000, label: 'Verse'),
    ];
    // Two-second bars from the top.
    final downbeats = <int>[for (var i = 0; i < 40; i += 1) i * 2000];

    test('is offered as the part under the playhead, else bars, else the clock',
        () {
      final part = TakeTurns.offeredPassage(
        atMs: 9000,
        sections: sections,
        downbeatsMs: downbeats,
      );
      expect(part.label, 'Verse');
      expect(part.startMs, 8000);
      expect(part.endMs, 24000);

      final bars = TakeTurns.offeredPassage(atMs: 30500, downbeatsMs: downbeats);
      expect(bars.label, 'Bars 16–23');
      expect(bars.startMs, 30000);
      expect(bars.endMs, 46000);

      final clock = TakeTurns.offeredPassage(atMs: 12000);
      expect(clock.label, '0:12–0:28');
      expect(clock.endMs - clock.startMs, TakeTurns.offeredMs);
    });

    test('is named on each phone from its own bars, never sent as words', () {
      final round = _round();
      expect(
        TakeTurns.passageOf(round, sections: sections, downbeatsMs: downbeats).label,
        'Verse',
      );
      expect(TakeTurns.passageOf(round, downbeatsMs: downbeats).label, 'Bars 5–12');
      // A phone with no analysis of the song reads the clock.
      expect(TakeTurns.passageOf(round).label, '0:08–0:24');
    });
  });

  group('the words', () {
    test('say whose turn it is, and never how many, how long or who has not',
        () {
      final seats = <LoopSeat>[
        _seat(_taylor, 'Taylor', SeatState.played, 'turn-t'),
        _seat(_jess, 'Jess', SeatState.waiting),
      ];
      final lines = <String>[
        TakeTurns.lineFor(_round(seats: seats, up: _jess), me: _taylor),
        TakeTurns.lineFor(_round(seats: seats, up: _jess), me: _jess),
        TakeTurns.lineFor(_round(seats: seats), me: _taylor),
        TakeTurns.lineFor(_round(seats: seats, ended: true), me: _taylor),
      ];
      expect(lines, <String>[
        'Jess is up.',
        'Your turn.',
        'It has been round. Anybody can still come in.',
        'This one is finished.',
      ]);
      final forbidden = RegExp(
        r'\d|skipped|passed|late|overdue|still to|waiting on|score|point|'
        r'vote|win|best|minute|hour|day|ago|deadline|timer|left',
        caseSensitive: false,
      );
      for (final line in lines) {
        expect(forbidden.hasMatch(line), isFalse, reason: '"$line"');
      }
    });
  });

  group('on the takes screen', () {
    Future<InMemoryMusicRepository> open(
      WidgetTester tester, {
      required InMemoryMusicRepository repo,
      required List<SharedLayer> layers,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = MusicBetaController(repo);
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          home: SongLayersScreen(
            roomId: 'room-1',
            projectId: _song,
            songTitle: 'Midnight Signal',
            layerService: _Recorded(layers),
            analysisService: _NoAnalysis(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return repo;
    }

    String orderOn(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const Key('take_turns_order')))
        .textSpan!
        .toPlainText();

    String lineOn(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('take_turns_line'))).data!;

    /// Everything the card says, in whatever state it is in, checked for the
    /// words that would make it a scoreboard or a clock: how many have
    /// played, who has not, how long anybody has had.
    void saysNoTally(WidgetTester tester) {
      final forbidden = RegExp(
        r'\d+\s*(of|/)\s*\d+|skipped|passed|\blate\b|overdue|still to|'
        r'waiting on|score|points|vote|winner|\bbest\b|minute|hour|\bdays?\b|'
        r'\bago\b|deadline|timer|\bleft\b',
        caseSensitive: false,
      );
      final said = tester.widgetList<Text>(find.descendant(
        of: find.byType(TakeTurnsCard),
        matching: find.byType(Text),
      ));
      expect(said, isNotEmpty);
      for (final text in said) {
        final words = text.data ?? text.textSpan?.toPlainText() ?? '';
        expect(forbidden.hasMatch(words), isFalse, reason: '"$words"');
      }
    }

    final jessBass = _layer(
      'bass',
      who: _jess,
      whoName: 'Jess',
      startMs: 0,
      shared: true,
      label: 'Bass line',
    );

    testWidgets('a song offers Take turns, and starting one shows the order',
        (tester) async {
      final repo = await open(tester, repo: _room(), layers: <SharedLayer>[jessBass]);
      expect(find.text('Take turns'), findsOneWidget);
      // Nothing about it is announced: a chip, under the others.
      expect(find.byType(TakeTurnsCard), findsNothing);

      await tester.tap(find.byKey(const Key('take_turns_start')));
      await tester.pumpAndSettle();
      // The person starting it goes first until they say otherwise, and the
      // order is names in a row, never numbers against people.
      expect(
        tester.widget<Text>(find.byKey(const Key('start_turns_order'))).data,
        'You',
      );
      await tester.tap(find.byKey(const Key('start_turns_person_$_sam')));
      await tester.tap(find.byKey(const Key('start_turns_person_$_jess')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('start_turns_order'))).data,
        'You, then Sam, then Jess',
      );
      expect(find.textContaining('Skipping is free'), findsOneWidget);

      await tester.tap(find.byKey(const Key('start_turns_go')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The round is on the server as it was chosen, by the clock because
      // this song has no bars to count.
      final round = (await repo.loadLoopRounds(_song)).single;
      expect(round.startMs, 0);
      expect(round.endMs, TakeTurns.offeredMs);
      expect(_names(round), <String>['Taylor', 'Sam', 'Jess']);

      expect(find.text('Taking turns · 0:00–0:16'), findsOneWidget);
      expect(orderOn(tester), 'You, then Sam, then Jess');
      expect(lineOn(tester), 'Your turn.');
      expect(find.text('Record my turn'), findsOneWidget);
      expect(find.text('Skip me'), findsOneWidget);
      // One round at a time, so the chip makes way for the card.
      expect(find.byKey(const Key('take_turns_start')), findsNothing);
      // Nothing to hear yet, and nothing offered.
      expect(find.text('Hear it'), findsNothing);
      saysNoTally(tester);
    });

    testWidgets('Skip me moves the card on and says nothing else', (tester) async {
      final seeded = _room();
      await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_taylor, _jess, _sam],
      );
      final told = seeded.told.length;
      final repo = await open(tester, repo: seeded, layers: <SharedLayer>[jessBass]);

      await tester.tap(find.byKey(const Key('take_turns_skip')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(orderOn(tester), 'Jess, then Sam');
      expect(lineOn(tester), 'You are sitting this one out.');
      expect(find.text('Record my turn'), findsNothing);
      expect(find.text('Skip me'), findsNothing);
      expect(find.text('Count me back in'), findsOneWidget);
      saysNoTally(tester);
      // Jess is told it is her turn. Nobody is told anything about Taylor.
      final after = repo.told.sublist(told);
      expect(after.map((t) => t.to), <String>[_jess]);
      expect(after.single.notification.actorId, isNull);

      await tester.tap(find.byKey(const Key('take_turns_back_in')));
      await tester.pumpAndSettle();
      expect(orderOn(tester), 'Jess, then Sam, then you');
      expect(lineOn(tester), 'Jess is up.');
      expect(find.text('Skip me'), findsOneWidget);
    });

    testWidgets("when it is somebody else's turn the card says whose",
        (tester) async {
      final seeded = _room();
      await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_jess, _taylor],
      );
      await open(tester, repo: seeded, layers: <SharedLayer>[jessBass]);

      expect(orderOn(tester), 'Jess, then you');
      expect(lineOn(tester), 'Jess is up.');
      expect(find.text('Record my turn'), findsNothing);
      // Free any time, not only when it is your turn.
      expect(find.text('Skip me'), findsOneWidget);
    });

    testWidgets('a draft on the passage is handed in, and asked about first',
        (tester) async {
      final seeded = _room(withSam: false);
      final id = await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_taylor, _jess],
      );
      final draft = seeded.recordTake(_song, part: 'lead', shared: false);
      final repo = await open(tester, repo: seeded, layers: <SharedLayer>[
        jessBass,
        _layer(draft, startMs: 0, at: DateTime.now().add(const Duration(minutes: 1))),
      ]);

      expect(lineOn(tester), 'Only you can hear your turn until you hand it in.');
      expect(find.text('Go again'), findsOneWidget);
      expect(find.text('Record my turn'), findsNothing);

      await tester.tap(find.byKey(const Key('take_turns_hand_in')));
      await tester.pumpAndSettle();
      // The same question sharing any take asks, because it is the same act.
      expect(find.text('Let the room hear this?'), findsOneWidget);
      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();
      expect((await repo.loadLoopRounds(_song)).single.played, isEmpty);

      await tester.tap(find.byKey(const Key('take_turns_hand_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share it'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final round = (await repo.loadLoopRounds(_song)).single;
      expect(round.id, id);
      expect(round.played.single.layerId, draft);
      expect(round.upId, _jess);
      expect(lineOn(tester), 'Jess is up.');
      expect(find.text('Hand it in'), findsNothing);
      // There is a conversation now, one turn long.
      expect(find.text('Hear it'), findsOneWidget);
      saysNoTally(tester);
    });

    testWidgets('a turn is left out of the ordinary mix until somebody wants it',
        (tester) async {
      final seeded = _room(withSam: false);
      final id = await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_jess, _taylor],
      );
      final turn = await _play(seeded, id, _jess, startMs: 0);
      seeded.currentUserId = _taylor;
      await open(tester, repo: seeded, layers: <SharedLayer>[
        jessBass,
        _layer(
          turn,
          who: _jess,
          whoName: 'Jess',
          startMs: 0,
          shared: true,
          label: 'Jess turn',
        ),
      ]);

      // The bass plays with the song; the turn sits on the same bars as
      // every other turn, so its lane starts switched off, and one tap
      // brings it in.
      expect(find.byTooltip('Mute Bass line'), findsOneWidget);
      expect(find.byTooltip('Unmute Jess turn'), findsOneWidget);
      expect(find.byTooltip('Mute Jess turn'), findsNothing);
      expect(lineOn(tester), 'Your turn.');
    });

    testWidgets('somebody who only listens sees the round and nothing to press',
        (tester) async {
      final seeded = _room(withViewer: true);
      await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_taylor, _jess],
      );
      seeded.currentUserId = _vee;
      await open(tester, repo: seeded, layers: <SharedLayer>[jessBass]);

      expect(orderOn(tester), 'Taylor, then Jess');
      expect(lineOn(tester), 'Taylor is up.');
      expect(find.text("I'm in"), findsNothing);
      expect(find.text('Skip me'), findsNothing);
      expect(find.byKey(const Key('take_turns_more')), findsNothing);
    });

    testWidgets('a round on a song with nothing on it still shows its card',
        (tester) async {
      final seeded = _room(withSam: false);
      await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_taylor, _jess],
      );
      await open(tester, repo: seeded, layers: const <SharedLayer>[]);
      expect(find.text('No takes yet'), findsOneWidget);
      expect(find.text('Record my turn'), findsOneWidget);
    });

    testWidgets('whoever started it can end it, and the next one starts there',
        (tester) async {
      final seeded = _room(withSam: false);
      await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_taylor, _jess],
      );
      final repo = await open(tester, repo: seeded, layers: <SharedLayer>[jessBass]);

      await tester.tap(find.byKey(const Key('take_turns_more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End this round'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect((await repo.loadLoopRounds(_song)).single.ended, isTrue);
      expect(find.text('Took turns · 0:00–0:16'), findsOneWidget);
      expect(lineOn(tester), 'This one is finished.');
      expect(find.text('Skip me'), findsNothing);
      saysNoTally(tester);
      expect(find.byKey(const Key('take_turns_start')), findsOneWidget);
    });

    testWidgets('the go before the one you kept does not play with the song',
        (tester) async {
      // Two goes at the same turn sit on the same bars, so both switched on
      // is one person playing over themselves. The latest is the one being
      // decided about, and it is the one that plays.
      final seeded = _room(withSam: false);
      await seeded.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_taylor, _jess],
      );
      final now = DateTime.now();
      await open(tester, repo: seeded, layers: <SharedLayer>[
        jessBass,
        _layer('first-go',
            startMs: 0,
            label: 'First go',
            at: now.add(const Duration(minutes: 1))),
        _layer('second-go',
            startMs: 0,
            label: 'Second go',
            at: now.add(const Duration(minutes: 2))),
      ]);

      expect(find.byTooltip('Mute Bass line'), findsOneWidget);
      expect(find.byTooltip('Mute Second go'), findsOneWidget);
      expect(find.byTooltip('Unmute First go'), findsOneWidget);
      // Still one thing to hand in, and it is the last one played.
      expect(find.text('Hand it in'), findsOneWidget);
    });
  });

  group('hearing it back', () {
    testWidgets('a hush while the file is being written stops it playing',
        (tester) async {
      // Writing a whole-song mix takes seconds on a phone. Record pressed in
      // those seconds must not leave the band's turns to start up under the
      // microphone when the file lands.
      final hush = ValueNotifier<int>(0);
      addTearDown(hush.dispose);
      final writing = Completer<TurnsTrack>();
      var asked = 0;
      const passage =
          PracticeLoop(startMs: 0, endMs: 16000, label: '0:00–0:16');
      final turns = <LoopSeat>[_seat(_jess, 'Jess', SeatState.played, 'turn-j')];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TakeTurnsCard(
            round: _round(
              seats: <LoopSeat>[
                ...turns,
                _seat(_taylor, 'Taylor', SeatState.waiting),
              ],
              up: _taylor,
              startMs: 0,
              endMs: 16000,
            ),
            passage: passage,
            me: _taylor,
            conversation: turns,
            draft: null,
            canSit: true,
            canRecordHere: true,
            canHear: true,
            canEnd: false,
            busy: false,
            onRecord: () {},
            onHandIn: (_) {},
            onSkip: () {},
            onJoin: () {},
            onEnd: () {},
            writeConversation: () {
              asked += 1;
              return writing.future;
            },
            hush: hush,
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('take_turns_hear')));
      await tester.pump();
      // Record is pressed on the screen while the file is still being made.
      hush.value += 1;
      writing.complete(TurnsTrack(
        path: '/tmp/turns.wav',
        roundId: 'round-1',
        passage: passage,
        turns: turns,
      ));
      await tester.pumpAndSettle();

      expect(asked, 1);
      // Nothing sounded, and nothing was said about it.
      expect(find.text('Hear it'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      expect(find.textContaining('would not play'), findsNothing);
      // And it can be asked for again.
      expect(
        tester.widget<TextButton>(find.ancestor(
          of: find.text('Hear it'),
          matching: find.byType(TextButton),
        )).onPressed,
        isNotNull,
      );
    });
  });

  group('in Perform', () {
    Future<List<List<Take>>> boot(
      WidgetTester tester, {
      required InMemoryMusicRepository repo,
      required List<SharedLayer> layers,
      required String keptPart,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'my_part_$_song': keptPart,
      });
      final controller = MusicBetaController(repo);
      await controller.load();
      addTearDown(controller.dispose);
      final project = (await repo.loadRooms())
          .first
          .projects
          .firstWhere((project) => project.id == _song);
      final mixes = <List<Take>>[];
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          home: LivePerformanceScreen(
            project: project,
            layerService: _Recorded(layers),
            analysisService: _NoAnalysis(),
            partMixer: (takes, onProgress) async {
              mixes.add(takes);
              return '/tmp/part-mix-${mixes.length}.wav';
            },
          ),
        ),
      ));
      for (var i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      return mixes;
    }

    /// A round with one turn handed in, and the song's other takes.
    Future<({InMemoryMusicRepository repo, String turn})> withARound() async {
      final repo = _room(withSam: false);
      final id = await repo.startLoopRound(
        projectId: _song,
        startMs: 0,
        endMs: 16000,
        order: <String>[_jess, _taylor],
      );
      final turn = await _play(repo, id, _jess, startMs: 0);
      repo.currentUserId = _taylor;
      return (repo: repo, turn: turn);
    }

    testWidgets('a turn is not summed into the part mix', (tester) async {
      // Perform builds its own mix, and knew nothing about rounds: four
      // turns on the same chorus would have played at once behind whoever
      // asked for their part forward.
      final made = await withARound();
      final mixes = await boot(
        tester,
        repo: made.repo,
        layers: <SharedLayer>[
          _layer('bass',
              who: _jess, whoName: 'Jess', startMs: 0, shared: true,
              label: 'Bass line'),
          _layer('gtr', startMs: 0, shared: true, label: 'Guitar'),
          _layer(made.turn,
              who: _jess, whoName: 'Jess', startMs: 0, shared: true,
              label: 'Jess turn'),
        ],
        keptPart: 'forward:gtr',
      );

      expect(mixes, hasLength(1));
      final heard = <String, Take>{
        for (final take in mixes.single) take.id: take,
      };
      expect(heard['bass']?.enabled, isTrue);
      expect(heard['gtr']?.enabled, isTrue);
      expect(heard[made.turn]?.enabled, isFalse);
    });

    testWidgets('and is not a part anybody can bring forward', (tester) async {
      // A turn is not a part somebody plays through the song; it is one of
      // several goes at the same few bars. A choice kept from before the
      // round is simply not put back.
      final made = await withARound();
      final mixes = await boot(
        tester,
        repo: made.repo,
        layers: <SharedLayer>[
          _layer('bass',
              who: _jess, whoName: 'Jess', startMs: 0, shared: true,
              label: 'Bass line'),
          _layer('gtr', startMs: 0, shared: true, label: 'Guitar'),
          _layer(made.turn,
              who: _jess, whoName: 'Jess', startMs: 0, shared: true,
              label: 'Jess turn'),
        ],
        keptPart: 'forward:${made.turn}',
      );
      expect(mixes, isEmpty);
    });
  });
}
