import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/loop_round.dart';
import '../../domain/moment_note.dart' show MomentNote;
import '../../domain/song_analysis_models.dart' show StructureSection;
import '../../services/chord_beat_grid.dart' show barNumberAt;
import '../../services/latency_probe.dart';
import '../../services/multitrack.dart';
import '../../services/song_layer_service.dart';
import '../workspace/practice_rules.dart';

/// Take turns on the loop: the rules, kept apart from the screen so they can
/// be tested without a player, a file or a server.
///
/// Every Musician, Same Song, 17 September 2026, slice 33: "A beat goes round
/// a room in 16-bar turns. 'Skip me' is always free. It plays back as one
/// conversation." Phones cannot play in time with each other over a network,
/// and a turn does not ask them to: each person records over the same
/// passage, one after the other, and the app lays the turns end to end.
///
/// Who may do what is the database's to decide (0159). What is here is what
/// only a phone can do: name the passage from its own bars, find the draft
/// somebody recorded for their turn, and write the conversation as one file.
///
/// There is no score, vote, count, timer or winner in this file, and the
/// copy in it is tested for the words that would make one.

/// The conversation as one file, and how to read the player's position back
/// as whose turn is sounding.
class TurnsTrack {
  const TurnsTrack({
    required this.path,
    required this.roundId,
    required this.passage,
    required this.turns,
  });

  final String path;
  final String roundId;
  final PracticeLoop passage;

  /// The turns in the file, in the order they sound.
  final List<LoopSeat> turns;

  /// How long each turn runs: the passage, exactly, so the loop under them
  /// never loses its place between one player and the next.
  int get turnMs => passage.endMs - passage.startMs;

  /// Whose turn is sounding at [fileMs].
  LoopSeat? turnAt(int fileMs) {
    if (turns.isEmpty || turnMs <= 0) return null;
    final at = (fileMs ~/ turnMs).clamp(0, turns.length - 1).toInt();
    return turns[at];
  }
}

abstract final class TakeTurns {
  /// The words on the control that starts one.
  static const String startLabel = 'Take turns';

  /// How many bars are offered first on a song with bars and no part under
  /// the playhead. Eight: long enough to say something, short enough that
  /// four people round is still a minute. The plan's sixteen is one tap up.
  static const int offeredBars = 8;

  /// How long a passage runs on a song with nothing to count bars on.
  static const int offeredMs = 16000;

  /// The passage to offer first: the part of the song the playhead is in,
  /// or else [offeredBars] from the bar under it, or else [offeredMs] from
  /// where it is, named by the clock.
  ///
  /// Never null, because a song with no recording still has a click to go
  /// round, and a round needs only two times.
  static PracticeLoop offeredPassage({
    required int atMs,
    List<StructureSection> sections = const <StructureSection>[],
    List<int> downbeatsMs = const <int>[],
    int? songEndMs,
  }) {
    final parts = sectionLoops(sections);
    for (final part in parts) {
      if (atMs >= part.startMs && atMs < part.endMs) return part;
    }
    if (downbeatsMs.length >= 2) {
      final first = barNumberAt(atMs, downbeatsMs) ?? 1;
      final bars = barLoop(
        firstBar: first,
        lastBar: math.min(first + offeredBars - 1, downbeatsMs.length),
        downbeatsMs: downbeatsMs,
        songEndMs: songEndMs,
      );
      if (bars != null) {
        return loopFor(
              bars.startMs,
              bars.endMs,
              sections: sections,
              downbeatsMs: downbeatsMs,
            ) ??
            bars;
      }
    }
    final start = math.max(0, atMs);
    var end = start + offeredMs;
    if (songEndMs != null && songEndMs > start) end = math.min(end, songEndMs);
    return PracticeLoop(startMs: start, endMs: end, label: _clock(start, end));
  }

  /// What this phone calls a round's passage: the part with exactly those
  /// edges, or the bars they cover, or the clock. Worked out here rather
  /// than sent, the way Follow me does it (see loopFor).
  static PracticeLoop passageOf(
    LoopRound round, {
    List<StructureSection> sections = const <StructureSection>[],
    List<int> downbeatsMs = const <int>[],
  }) {
    return loopFor(
          round.startMs,
          round.endMs,
          sections: sections,
          downbeatsMs: downbeatsMs,
        ) ??
        PracticeLoop(
          startMs: round.startMs,
          endMs: round.endMs,
          label: _clock(round.startMs, round.endMs),
        );
  }

  static String _clock(int startMs, int endMs) =>
      '${MomentNote.clockOf(startMs)}–${MomentNote.clockOf(endMs)}';

  /// Every take that is a turn of any of [rounds]. They all sit on the same
  /// few bars, so the ordinary mix leaves them off until somebody turns one
  /// on: six solos at once is not what anybody played.
  static Set<String> turnIds(Iterable<LoopRound> rounds) => <String>{
        for (final round in rounds) ...round.turnLayerIds,
      };

  /// The conversation: the turns the room can hear, in the order of the
  /// round, for the takes that are on this phone.
  ///
  /// By the order and never by when a turn was recorded: somebody who came
  /// back in sits at the end of the line, and that is where they are heard.
  static List<LoopSeat> conversation(
    LoopRound round, {
    required Set<String> playable,
  }) =>
      <LoopSeat>[
        for (final seat in round.played)
          if (playable.contains(seat.layerId)) seat,
      ];

  /// How far past the end of the passage a turn may run and still be taken
  /// for one. A turn stops itself where the passage ends, give or take the
  /// recorder's tick; a whole verse recorded from the same bar is a take,
  /// not a turn.
  static const int turnSlackMs = 1500;

  /// The draft somebody recorded for their turn and has not handed in: their
  /// latest take that starts on the passage and runs no longer than it, is
  /// still theirs alone, was recorded since the round started and is not
  /// already a turn.
  ///
  /// Found rather than remembered, so leaving the screen between recording
  /// a turn and handing it in loses nothing, and nothing has to be kept on
  /// the phone to say which take was meant.
  static SharedLayer? draftFor(
    LoopRound round,
    Iterable<SharedLayer> layers, {
    required String? me,
    Set<String> alreadyTurns = const <String>{},
  }) {
    if (me == null) return null;
    SharedLayer? latest;
    for (final layer in layers) {
      if (layer.recordedBy != me || layer.isShared) continue;
      if (layer.startMs != round.startMs) continue;
      if (layer.durationMs > round.lengthMs + turnSlackMs) continue;
      if (layer.createdAt.isBefore(round.startedAt)) continue;
      if (alreadyTurns.contains(layer.id)) continue;
      if (latest == null || layer.createdAt.isAfter(latest.createdAt)) {
        latest = layer;
      }
    }
    return latest;
  }

  /// The one line under the passage: whose turn it is, in words.
  ///
  /// Names and words, never a number: not how many have played, not how
  /// long anybody has had, not who has not. A round nobody is waiting on
  /// says only that it has been round.
  static String lineFor(LoopRound round, {required String? me}) {
    if (round.ended) return 'This one is finished.';
    if (round.isUp(me)) return 'Your turn.';
    final name = round.upName;
    if (name != null) return '$name is up.';
    return 'It has been round. Anybody can still come in.';
  }

  /// [takes] with every turn in [turns] silenced: the loop a turn is
  /// recorded against, and the loop under each turn when it is heard back.
  /// Everything else stays as this person has it.
  static List<Take> withoutTurns(List<Take> takes, Set<String> turns) => <Take>[
        for (final take in takes)
          if (turns.contains(take.id)) take.copyWith(enabled: false) else take,
      ];

  /// The passage of [backing] with [turn] laid over it.
  ///
  /// Both are whole-song signals from Multitrack.mix with fit off, so a
  /// sample index means the same place in each. A turn that stops early is
  /// heard stopping; one that runs past the passage is cut where the
  /// passage ends, so the next player comes in on the one.
  static Float64List turnOver(
    Float64List backing,
    Float64List turn, {
    required int startMs,
    required int endMs,
  }) {
    final from = (startMs * Multitrack.rate / 1000).round();
    final to = (endMs * Multitrack.rate / 1000).round();
    final length = math.max(0, to - from);
    final out = Float64List(length);
    for (var i = 0; i < length; i += 1) {
      final at = from + i;
      var value = 0.0;
      if (at < backing.length) value += backing[at];
      if (at < turn.length) value += turn[at];
      out[i] = value;
    }
    return out;
  }

  /// [segments] end to end as one signal, with no gap: the loop keeps going
  /// round while the players change.
  ///
  /// Fitted once, together, the way then and now fits its two halves: each
  /// turn turned down on its own would make the quiet player loud and the
  /// loud one quiet, which says something nobody meant.
  static Float64List splice(List<Float64List> segments) {
    var total = 0;
    for (final segment in segments) {
      total += segment.length;
    }
    final out = Float64List(total);
    var at = 0;
    for (final segment in segments) {
      out.setAll(at, segment);
      at += segment.length;
    }
    var peak = 0.0;
    for (final value in out) {
      final magnitude = value.abs();
      if (magnitude > peak) peak = magnitude;
    }
    if (peak > 1.0) {
      final factor = 0.99 / peak;
      for (var i = 0; i < out.length; i += 1) {
        out[i] *= factor;
      }
    }
    return out;
  }

  /// Writes the conversation to [outputPath] as one wav.
  ///
  /// One file rather than a play per turn, for the reason at the top of
  /// multitrack.dart: one file has nothing to drift against and nothing to
  /// wait for between players. [takes] are the song's takes as this person
  /// hears them; [turns] is [conversation]. The loop under every turn is the
  /// same mix -- everything that is not a turn of this round -- so it is
  /// mixed once, and each turn is laid over its own copy of the passage.
  static Future<TurnsTrack> write({
    required List<Take> takes,
    required LoopRound round,
    required PracticeLoop passage,
    required List<LoopSeat> turns,
    required String outputPath,
  }) async {
    final backingTakes = withoutTurns(takes, round.turnLayerIds);
    final heard = <String>{for (final seat in turns) seat.layerId!};
    // Decoded once per take. samplesFor caches beside the file, so for
    // anything the ordinary mix already used this is a read.
    final audio = <Float64List>[];
    for (var i = 0; i < takes.length; i += 1) {
      final wanted = backingTakes[i].enabled || heard.contains(takes[i].id);
      audio.add(wanted ? await Multitrack.samplesFor(takes[i]) : Float64List(0));
    }
    final backing = Multitrack.mix(backingTakes, audio, fit: false).samples;
    final segments = <Float64List>[];
    for (final seat in turns) {
      final at = takes.indexWhere((take) => take.id == seat.layerId);
      if (at < 0) continue;
      // The turn on its own, placed and trimmed by the mixer's own rules,
      // and heard whether or not its lane is switched on.
      final alone = Multitrack.mix(
        <Take>[takes[at].copyWith(enabled: true)],
        <Float64List>[audio[at]],
        fit: false,
      ).samples;
      segments.add(turnOver(
        backing,
        alone,
        startMs: passage.startMs,
        endMs: passage.endMs,
      ));
    }
    await File(outputPath).writeAsBytes(
      LatencyProbe.toWav(splice(segments), rate: Multitrack.rate),
      flush: true,
    );
    return TurnsTrack(
      path: outputPath,
      roundId: round.id,
      passage: passage,
      turns: <LoopSeat>[
        for (final seat in turns)
          if (takes.any((take) => take.id == seat.layerId)) seat,
      ],
    );
  }
}
