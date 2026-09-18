import 'dart:math' as math;

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';
import 'package:colabroom/services/chord_beat_grid.dart';
import 'package:colabroom/services/chord_names.dart';
import 'package:colabroom/services/horn_reading.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:colabroom/services/number_reading.dart';

class MusicianSheetLine {
  const MusicianSheetLine({
    required this.contributionId,
    required this.body,
    required this.section,
    required this.startMs,
    required this.endMs,
    required this.chords,
    required this.approximateTiming,
    this.wordStartsMs,
    this.bar,
  });

  final String? contributionId;
  final String body;
  final bool section;
  final int startMs;
  final int endMs;
  final List<ChordCue> chords;
  final bool approximateTiming;

  /// One real start timestamp per word in [body], in the same order —
  /// only set when the line came from actual transcribed word timing
  /// (see _transcriptLines), null for proportional/manual-guess lines.
  /// Lets chordPlacementsForLine anchor a chord to the word that's
  /// actually sounding when it changes, instead of assuming every word
  /// in the line takes the same amount of time to sing.
  final List<int>? wordStartsMs;

  /// The bar this line starts in, 1-indexed, or null when the recording has
  /// no beat grid (and for anything before the first downbeat — a pickup
  /// isn't in bar 1 and shouldn't be labelled as if it were).
  ///
  /// This is what "come in on 17" is written next to on paper, and the
  /// reason beat tracking was worth building: it turns a line that happens
  /// at 48.2 seconds into a line a band can find.
  final int? bar;
}

List<Contribution> visibleMusicianLyrics(SongProject project) {
  return project.contributions
      .where((line) {
        final body = displayContributionBody(line.body).trim();
        return line.kind != ContributionKind.note &&
            !isSheetSection(line) &&
            body.isNotEmpty;
      })
      .toList(growable: false);
}

double lyricTimingWeight(Contribution line) {
  final body = displayContributionBody(line.body).trim();
  final words = body
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .length;
  final punctuationPause = RegExp(r'[.!?…]$').hasMatch(body) ? 0.55 : 0.0;
  return (1.0 + words * 0.62 + body.length * 0.012 + punctuationPause)
      .clamp(1.0, 14.0)
      .toDouble();
}

/// Creates a usable current-project lyric timeline even when stored analysis
/// cues point at lyric rows that were later replaced or edited.
///
/// Exact current-line cues are retained. Missing lines are interpolated in
/// document order using phrase length, which is a better fallback than giving
/// every lyric line exactly the same share of the recording.
List<LyricSyncCue> buildPerformanceLyricCues(
  SongProject project,
  SongAnalysisBundle bundle,
) {
  final lyrics = visibleMusicianLyrics(project);
  if (lyrics.isEmpty) return const <LyricSyncCue>[];

  final validIds = lyrics.map((line) => line.id).toSet();
  final exactById = <String, LyricSyncCue>{
    for (final cue in bundle.lyricCues)
      if (validIds.contains(cue.contributionId)) cue.contributionId: cue,
  };
  final explicitEnd = exactById.values.fold<int>(
    0,
    (largest, cue) => math.max(largest, cue.endMs),
  );
  final chordEnd =
      bundle.chordCues.isEmpty ? 0 : bundle.chordCues.last.endMs;
  var duration = math
      .max(
        bundle.reference?.durationMs ?? 0,
        math.max(explicitEnd, chordEnd),
      )
      .toInt();
  if (duration <= 0) {
    duration = math.max(12000, lyrics.length * 3600).toInt();
  }

  final count = lyrics.length;
  final pad = (duration * 0.025).round().clamp(0, duration ~/ 4).toInt();
  final starts = List<int?>.filled(count, null);
  final exactAt = <int, LyricSyncCue>{};
  var lastAccepted = -1;

  for (var index = 0; index < count; index += 1) {
    final exact = exactById[lyrics[index].id];
    if (exact == null) continue;
    final start = exact.startMs.clamp(0, duration).toInt();
    if (start <= lastAccepted) continue;
    starts[index] = start;
    exactAt[index] = exact;
    lastAccepted = start;
  }

  final anchors = <(int, int)>[(-1, pad)];
  for (var index = 0; index < count; index += 1) {
    final start = starts[index];
    if (start != null) anchors.add((index, start));
  }
  anchors.add((count, math.max(pad + 1, duration - pad).toInt()));

  for (var anchorIndex = 0;
      anchorIndex < anchors.length - 1;
      anchorIndex += 1) {
    final left = anchors[anchorIndex];
    final right = anchors[anchorIndex + 1];
    if (right.$1 <= left.$1 + 1 && left.$1 >= 0) continue;

    final weightStart = math.max(0, left.$1).toInt();
    final weightEnd = math.min(count, right.$1).toInt();
    var totalWeight = 0.0;
    for (var index = weightStart; index < weightEnd; index += 1) {
      totalWeight += lyricTimingWeight(lyrics[index]);
    }
    if (totalWeight <= 0) totalWeight = 1;

    var cumulative = 0.0;
    if (left.$1 >= 0 && left.$1 < count) {
      cumulative = lyricTimingWeight(lyrics[left.$1]);
    }
    final firstMissing = math.max(0, left.$1 + 1).toInt();
    final span = math.max(1, right.$2 - left.$2).toInt();
    for (var index = firstMissing;
        index < right.$1 && index < count;
        index += 1) {
      if (starts[index] == null) {
        starts[index] = left.$2 + (span * cumulative / totalWeight).round();
      }
      cumulative += lyricTimingWeight(lyrics[index]);
    }
  }

  for (var index = 1; index < count; index += 1) {
    final previous = starts[index - 1] ?? 0;
    final current = starts[index] ?? previous + 120;
    if (current <= previous) starts[index] = previous + 120;
  }

  final cues = <LyricSyncCue>[];
  for (var index = 0; index < count; index += 1) {
    final start = starts[index] ?? 0;
    final nextStart =
        index + 1 < count ? starts[index + 1] ?? duration : duration;
    final exact = exactAt[index];
    final availableEnd = math.max(start + 120, nextStart - 40).toInt();
    final end = exact == null
        ? availableEnd
        : math
            .min(
              availableEnd,
              math.max(start + 120, exact.endMs),
            )
            .toInt();
    cues.add(
      LyricSyncCue(
        contributionId: lyrics[index].id,
        startMs: start,
        endMs: end,
        confidence: exact?.confidence ?? 0.24,
        source: exact?.source ?? 'automatic',
      ),
    );
  }
  return cues;
}

List<LyricSyncCue> buildManualLyricCuesFromStarts({
  required List<Contribution> lyrics,
  required List<int> startsMs,
  required int durationMs,
}) {
  if (lyrics.isEmpty || startsMs.isEmpty || lyrics.length != startsMs.length) {
    throw ArgumentError('Every lyric line needs exactly one timing marker.');
  }
  var previous = -1;
  for (final start in startsMs) {
    if (start < 0 || start <= previous) {
      throw ArgumentError('Timing markers must move forward through the song.');
    }
    previous = start;
  }
  final safeDuration = math.max(durationMs, startsMs.last + 1200).toInt();
  return List<LyricSyncCue>.generate(lyrics.length, (index) {
    final start = startsMs[index];
    final next =
        index + 1 < startsMs.length ? startsMs[index + 1] : safeDuration;
    return LyricSyncCue(
      contributionId: lyrics[index].id,
      startMs: start,
      endMs: math.max(start + 120, next - 40).toInt(),
      confidence: 1.0,
      source: 'manual',
    );
  }, growable: false);
}

List<LyricSyncCue> nudgeLyricCues(
  List<LyricSyncCue> cues,
  int deltaMs, {
  required int durationMs,
}) {
  if (cues.isEmpty || deltaMs == 0) return cues;
  final earliest = cues.first.startMs;
  final applied = math.max(-earliest, deltaMs).toInt();
  final safeDuration = math.max(durationMs, cues.last.endMs + applied).toInt();
  return cues.map((cue) {
    final start = math.max(0, cue.startMs + applied).toInt();
    final end = math
        .min(
          safeDuration,
          math.max(start + 120, cue.endMs + applied),
        )
        .toInt();
    return LyricSyncCue(
      contributionId: cue.contributionId,
      startMs: start,
      endMs: end,
      confidence: 1.0,
      source: 'manual',
    );
  }).toList(growable: false);
}

/// Builds the lines for either the live collaborative workspace (default —
/// project.contributions with proportional-guess timing, no chords) or, when
/// [ignoreWorkspaceLyrics] is true, the Song Sheet: analysis output only
/// (transcript/chords from [bundle]), regardless of what's in the project's
/// own lyrics. Analysis output must never be influenced by or mixed with
/// manually-typed lyrics — the two stay fully independent.
List<MusicianSheetLine> buildMusicianSheetLines(
  SongProject project,
  SongAnalysisBundle bundle, {
  bool ignoreWorkspaceLyrics = false,
}) {
  final duration = bundle.reference?.durationMs ??
      (bundle.chordCues.isEmpty ? 0 : bundle.chordCues.last.endMs);
  if (ignoreWorkspaceLyrics) {
    return transcriptSheetLines(
      transcriptWords: bundle.reference?.transcriptWords ?? const <TranscriptWord>[],
      transcriptText: bundle.reference?.transcriptText,
      chordCues: bundle.chordCues,
      durationMs: duration,
      downbeatsMs: bundle.reference?.downbeatsMs ?? const <int>[],
    );
  }

  final contributions = project.contributions
      .where((line) =>
          line.kind != ContributionKind.note &&
          displayContributionBody(line.body).trim().isNotEmpty)
      .toList(growable: false);
  final lyrics = visibleMusicianLyrics(project);
  if (lyrics.isEmpty) {
    return transcriptSheetLines(
      transcriptWords: bundle.reference?.transcriptWords ?? const <TranscriptWord>[],
      transcriptText: bundle.reference?.transcriptText,
      chordCues: bundle.chordCues,
      durationMs: duration,
      downbeatsMs: bundle.reference?.downbeatsMs ?? const <int>[],
    );
  }

  final performanceById = <String, LyricSyncCue>{
    for (final cue in buildPerformanceLyricCues(project, bundle))
      cue.contributionId: cue,
  };
  return contributions.map((line) {
    final body = displayContributionBody(line.body).trimRight();
    if (isSheetSection(line)) {
      return MusicianSheetLine(
        contributionId: line.id,
        body: cleanSheetSection(body),
        section: true,
        startMs: 0,
        endMs: 0,
        chords: const <ChordCue>[],
        approximateTiming: false,
      );
    }
    final exact = bundle.cueForContribution(line.id);
    final cue = performanceById[line.id];
    final range = cue == null
        ? proportionalSheetRange(
            lyrics.indexWhere((candidate) => candidate.id == line.id),
            lyrics.length,
            duration,
          )
        : (cue.startMs, cue.endMs);
    return MusicianSheetLine(
      contributionId: line.id,
      body: body,
      section: false,
      startMs: range.$1,
      endMs: range.$2,
      chords: bundle
          .chordsForRange(range.$1, range.$2)
          .where((chord) => chord.isManual || chord.confidence >= 0.18)
          .toList(growable: false),
      approximateTiming: exact == null,
      // Only when the timing is real. An interpolated position doesn't know
      // what bar it's in, and a bar number is a promise that it does.
      bar: exact == null
          ? null
          : barNumberAt(range.$1, bundle.reference?.downbeatsMs ?? const <int>[]),
    );
  }).toList(growable: false);
}

Map<int, ChordCue> chordPlacementsForLine({
  required int wordCount,
  required int lineStartMs,
  required int lineEndMs,
  required List<ChordCue> chords,
  List<int>? wordStartsMs,
}) {
  if (wordCount <= 0 || chords.isEmpty) return const <int, ChordCue>{};
  final unique = <ChordCue>[];
  for (final chord in chords) {
    if (unique.isEmpty ||
        unique.last.chord != chord.chord ||
        unique.last.startMs != chord.startMs) {
      unique.add(chord);
    }
  }
  final hasWordTiming = wordStartsMs != null && wordStartsMs.length == wordCount;
  final span = math.max(1, lineEndMs - lineStartMs);
  final placements = <int, ChordCue>{};
  for (final chord in unique) {
    int index;
    if (hasWordTiming) {
      // Real per-word timestamps: anchor the chord to whichever word is
      // actually sounding when it changes. A uniform-spacing guess is
      // wrong whenever words in the line don't take equal time to sing
      // (a held note, a fast run, a mid-line breath) — which is most of
      // the time in an actual vocal performance.
      index = 0;
      for (var i = 0; i < wordStartsMs.length; i += 1) {
        if (wordStartsMs[i] <= chord.startMs) {
          index = i;
        } else {
          break;
        }
      }
    } else {
      final ratio = ((chord.startMs - lineStartMs) / span).clamp(0.0, 0.999);
      index = (ratio * wordCount).floor().clamp(0, wordCount - 1).toInt();
    }
    while (placements.containsKey(index) && index < wordCount - 1) {
      index += 1;
    }
    placements[index] = chord;
  }
  return placements;
}

int chordStartForWordIndex({
  required int wordIndex,
  required int wordCount,
  required int lineStartMs,
  required int lineEndMs,
}) {
  if (wordCount <= 1 || lineEndMs <= lineStartMs) return lineStartMs;
  final safeIndex = wordIndex.clamp(0, wordCount - 1).toInt();
  final ratio = safeIndex / wordCount;
  return lineStartMs + ((lineEndMs - lineStartMs) * ratio).round();
}

/// A chord moved by [semitones]: the root, and the bass under it.
///
/// It used to move only the root, so "G/B" up two came out "A/B" -- a
/// different chord with the wrong note in the bass player's hand (audit, 17
/// September 2026). Only a bass written as a note moves. Harte notation from
/// the analysis writes the bass as a degree of the chord ("G:maj/3" is G over
/// its third), and a degree counts from the root, so moving the root has
/// already moved it; moving "3" as well would move it twice. "C6/9" is a
/// quality with a slash in it, not a bass, and stays as written for the same
/// reason.
///
/// Names come out sharp. Spelling them the way the new key writes them needs
/// the key, which is what [chordAsPlayed] is for.
String transposeChord(String chord, int semitones) {
  if (semitones % 12 == 0) return chord;
  final match = RegExp(r'^([A-G][#b]?)(.*)$').firstMatch(chord.trim());
  if (match == null) return chord;
  final root = _moveNote(match.group(1)!, semitones);
  if (root == null) return chord;
  var rest = match.group(2)!;
  final slash = rest.lastIndexOf('/');
  if (slash >= 0) {
    final bass = _moveNote(rest.substring(slash + 1), semitones);
    if (bass != null) rest = '${rest.substring(0, slash + 1)}$bass';
  }
  return '$root$rest';
}

/// A chord as it is read off the page: moved into the key somebody is
/// playing in, written the way a musician writes it rather than in Harte,
/// and spelled the way that key spells it -- Bb/D in B-flat, not A#/D.
///
/// [key] is the song's key before transposing. The sheet, the chart and
/// Perform all draw their chords through this one call, so the same chord
/// cannot read differently on two of them.
String chordAsPlayed(String chord, {required int transpose, String? key}) =>
    spellInKey(
      chordDisplay(transposeChord(chord, transpose)),
      key == null ? null : transposeChord(key, transpose),
    );

/// The song's key, moved and spelled the same way as its chords.
String keyAsPlayed(String key, int transpose) {
  final moved = transposeChord(key, transpose);
  return spellInKey(moved, moved);
}

/// Semitones from [from] up to [to], 0 to 11, or 0 when either is missing
/// or not a key this can read.
///
/// The transpose that takes a song from its own key to the one a set does
/// it in, and the one the key sheet works out from the two keys it was
/// opened with. Between two keys in the same mode it is the distance
/// between their roots: a song in A minor done in C minor is up three.
///
/// Between a major key and a minor one no transposition exists, so the
/// second key is read as the band naming the same chords another way and
/// then moving them (review, 18 September 2026). The usual way a band and
/// the analyser disagree about a key is the relative -- the detector hears
/// A minor where the band knows C -- so a minor key counts from its
/// relative major, the rule the numbers already follow: A minor to C major
/// moves nothing, G major to E minor moves nothing, A minor to D major is
/// up two. The one exception is the parallel. A band writing A major over a
/// song the analyser called A minor is correcting the mode, not asking for
/// the chords nine semitones away, so the same root in the other mode moves
/// nothing either.
int semitonesBetweenKeys(String? from, String? to) {
  final pa = _keyRootPitch(from);
  final pb = _keyRootPitch(to);
  if (pa == null || pb == null) return 0;
  final fromMinor = keyIsMinor(from);
  final toMinor = keyIsMinor(to);
  if (fromMinor == toMinor || pa == pb) return ((pb - pa) % 12 + 12) % 12;
  final fromMajor = fromMinor ? pa + 3 : pa;
  final toMajor = toMinor ? pb + 3 : pb;
  return ((toMajor - fromMajor) % 12 + 12) % 12;
}

int? _keyRootPitch(String? key) {
  if (key == null) return null;
  final root = RegExp(r'^([A-G][#b]?)').firstMatch(key.trim())?.group(1);
  return root == null ? null : pitchOf(root);
}

/// A chord as this person is reading it: letters in their key, or the number
/// it is of the song's key.
///
/// The one call a sheet, a chart or Perform makes to draw a chord, so the
/// same chord cannot read differently on two of them. [transpose] is how far
/// the letters have moved — the person's own key, their instrument's part and
/// their capo, already added up by the caller. Numbers ignore all of it on
/// purpose: a chart in numbers is the same chart after the singer changes
/// key, which is the entire reason those players read it (Every Musician,
/// Same Song, 17 September 2026).
///
/// Falls back to letters when there is no key to count from, or when the
/// chord is not one this can place. A number nobody can trust is worse than
/// the letter it replaced.
String chordAsRead(
  String chord, {
  required int transpose,
  String? key,
  NumberReading numbers = NumberReading.letters,
}) {
  final letters = chordAsPlayed(chord, transpose: transpose, key: key);
  if (!numbers.on || key == null || key.trim().isEmpty) return letters;
  return chordAsDegree(
        chordDisplay(chord),
        key,
        roman: numbers.style == NumberStyle.roman,
        fromMinorTonic: numbers.minor == MinorNumbers.minorTonic,
      ) ??
      letters;
}

/// The line a capo puts under the key: "Capo 4 · G shapes · sounds in B".
///
/// A capo does not change what the band hears, it changes where the hand
/// goes — so both keys are named: the shapes because they are what is printed
/// on the page in front of the player, and the sounding key because that is
/// what they have to say out loud to everybody else. The same reason a horn
/// reading never drops the concert key.
///
/// [key] is the song's own key and [transpose] the semitones this person has
/// moved it, as everywhere else here. With no capo on it is just the key,
/// because a sheet should not label something that has not changed.
String capoLine(String key, {required int capo, required int transpose}) {
  final sounds = keyAsPlayed(key, transpose);
  if (capo <= 0) return sounds;
  return 'Capo $capo · ${keyAsPlayed(key, transpose - capo)} shapes · '
      'sounds in $sounds';
}

/// The key line a horn player reads: the written key, with the concert key
/// always beside it -- "For B♭ · written in E · concert D".
///
/// [key] is the song's own key, [transpose] the semitones this person has
/// moved it, and [reading] the instrument they read for. The concert key is
/// never dropped: a horn player calling a tune to the rest of the band has to
/// say the key everybody else is in, and a part that only knows its own key
/// is how a rehearsal loses five minutes (Every Musician, Same Song, 17
/// September 2026).
///
/// In concert pitch it is just the key, because there is no second key to
/// name and a sheet should not label something that has not changed.
String keyAsRead(
  String key, {
  required int transpose,
  required HornReading reading,
}) {
  final concert = keyAsPlayed(key, transpose);
  if (reading == HornReading.concert) return concert;
  final written = keyAsPlayed(key, transpose + reading.semitones);
  return 'For ${reading.label} · written in $written · concert $concert';
}

/// A sung note as the person reading the song sees it: [transpose] semitones
/// from where the recording sang it, spelled in the key that lands in.
///
/// [key] is the song's key before transposing, as for [chordAsPlayed].
///
/// Perform moved its chords into the key you had chosen and left its note
/// names in the recording's, so a singer who dropped the song to fit their
/// voice read the chord over a word in one key and the note under it in
/// another, and Sing along asked them for a pitch the chart no longer had.
/// How you read a song is yours and moves with your transpose; what the
/// recording did is a fact and does not (Every Musician, Same Song, 17
/// September 2026).
String noteAsPlayed(int midi, {required int transpose, String? key}) =>
    noteInKey(midi + transpose, key == null ? null : keyAsPlayed(key, transpose));

/// A note name moved by [semitones], or null when [note] is not a note name
/// at all -- a degree, a quality, anything else after a slash.
///
/// Read from music_reference's one pitch table, so an E# or a Cb moves like
/// any other note.
String? _moveNote(String note, int semitones) {
  final pitch = pitchOf(note);
  if (pitch == null) return null;
  return noteName(pitch + semitones, flats: false);
}

final RegExp _plainSectionPattern = RegExp(
  r'^(?:intro|verse(?:\s+(?:\d+|[ivx]+))?|pre[ -]?chorus(?:\s+\d+)?|chorus(?:\s+\d+)?|post[ -]?chorus(?:\s+\d+)?|refrain|hook|bridge(?:\s+\d+)?|breakdown|instrumental(?:\s+\d+)?|interlude(?:\s+\d+)?|(?:guitar|drum|bass|keys?|piano)?\s*solo(?:\s+\d+)?|outro|tag)(?:\s*[.:_-])?$',
  caseSensitive: false,
);

bool isSheetSection(Contribution line) {
  final body = displayContributionBody(line.body).trim();
  if (line.kind == ContributionKind.section ||
      RegExp(r'^\s*\[[^\]]+\]\s*$').hasMatch(body)) {
    return true;
  }
  final normalized = body
      .replaceAll(RegExp(r'^[\s#>*-]+'), '')
      .replaceAll(RegExp(r'[\s:;._-]+$'), '')
      .trim();
  return _plainSectionPattern.hasMatch(normalized);
}

String cleanSheetSection(String value) => value
    .replaceFirst(RegExp(r'^\s*\['), '')
    .replaceFirst(RegExp(r'\]\s*$'), '')
    .replaceAll(RegExp(r'^[\s#>*-]+'), '')
    .replaceAll(RegExp(r'[\s:;._-]+$'), '')
    .trim();

(int, int) proportionalSheetRange(int index, int count, int durationMs) {
  if (count <= 0 || durationMs <= 0 || index < 0) return (0, 0);
  final pad = (durationMs * 0.035).round();
  final usable = math.max(1, durationMs - pad * 2);
  final start = pad + (usable * index / count).round();
  final end = pad + (usable * (index + 1) / count).round();
  return (start, math.max(start + 120, end).toInt());
}

/// Builds sheet lines straight from a transcript + chord cues, with no
/// SongProject/SongAnalysisBundle involved — the actual "chords positioned
/// above the word they land on" rendering only ever needs these primitives,
/// so both the per-project Song Sheet (via [buildMusicianSheetLines]) and
/// The Studio's pre-project drafts (which have no project to wrap this in)
/// can share the exact same line-building logic instead of duplicating it.
///
/// [downbeatsMs] is optional because not every recording has a beat grid —
/// an older analysis, or one the tracker wasn't confident about. Without it
/// the lines come out exactly as before, just without bar numbers.
List<MusicianSheetLine> transcriptSheetLines({
  required List<TranscriptWord> transcriptWords,
  required String? transcriptText,
  required List<ChordCue> chordCues,
  required int durationMs,
  List<int> downbeatsMs = const <int>[],
}) {
  List<ChordCue> chordsForRange(int startMs, int endMs) => chordCues
      .where((cue) => cue.endMs >= startMs && cue.startMs <= endMs)
      .toList(growable: false);

  final words = transcriptWords;
  if (words.isNotEmpty) {
    // Break lines on natural pauses in the sung timing (a breath, a held
    // note, a bar between phrases) rather than a fixed word count — a fixed
    // count breaks lines mid-phrase whenever the actual phrasing doesn't
    // happen to land on a multiple of it. Mirrors the grouping in
    // SongAnalysisService.transcriptLyricLines, which uses the same
    // pause-gap heuristic for the "Replace project lyrics" action.
    const pauseGapMs = 650;
    const maxWordsPerLine = 12;
    const maxLineDurationMs = 9000;
    final slices = <List<TranscriptWord>>[];
    var current = <TranscriptWord>[];
    for (final word in words) {
      if (current.isNotEmpty) {
        final gap = word.startMs - current.last.endMs;
        final duration = word.endMs - current.first.startMs;
        if (gap >= pauseGapMs ||
            current.length >= maxWordsPerLine ||
            duration >= maxLineDurationMs) {
          slices.add(current);
          current = <TranscriptWord>[];
        }
      }
      current.add(word);
    }
    if (current.isNotEmpty) slices.add(current);

    return slices
        .map((slice) => MusicianSheetLine(
              contributionId: null,
              body: slice.map((word) => word.word).join(' '),
              section: false,
              startMs: slice.first.startMs,
              endMs: slice.last.endMs,
              chords: chordsForRange(slice.first.startMs, slice.last.endMs),
              approximateTiming: false,
              wordStartsMs:
                  slice.map((word) => word.startMs).toList(growable: false),
              bar: barNumberAt(slice.first.startMs, downbeatsMs),
            ))
        .toList(growable: false);
  }
  final text = transcriptText?.trim() ?? '';
  if (text.isEmpty) return _chordOnlyLines(chordCues, downbeatsMs);
  final wordsOnly = text.replaceAll(RegExp(r'\s+'), ' ').split(' ');
  final chunks = <String>[];
  for (var start = 0; start < wordsOnly.length; start += 7) {
    chunks.add(
      wordsOnly
          .sublist(start, math.min(start + 7, wordsOnly.length))
          .join(' '),
    );
  }
  return chunks.asMap().entries.map((entry) {
    final range =
        proportionalSheetRange(entry.key, chunks.length, durationMs);
    return MusicianSheetLine(
      contributionId: null,
      body: entry.value,
      section: false,
      startMs: range.$1,
      endMs: range.$2,
      chords: chordsForRange(range.$1, range.$2),
      approximateTiming: true,
      // Deliberately no bar: these lines are spread evenly across the
      // recording because there was no word timing to place them by. A bar
      // number on a guessed position would read as precision that isn't
      // there.
    );
  }).toList(growable: false);
}

/// The marker an instrumental line puts under each chord in place of a word.
///
/// Named rather than typed twice, because it is not only a layout detail any
/// more: anything carrying the sheet off the phone has to be able to tell a
/// placeholder from a lyric, or it hands somebody a page of dots and calls
/// them words (Every Musician, Same Song, 17 September 2026 — see
/// ChordSheetExport).
const String instrumentalMark = '·';

/// For a genuinely instrumental recording (no sung words at all, so no
/// transcript to build lines from): the chord chart is still worth
/// showing rather than an empty sheet. Chord placement is driven by
/// word position within a line (see chordPlacementsForLine), so this
/// gives each chord a small placeholder marker to sit above instead of a
/// real lyric word — the same visual shape as a chord-only instrumental
/// section on a normal chord chart.
/// With a beat grid, the lines are bars — the chart breaks where the music
/// does instead of every four changes, and each line says which bar it is.
/// Without one it falls back to fixed groups, which is what this always did.
List<MusicianSheetLine> _chordOnlyLines(
  List<ChordCue> chords,
  List<int> downbeatsMs,
) {
  if (chords.isEmpty) return const <MusicianSheetLine>[];
  final bars = groupChordsIntoBars(chords, downbeatsMs);
  if (bars.isNotEmpty) {
    return <MusicianSheetLine>[
      for (final bar in bars)
        MusicianSheetLine(
          contributionId: null,
          body:
              List<String>.filled(bar.chords.length, instrumentalMark).join('   '),
          section: false,
          startMs: bar.startMs,
          endMs: bar.endMs,
          chords: bar.chords,
          approximateTiming: false,
          bar: bar.number,
        ),
    ];
  }
  const chordsPerLine = 4;
  final lines = <MusicianSheetLine>[];
  for (var start = 0; start < chords.length; start += chordsPerLine) {
    final slice = chords.sublist(start, math.min(start + chordsPerLine, chords.length));
    lines.add(
      MusicianSheetLine(
        contributionId: null,
        body: List<String>.filled(slice.length, instrumentalMark).join('   '),
        section: false,
        startMs: slice.first.startMs,
        endMs: slice.last.endMs,
        chords: slice,
        approximateTiming: false,
      ),
    );
  }
  return lines;
}

/// Every chord on a sheet, in the order somebody reads them, with the line
/// and the word each one sits over.
///
/// The keyboard needs this and the sheet does not: on screen a chord is
/// drawn where its line puts it, but "the next chord" is a question about
/// the whole page. Pure, and rebuilt on demand rather than cached, because
/// the bundle changes under it on every correction and a stale order would
/// move the wrong chord.
List<({MusicianSheetLine line, ChordCue chord, int wordIndex})>
    chordsInReadingOrder(List<MusicianSheetLine> lines) {
  final found = <({MusicianSheetLine line, ChordCue chord, int wordIndex})>[];
  for (final line in lines) {
    if (line.section || line.body.trim().isEmpty) continue;
    final words = line.body
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    final placements = chordPlacementsForLine(
      wordCount: words.length,
      lineStartMs: line.startMs,
      lineEndMs: line.endMs,
      chords: line.chords,
      wordStartsMs: line.wordStartsMs,
    );
    // Over the words, not over the map: placements is keyed by word index
    // and holds only the words that have a chord, so its length is a count
    // of chords and walking that misses everything past the last dense one.
    for (var i = 0; i < words.length; i += 1) {
      final cue = placements[i];
      if (cue != null) {
        found.add((line: line, chord: cue, wordIndex: i));
      }
    }
  }
  return found;
}
