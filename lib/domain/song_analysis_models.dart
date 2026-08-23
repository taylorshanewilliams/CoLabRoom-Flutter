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
    this.chordCoverage,
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
  /// Legacy. Held a placeholder averaged into a percentage that read the same
  /// on every song; no longer written. Prefer [chordCoverage].
  final double? chordConfidence;

  /// Fraction of the recording the model actually named a chord over — the
  /// measured answer to "how well did this go".
  final double? chordCoverage;
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
    this.groupIndex = 0,
    this.repeatsSectionLabel,
  });

  final int startMs;
  final int endMs;

  /// The part this stretch is — "A", "B". Every occurrence of the same
  /// musical idea shares a label, so the sequence of labels reads as the
  /// song's form.
  final String label;

  /// Which distinct idea this is, in order of first appearance. Drives
  /// colour so repeats are recognisable at a glance.
  final int groupIndex;

  /// Legacy: analyses written before parts were grouped pointed each repeat
  /// at whichever earlier section it resembled, which had to be traced
  /// backwards to be understood. Kept so old saved analyses still render.
  final String? repeatsSectionLabel;

  int get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start_ms': startMs,
        'end_ms': endMs,
        'label': label,
        'group_index': groupIndex,
        if (repeatsSectionLabel != null) 'repeats_section_label': repeatsSectionLabel,
      };

  factory StructureSection.fromJson(Map<String, dynamic> json) {
    return StructureSection(
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      label: json['label'] as String? ?? '',
      groupIndex: (json['group_index'] as num?)?.toInt() ?? 0,
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

/// Since the separation worker moved to `htdemucs_6s`, [guitar] and [piano]
/// are genuinely separate sources rather than one lumped "other" stem, so
/// the UI can name them honestly. [other] is what's left after all five
/// named sources — synths, strings, horns — and stays deliberately vague.
class InstrumentSummary {
  const InstrumentSummary({
    this.vocals,
    this.guitar,
    this.piano,
    this.bass,
    this.drums,
    this.other,
  });

  final InstrumentPresence? vocals;
  final InstrumentPresence? guitar;
  final InstrumentPresence? piano;
  final InstrumentPresence? bass;
  final InstrumentPresence? drums;
  final InstrumentPresence? other;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (vocals != null) 'vocals': vocals!.toJson(),
        if (guitar != null) 'guitar': guitar!.toJson(),
        if (piano != null) 'piano': piano!.toJson(),
        if (bass != null) 'bass': bass!.toJson(),
        if (drums != null) 'drums': drums!.toJson(),
        if (other != null) 'other': other!.toJson(),
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
      piano: read('piano'),
      bass: read('bass'),
      drums: read('drums'),
      other: read('other'),
    );
  }
}

/// One separated instrument track, kept in Storage after analysis rather
/// than discarded. Playable on its own — isolating the guitar to learn a
/// part is the whole point.
enum StemKind { vocals, drums, bass, guitar, piano, other }

extension StemKindLabel on StemKind {
  String get label {
    switch (this) {
      case StemKind.vocals:
        return 'Vocals';
      case StemKind.drums:
        return 'Drums';
      case StemKind.bass:
        return 'Bass';
      case StemKind.guitar:
        return 'Guitar';
      case StemKind.piano:
        return 'Piano';
      case StemKind.other:
        return 'Other';
    }
  }
}

class SongStem {
  const SongStem({
    required this.projectId,
    required this.kind,
    required this.storagePath,
    this.byteSize,
  });

  final String projectId;
  final StemKind kind;
  final String storagePath;
  final int? byteSize;
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
    this.stems = const <SongStem>[],
  });

  final ReferenceTrack? reference;
  final List<LyricSyncCue> lyricCues;
  final List<ChordCue> chordCues;
  final List<SongStem> stems;

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
    List<SongStem>? stems,
  }) {
    return SongAnalysisBundle(
      reference: reference ?? this.reference,
      lyricCues: lyricCues ?? this.lyricCues,
      chordCues: chordCues ?? this.chordCues,
      stems: stems ?? this.stems,
    );
  }
}
