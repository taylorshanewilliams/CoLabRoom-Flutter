enum SongAnalysisState { uploaded, queued, processing, ready, failed }

class TranscriptWord {
  const TranscriptWord({
    required this.word,
    required this.startMs,
    required this.endMs,
  });

  final String word;
  final int startMs;
  final int endMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'word': word,
        'start_ms': startMs,
        'end_ms': endMs,
      };

  factory TranscriptWord.fromJson(Map<String, dynamic> json) {
    return TranscriptWord(
      word: json['word'] as String? ?? '',
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class ReferenceTrack {
  const ReferenceTrack({
    required this.projectId,
    required this.fileId,
    required this.storagePath,
    required this.displayName,
    required this.state,
    this.durationMs,
    this.musicalKey,
    this.lyricConfidence,
    this.chordConfidence,
    this.transcriptText,
    this.transcriptWords = const <TranscriptWord>[],
    this.analysisWarning,
    this.lastError,
    this.bpm,
    this.structureSections = const <StructureSection>[],
    this.instruments,
  });

  final String projectId;
  final String fileId;
  final String storagePath;
  final String displayName;
  final SongAnalysisState state;
  final int? durationMs;
  final String? musicalKey;
  final double? lyricConfidence;
  final double? chordConfidence;
  final String? transcriptText;
  final List<TranscriptWord> transcriptWords;
  final String? analysisWarning;
  final String? lastError;
  final double? bpm;
  final List<StructureSection> structureSections;
  final InstrumentSummary? instruments;

  bool get hasTranscript => (transcriptText?.trim().isNotEmpty ?? false);
}

/// A suggested song-structure boundary (e.g. "where the chorus probably
/// starts") — [label] is always a generic placeholder ("Section A", "Section
/// B", ...), never asserted as Verse/Chorus/Bridge. The musician relabels
/// sections themselves; this only claims to know where the music changes,
/// not what to call the result. [repeatsSectionLabel] is a soft hint (this
/// section's chroma closely matches an earlier one) worth surfacing as
/// "repeats Section B" but not treated as certain.
class StructureSection {
  const StructureSection({
    required this.startMs,
    required this.endMs,
    required this.label,
    this.repeatsSectionLabel,
  });

  final int startMs;
  final int endMs;
  final String label;
  final String? repeatsSectionLabel;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start_ms': startMs,
        'end_ms': endMs,
        'label': label,
        if (repeatsSectionLabel != null) 'repeats_section_label': repeatsSectionLabel,
      };

  factory StructureSection.fromJson(Map<String, dynamic> json) {
    return StructureSection(
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      label: json['label'] as String? ?? '',
      repeatsSectionLabel: json['repeats_section_label'] as String?,
    );
  }
}

/// Energy-presence, not real instrument recognition — [confidence] is a
/// normalized ratio of stem RMS energy against a silence floor, not a
/// classifier score.
class InstrumentPresence {
  const InstrumentPresence({required this.present, required this.confidence});

  final bool present;
  final double confidence;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'present': present, 'confidence': confidence};

  factory InstrumentPresence.fromJson(Map<String, dynamic> json) {
    return InstrumentPresence(
      present: json['present'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// [guitar] actually covers Demucs' "other" stem — guitar, keys, and synths
/// are indistinguishable at this stage, so the UI should label it something
/// like "Guitar/Keys" rather than claim guitar specifically was detected.
class InstrumentSummary {
  const InstrumentSummary({this.vocals, this.guitar, this.bass, this.drums});

  final InstrumentPresence? vocals;
  final InstrumentPresence? guitar;
  final InstrumentPresence? bass;
  final InstrumentPresence? drums;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (vocals != null) 'vocals': vocals!.toJson(),
        if (guitar != null) 'guitar': guitar!.toJson(),
        if (bass != null) 'bass': bass!.toJson(),
        if (drums != null) 'drums': drums!.toJson(),
      };

  factory InstrumentSummary.fromJson(Map<String, dynamic> json) {
    InstrumentPresence? read(String key) {
      final value = json[key];
      return value is Map<String, dynamic>
          ? InstrumentPresence.fromJson(value)
          : null;
    }

    return InstrumentSummary(
      vocals: read('vocals'),
      guitar: read('guitar'),
      bass: read('bass'),
      drums: read('drums'),
    );
  }
}

class LyricSyncCue {
  const LyricSyncCue({
    required this.contributionId,
    required this.startMs,
    required this.endMs,
    required this.confidence,
    this.source = 'automatic',
  });

  final String contributionId;
  final int startMs;
  final int endMs;
  final double confidence;
  final String source;

  bool get isManual => source == 'manual' || source == 'reviewed';

  LyricSyncCue copyWith({
    String? contributionId,
    int? startMs,
    int? endMs,
    double? confidence,
    String? source,
  }) {
    return LyricSyncCue(
      contributionId: contributionId ?? this.contributionId,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
    );
  }
}

class ChordCue {
  const ChordCue({
    required this.startMs,
    required this.endMs,
    required this.chord,
    required this.confidence,
    this.id,
    this.source = 'automatic',
  });

  final int? id;
  final int startMs;
  final int endMs;
  final String chord;
  final double confidence;
  final String source;

  bool get isManual => source == 'manual' || source == 'reviewed';

  ChordCue copyWith({
    int? id,
    int? startMs,
    int? endMs,
    String? chord,
    double? confidence,
    String? source,
  }) {
    return ChordCue(
      id: id ?? this.id,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      chord: chord ?? this.chord,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
    );
  }
}

class SongAnalysisBundle {
  const SongAnalysisBundle({
    required this.reference,
    required this.lyricCues,
    required this.chordCues,
  });

  final ReferenceTrack? reference;
  final List<LyricSyncCue> lyricCues;
  final List<ChordCue> chordCues;

  bool get ready {
    final track = reference;
    if (track?.state != SongAnalysisState.ready) return false;
    return lyricCues.isNotEmpty ||
        chordCues.isNotEmpty ||
        (track?.hasTranscript ?? false);
  }

  bool get hasSyncedLyrics => lyricCues.isNotEmpty;

  LyricSyncCue? cueForContribution(String contributionId) {
    for (final cue in lyricCues) {
      if (cue.contributionId == contributionId) return cue;
    }
    return null;
  }

  List<ChordCue> chordsForRange(int startMs, int endMs) => chordCues
      .where((cue) => cue.endMs >= startMs && cue.startMs <= endMs)
      .toList(growable: false);

  SongAnalysisBundle copyWith({
    ReferenceTrack? reference,
    List<LyricSyncCue>? lyricCues,
    List<ChordCue>? chordCues,
  }) {
    return SongAnalysisBundle(
      reference: reference ?? this.reference,
      lyricCues: lyricCues ?? this.lyricCues,
      chordCues: chordCues ?? this.chordCues,
    );
  }
}
