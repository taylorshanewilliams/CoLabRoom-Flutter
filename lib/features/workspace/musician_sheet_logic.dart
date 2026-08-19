import 'dart:math' as math;

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';

class MusicianSheetLine {
  const MusicianSheetLine({
    required this.contributionId,
    required this.body,
    required this.section,
    required this.startMs,
    required this.endMs,
    required this.chords,
    required this.approximateTiming,
  });

  final String? contributionId;
  final String body;
  final bool section;
  final int startMs;
  final int endMs;
  final List<ChordCue> chords;
  final bool approximateTiming;
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
  if (ignoreWorkspaceLyrics) return _transcriptLines(bundle, duration);

  final contributions = project.contributions
      .where((line) =>
          line.kind != ContributionKind.note &&
          displayContributionBody(line.body).trim().isNotEmpty)
      .toList(growable: false);
  final lyrics = visibleMusicianLyrics(project);
  if (lyrics.isEmpty) return _transcriptLines(bundle, duration);

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
    );
  }).toList(growable: false);
}

Map<int, ChordCue> chordPlacementsForLine({
  required int wordCount,
  required int lineStartMs,
  required int lineEndMs,
  required List<ChordCue> chords,
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
  final span = math.max(1, lineEndMs - lineStartMs);
  final placements = <int, ChordCue>{};
  for (final chord in unique) {
    final ratio =
        ((chord.startMs - lineStartMs) / span).clamp(0.0, 0.999);
    var index =
        (ratio * wordCount).floor().clamp(0, wordCount - 1).toInt();
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

String transposeChord(String chord, int semitones) {
  if (semitones % 12 == 0) return chord;
  final match = RegExp(r'^([A-G])([#b]?)(.*)$').firstMatch(chord.trim());
  if (match == null) return chord;
  const names = <String>[
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];
  const pitch = <String, int>{
    'C': 0,
    'C#': 1,
    'Db': 1,
    'D': 2,
    'D#': 3,
    'Eb': 3,
    'E': 4,
    'F': 5,
    'F#': 6,
    'Gb': 6,
    'G': 7,
    'G#': 8,
    'Ab': 8,
    'A': 9,
    'A#': 10,
    'Bb': 10,
    'B': 11,
  };
  final root = '${match.group(1)}${match.group(2)}';
  final value = pitch[root];
  if (value == null) return chord;
  final normalized = ((value + semitones) % 12 + 12) % 12;
  return '${names[normalized]}${match.group(3) ?? ''}';
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

List<MusicianSheetLine> _transcriptLines(
  SongAnalysisBundle bundle,
  int durationMs,
) {
  final words =
      bundle.reference?.transcriptWords ?? const <TranscriptWord>[];
  if (words.isNotEmpty) {
    final lines = <MusicianSheetLine>[];
    for (var start = 0; start < words.length; start += 7) {
      final slice =
          words.sublist(start, math.min(start + 7, words.length));
      lines.add(
        MusicianSheetLine(
          contributionId: null,
          body: slice.map((word) => word.word).join(' '),
          section: false,
          startMs: slice.first.startMs,
          endMs: slice.last.endMs,
          chords:
              bundle.chordsForRange(slice.first.startMs, slice.last.endMs),
          approximateTiming: false,
        ),
      );
    }
    return lines;
  }
  final text = bundle.reference?.transcriptText?.trim() ?? '';
  if (text.isEmpty) return _chordOnlyLines(bundle);
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
      chords: bundle.chordsForRange(range.$1, range.$2),
      approximateTiming: true,
    );
  }).toList(growable: false);
}

/// For a genuinely instrumental recording (no sung words at all, so no
/// transcript to build lines from): the chord chart is still worth
/// showing rather than an empty sheet. Chord placement is driven by
/// word position within a line (see chordPlacementsForLine), so this
/// gives each chord a small placeholder marker to sit above instead of a
/// real lyric word — the same visual shape as a chord-only instrumental
/// section on a normal chord chart.
List<MusicianSheetLine> _chordOnlyLines(SongAnalysisBundle bundle) {
  final chords = bundle.chordCues;
  if (chords.isEmpty) return const <MusicianSheetLine>[];
  const chordsPerLine = 4;
  final lines = <MusicianSheetLine>[];
  for (var start = 0; start < chords.length; start += chordsPerLine) {
    final slice = chords.sublist(start, math.min(start + chordsPerLine, chords.length));
    lines.add(
      MusicianSheetLine(
        contributionId: null,
        body: List<String>.filled(slice.length, '·').join('   '),
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
