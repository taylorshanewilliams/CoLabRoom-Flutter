import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/moment_note.dart' show MomentNote;
import '../../services/chord_beat_grid.dart' show barNumberAt;
import '../../services/latency_probe.dart';
import '../../services/multitrack.dart';
import '../../services/song_layer_service.dart';
import '../../services/take_naming.dart';
import '../workspace/practice_rules.dart';

/// Then and now: today's take beside the first one, on the same bars.
///
/// Every Musician, Same Song, 17 September 2026, for beginners at every age:
/// they arrive wanting it and leave the first time they feel judged or
/// stuck. The one thing that shows a beginner they are getting somewhere
/// without anybody saying so is hearing their own first go beside today's,
/// on the same few bars, and letting their ears decide. So this plays one
/// passage twice -- once from the first take of a part, once from the
/// latest, one after the other at the same speed -- and says nothing about
/// either beyond which is which.
///
/// The words are "then" and "now". Never "improved", never a score, never
/// how long ago: that is the plan's rule, and the reason the copy in this
/// file is tested for time words. Somebody hearing themselves a year apart
/// knows what they are hearing. The app's job is to put the two beside each
/// other and get out of the way.
///
/// The first take of a part is kept past the retention sweep for the same
/// reason (tools/expire_layers.py): there is no "then" to come back to if
/// the sweep took it while nobody was practising.

/// Which half is sounding.
enum ThenOrNow {
  then,
  now;

  String get label => this == ThenOrNow.then ? 'Then' : 'Now';
}

/// A part somebody has recorded more than once: their first take of it,
/// their latest, and every take of theirs in between.
class ThenAndNowPair {
  ThenAndNowPair({required this.group}) : assert(group.length >= 2);

  /// Every take of this part by this person, first to latest.
  final List<SharedLayer> group;

  SharedLayer get then => group.first;
  SharedLayer get now => group.last;

  /// Every take in the group, for silencing the ones not being heard.
  Set<String> get ids => <String>{for (final layer in group) layer.id};

  /// "Dylan's lead", or "lead": the part and the person.
  ///
  /// Not either take's own name. The two were named at different times and
  /// may say different things, and a pair called "Lead 3" is not a pair.
  String get name {
    final who = now.attributedTo;
    final what = now.part.label;
    return who == null ? what : TakeNaming.belongingTo(who, what);
  }

  /// Where both takes exist on the song, in milliseconds: from the later
  /// start to the earlier end. The bars they can be heard on are in here.
  int get sharedStartMs => math.max(then.startMs, now.startMs);
  int get sharedEndMs => math.min(
        then.startMs + then.durationMs,
        now.startMs + now.durationMs,
      );

  /// The same pair by the same two takes, so the chip that started it can
  /// tell it is the one playing.
  @override
  bool operator ==(Object other) =>
      other is ThenAndNowPair && other.then.id == then.id && other.now.id == now.id;

  @override
  int get hashCode => Object.hash(then.id, now.id);
}

/// The file the two halves were written to, and how to read the player's
/// position back as a place on the song.
///
/// The player reports where it is in the file. The screen shows where that
/// is in the song, which is the passage twice over with a breath between:
/// the playhead crosses the same bars once for "then" and once for "now".
class ThenAndNowTrack {
  const ThenAndNowTrack({
    required this.path,
    required this.pair,
    required this.passage,
    this.breathMs = ThenAndNow.breathMs,
  });

  final String path;
  final ThenAndNowPair pair;
  final PracticeLoop passage;
  final int breathMs;

  /// How long each half runs.
  int get halfMs => passage.endMs - passage.startMs;

  /// Where in the file "now" begins.
  int get nowFromMs => halfMs + breathMs;

  /// Which half is sounding at [fileMs]. The breath belongs to "then": it is
  /// the silence after it, before "now" has begun.
  ThenOrNow halfAt(int fileMs) =>
      fileMs < nowFromMs ? ThenOrNow.then : ThenOrNow.now;

  /// Where on the song [fileMs] is.
  int songMsAt(int fileMs) {
    final into = fileMs < nowFromMs ? fileMs : fileMs - nowFromMs;
    return passage.startMs + into.clamp(0, halfMs).toInt();
  }
}

/// The rules, kept apart from the screen so they can be tested without a
/// player or a file.
abstract final class ThenAndNow {
  /// How many bars a passage runs, on a song with bars. A phrase: long
  /// enough to hear a line through, short enough to hold both in the ear.
  static const int passageBars = 4;

  /// How long a passage runs on a song with no bar grid to count on.
  static const int passageMs = 8000;

  /// The silence between then and now. A breath, so the ear lets go of one
  /// before the other starts, and short enough that it is plainly a pause
  /// rather than the end.
  static const int breathMs = 700;

  /// The one word on the chip.
  static const String chipLabel = 'Then and now';

  /// Every pair on the song, the one most recently added to first.
  ///
  /// A pair is one person's first and latest take of one part, where the
  /// two cover some of the same song. Grouped by the account that recorded
  /// them rather than by the typed performer, because the account is the
  /// person who was practising: a teacher's demonstration of the lead in a
  /// lesson room is not the student's "then", however the takes are
  /// labelled. Takes that never overlap -- a first verse and a last chorus
  /// -- have no same bars to hear, and are not a pair.
  ///
  /// The part is taken as it was picked, "part" included. A beginner who
  /// never chooses one still has a first take and a latest, and the point
  /// of this is that they hear them.
  static List<ThenAndNowPair> pairs(Iterable<SharedLayer> layers) {
    final groups = <(String, TakePart), List<SharedLayer>>{};
    for (final layer in layers) {
      groups
          .putIfAbsent((layer.recordedBy, layer.part), () => <SharedLayer>[])
          .add(layer);
    }
    final out = <ThenAndNowPair>[];
    for (final group in groups.values) {
      if (group.length < 2) continue;
      final ordered = <SharedLayer>[...group]..sort(_byRecording);
      final pair = ThenAndNowPair(group: ordered);
      if (pair.sharedEndMs <= pair.sharedStartMs) continue;
      out.add(pair);
    }
    // The pair somebody just added a take to is the one they came to hear.
    out.sort((a, b) => b.now.createdAt.compareTo(a.now.createdAt));
    return out;
  }

  /// By when it was recorded; by id when two were recorded in the same
  /// instant, so the first take is the same one on every phone.
  static int _byRecording(SharedLayer a, SharedLayer b) {
    final byTime = a.createdAt.compareTo(b.createdAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  /// The bars to hear twice.
  ///
  /// From the bar under the playhead, [passageBars] of them, cut to where
  /// both takes exist. A playhead outside that stretch starts at the first
  /// bar both takes share, and a pickup ahead of bar 1 starts where the
  /// bars do (see barNumberAt). Without a grid, [passageMs] from the
  /// playhead, named by the clock. Null only when the pair shares nothing,
  /// which [pairs] already refuses.
  static PracticeLoop? passage(
    ThenAndNowPair pair, {
    required int atMs,
    List<int> downbeatsMs = const <int>[],
    int? songEndMs,
  }) {
    final from = pair.sharedStartMs;
    final to = pair.sharedEndMs;
    if (to <= from) return null;
    final at = atMs.clamp(from, to - 1).toInt();

    if (downbeatsMs.isNotEmpty) {
      final first = barNumberAt(at, downbeatsMs) ?? 1;
      final start = math.max(barStartMs(first, downbeatsMs), from);
      final end = math.min(
        barEndMs(first + passageBars - 1, downbeatsMs, songEndMs: songEndMs),
        to,
      );
      if (end > start) {
        final onBars = loopFor(start, end, downbeatsMs: downbeatsMs);
        if (onBars != null) return onBars;
        return PracticeLoop(startMs: start, endMs: end, label: _clock(start, end));
      }
      // Both takes end before the bars begin: a pickup, or a count-in. Heard
      // by the clock instead, the way a song with no grid is.
    }

    final end = math.min(at + passageMs, to);
    return PracticeLoop(startMs: at, endMs: end, label: _clock(at, end));
  }

  static String _clock(int startMs, int endMs) =>
      '${MomentNote.clockOf(startMs)}–${MomentNote.clockOf(endMs)}';

  /// [takes] as one half hears them: of the pair's takes only [heard] is on,
  /// and everything else stays as this person has it -- muted, forward, at
  /// the room's levels. Then and now is the mix with one take swapped, not
  /// a different mix.
  static List<Take> half(
    List<Take> takes,
    ThenAndNowPair pair, {
    required String heard,
  }) {
    final ids = pair.ids;
    return <Take>[
      for (final take in takes)
        if (ids.contains(take.id))
          take.copyWith(enabled: take.id == heard)
        else
          take,
    ];
  }

  /// [thenMix] and [nowMix] from [startMs] to [endMs], one after the other
  /// with a breath between, as one signal.
  ///
  /// One file rather than two plays, for the reason at the top of
  /// multitrack.dart: one file has nothing to drift against, and nothing to
  /// wait for between the halves. A mix shorter than the passage pads with
  /// silence, so a take that stops early is heard stopping rather than
  /// throwing.
  ///
  /// Fitted once, together. Each half came from Multitrack.mix with fit off,
  /// so the two are at the same level relative to each other, and turning
  /// the whole thing down here keeps them that way.
  static Float64List splice(
    Float64List thenMix,
    Float64List nowMix, {
    required int startMs,
    required int endMs,
    int breathMs = ThenAndNow.breathMs,
  }) {
    final from = (startMs * Multitrack.rate / 1000).round();
    final to = (endMs * Multitrack.rate / 1000).round();
    final half = math.max(0, to - from);
    final breath = math.max(0, (breathMs * Multitrack.rate / 1000).round());
    final out = Float64List(half * 2 + breath);
    _copy(thenMix, from, out, 0, half);
    _copy(nowMix, from, out, half + breath, half);

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

  static void _copy(
    Float64List source,
    int from,
    Float64List out,
    int at,
    int count,
  ) {
    final available = math.min(count, source.length - from);
    for (var i = 0; i < available; i += 1) {
      out[at + i] = source[from + i];
    }
  }

  /// Writes the two halves to [outputPath] as one wav, and says how to read
  /// it back.
  ///
  /// [takes] are the song's takes as this person hears them -- the same list
  /// the ordinary mix is built from, with their part forward or left out
  /// already applied -- so then and now sounds like the mix they know with
  /// one take swapped. The click is left out on purpose: it is a way of
  /// playing along, and nobody plays along with a passage heard twice.
  static Future<ThenAndNowTrack> write({
    required List<Take> takes,
    required ThenAndNowPair pair,
    required PracticeLoop passage,
    required String outputPath,
  }) async {
    final thenHalf = half(takes, pair, heard: pair.then.id);
    final nowHalf = half(takes, pair, heard: pair.now.id);
    // Decoded once per take, for both halves. samplesFor caches beside the
    // file, so for anything the ordinary mix already used this is a read.
    final audio = <Float64List>[];
    for (var i = 0; i < takes.length; i += 1) {
      final wanted = thenHalf[i].enabled || nowHalf[i].enabled;
      audio.add(wanted ? await Multitrack.samplesFor(takes[i]) : Float64List(0));
    }
    final thenMix = Multitrack.mix(thenHalf, audio, fit: false).samples;
    final nowMix = Multitrack.mix(nowHalf, audio, fit: false).samples;
    final spliced = splice(
      thenMix,
      nowMix,
      startMs: passage.startMs,
      endMs: passage.endMs,
    );
    await File(outputPath).writeAsBytes(
      LatencyProbe.toWav(spliced, rate: Multitrack.rate),
      flush: true,
    );
    return ThenAndNowTrack(path: outputPath, pair: pair, passage: passage);
  }
}
