import 'dart:math' as math;

import '../domain/song_analysis_models.dart';
import 'chord_beat_grid.dart';

/// Correct a chord once, and everywhere the passage comes round again.
///
/// A correction is saved at one moment in the song. The model heard the wrong
/// chord in the third bar of the chorus, and it heard the same wrong chord in
/// the third bar of every chorus, because it was listening to the same
/// passage. Fixing it three times is the chore that makes somebody stop
/// fixing it at all (Every Musician, Same Song, 17 September 2026: slice 36
/// finishes step 3 of "A Second Pair of Ears", which saved a correction at one
/// moment and spread it nowhere).
///
/// This finds where the passage repeats and what the correction would do
/// there. It applies nothing. The panel asks first, in one line with a yes and
/// a no, because a correction that spreads on its own is a guess with a
/// person's name on it.
///
/// Repeats are the sections that carry the same label: every chorus is a
/// "Chorus". The place inside a repeat is the same bar, counted from the
/// section's first bar, when the recording has downbeats; without them it is
/// the same distance into the section. Sections that are not repeats of each
/// other are never guessed across, and a chord somebody typed by hand in a
/// repeat is left exactly as they typed it.

/// One place the same passage comes round again, and what the correction
/// would do there.
class ChordRepeatTarget {
  const ChordRepeatTarget({
    required this.section,
    required this.startMs,
    required this.endMs,
    this.replaces,
  });

  /// The repeat the chord lands in.
  final StructureSection section;
  final int startMs;
  final int endMs;

  /// The detected cue standing where the corrected chord lands, which goes
  /// when the correction is applied. Null when nothing was detected changing
  /// there, and the chord is added the way tapping a bare word adds one.
  final ChordCue? replaces;
}

/// The offer: the chord as corrected, the section it was corrected in, and
/// each repeat it could be applied to.
class ChordRepeatOffer {
  const ChordRepeatOffer({
    required this.chord,
    required this.section,
    required this.targets,
  });

  final String chord;
  final StructureSection section;
  final List<ChordRepeatTarget> targets;

  /// "Also in the other two choruses?" — the one line the panel asks.
  String get question => repeatQuestion(section, targets.length);
}

/// The question, with the part named the way the band names it.
///
/// A label the model gave has a plural; a name the band gave does not — "the
/// big one" cannot be made plural by a program without reading badly — so a
/// renamed or unfamiliar part is asked about as "the other parts called".
String repeatQuestion(StructureSection section, int count) {
  final many = count == 1 ? '' : '${_countWord(count)} ';
  final plural = section.isRenamed ? null : _plurals[section.label];
  if (plural != null) {
    final part = count == 1 ? section.label.toLowerCase() : plural;
    return 'Also in the other $many$part?';
  }
  final parts = count == 1 ? 'part' : 'parts';
  return 'Also in the other $many$parts called ${section.displayLabel}?';
}

const Map<String, String> _plurals = <String, String>{
  'Intro': 'intros',
  'Verse': 'verses',
  'Chorus': 'choruses',
  'Bridge': 'bridges',
  'Instrumental': 'instrumentals',
  'Solo': 'solos',
  'Break': 'breaks',
  'Outro': 'outros',
};

String _countWord(int count) {
  const words = <String>[
    '', '', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
  ];
  return count < words.length ? words[count] : '$count';
}

/// Where a corrected chord would also go, or null when there is nowhere.
///
/// [startMs] and [endMs] are the correction as saved; [chord] is what it now
/// says. [originalStartMs] is where the detected cue it replaced started, when
/// it replaced one: that is the moment used to find the counterpart in each
/// repeat, because the model put both on the beat it heard the change on,
/// while the corrected start is interpolated from the word it sits over and
/// can drift from the beat by more than a chord change is wide.
///
/// Null rather than an empty offer whenever there is nothing to ask, so the
/// caller has one thing to check.
ChordRepeatOffer? findChordRepeats({
  required SongAnalysisBundle bundle,
  required String chord,
  required int startMs,
  required int endMs,
  int? originalStartMs,
}) {
  final reference = bundle.reference;
  if (reference == null) return null;
  final sections = reference.structureSections;
  final home = _sectionAt(sections, startMs);
  if (home == null) return null;
  final family = _family(home);
  if (family.isEmpty) return null;

  final downbeats = List<int>.of(reference.downbeatsMs)..sort();
  final beats = List<int>.of(reference.beatsMs)..sort();
  final tolerance = _toleranceMs(beats);
  final cues = List<ChordCue>.of(bundle.chordCues)
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  final wanted = chord.trim();
  // The detected change this correction stands for, when it stands for one
  // in this section. A chord added where nothing was detected has no
  // counterpart to look for.
  final anchor = originalStartMs != null &&
          originalStartMs >= home.startMs &&
          originalStartMs < home.endMs
      ? originalStartMs
      : null;

  final targets = <ChordRepeatTarget>[];
  for (final repeat in sections) {
    if (repeat.startMs == home.startMs && repeat.endMs == home.endMs) continue;
    if (_family(repeat) != family || repeat.durationMs <= 0) continue;

    final moment = _mapMoment(home, repeat, startMs, downbeats);
    if (moment == null) continue;
    final mappedEnd = _mapMoment(home, repeat, endMs, downbeats) ??
        math.min(repeat.endMs, moment + (endMs - startMs));
    final end = math.max(moment + 120, mappedEnd);

    ChordCue? counterpart;
    if (anchor != null) {
      final there = _mapMoment(home, repeat, anchor, downbeats);
      if (there != null) counterpart = _nearestStart(cues, there, tolerance);
    }
    // Hand-typed anywhere the correction would land, or right beside it:
    // this repeat has been gone over by a person, and stays theirs.
    final handTyped = cues.any((cue) =>
        cue.isManual &&
        ((cue.endMs > moment && cue.startMs < end) ||
            (cue.startMs - moment).abs() <= tolerance));
    if (handTyped || (counterpart?.isManual ?? false)) continue;

    final standing = counterpart ?? _soundingAt(cues, moment);
    if (standing != null && standing.chord.trim() == wanted) continue;

    targets.add(ChordRepeatTarget(
      section: repeat,
      startMs: moment,
      endMs: end,
      replaces: counterpart,
    ));
  }
  if (targets.isEmpty) return null;
  return ChordRepeatOffer(chord: wanted, section: home, targets: targets);
}

/// Which part this is a repeat of.
///
/// Analyses since the parts were named share a label between repeats. The
/// lettered analyses before that gave every section its own letter and
/// pointed each repeat at the earlier section it resembled, so a pointer
/// names the family and a section without one is its own.
String _family(StructureSection section) {
  final pointer = section.repeatsSectionLabel?.trim() ?? '';
  return pointer.isNotEmpty ? pointer : section.label.trim();
}

StructureSection? _sectionAt(List<StructureSection> sections, int ms) {
  for (final section in sections) {
    if (ms >= section.startMs && ms < section.endMs) return section;
  }
  return null;
}

/// Half a beat: anything further from a moment than that is nearer to some
/// other beat, and the model puts its changes on beats. Without a grid the
/// counterpart is found by proportion, which is rougher, so the window is
/// wider.
int _toleranceMs(List<int> beats) {
  if (beats.length >= 4) {
    final beat = medianBeatIntervalMs(beats);
    if (beat > 0) return (beat / 2).round();
  }
  return 600;
}

/// The same moment in [repeat] as [ms] is in [home].
///
/// By bar when the grid reaches: the bar [ms] is in, counted from the bar
/// the section starts nearest to, and the same way into that bar. A section
/// boundary from the structure model sits a few frames either side of the
/// downbeat it means, which is why its first bar is the nearest one and not
/// the one containing it. Null when the repeat is too short to have that bar,
/// so a half-length last chorus is not given a chord from a bar it does not
/// play. Before the first downbeat, and without a grid at all, the same
/// distance into the section.
int? _mapMoment(
  StructureSection home,
  StructureSection repeat,
  int ms,
  List<int> downbeats,
) {
  if (downbeats.length >= 2) {
    final homeFirst = _nearestIndex(home.startMs, downbeats);
    final repeatFirst = _nearestIndex(repeat.startMs, downbeats);
    final bar = barNumberAt(ms, downbeats);
    if (bar != null && bar - 1 >= homeFirst) {
      final target = repeatFirst + (bar - 1 - homeFirst);
      if (target >= downbeats.length) return null;
      final targetStart = downbeats[target];
      if (targetStart >= repeat.endMs) return null;
      final barStart = downbeats[bar - 1];
      final barLength =
          bar < downbeats.length ? downbeats[bar] - barStart : 0;
      final targetLength = target + 1 < downbeats.length
          ? downbeats[target + 1] - targetStart
          : barLength;
      final fraction = barLength <= 0
          ? 0.0
          : ((ms - barStart) / barLength).clamp(0.0, 1.0);
      return targetStart + (fraction * targetLength).round();
    }
  }
  if (home.durationMs <= 0) return null;
  final fraction = ((ms - home.startMs) / home.durationMs).clamp(0.0, 1.0);
  return repeat.startMs + (fraction * repeat.durationMs).round();
}

int _nearestIndex(int ms, List<int> sorted) {
  var best = 0;
  for (var i = 1; i < sorted.length; i += 1) {
    if ((sorted[i] - ms).abs() < (sorted[best] - ms).abs()) best = i;
  }
  return best;
}

/// The cue whose change is nearest [ms], within [toleranceMs] of it.
ChordCue? _nearestStart(List<ChordCue> cues, int ms, int toleranceMs) {
  ChordCue? best;
  for (final cue in cues) {
    final distance = (cue.startMs - ms).abs();
    if (distance > toleranceMs) continue;
    if (best == null || distance < (best.startMs - ms).abs()) best = cue;
  }
  return best;
}

/// The cue ringing at [ms]: the last one to have started by then.
ChordCue? _soundingAt(List<ChordCue> cues, int ms) {
  ChordCue? sounding;
  for (final cue in cues) {
    if (cue.startMs > ms) break;
    if (cue.endMs > ms) sounding = cue;
  }
  return sounding;
}
