import 'song_analysis_models.dart';

/// A pre-project recording uploaded to The Studio — mirrors [ReferenceTrack]'s
/// shape, but has no [SongProject] behind it yet (no projectId; account-scoped
/// instead). Once promoted, its analysis is copied into a real
/// project_audio_references row and this draft's [promotedProjectId] is set.
class StudioDraft {
  const StudioDraft({
    required this.id,
    required this.accountId,
    required this.displayName,
    required this.storagePath,
    required this.state,
    required this.createdAt,
    this.mimeType,
    this.byteSize,
    this.durationMs,
    this.bpm,
    this.musicalKey,
    this.analyzerVersion,
    this.chordConfidence,
    this.transcriptText,
    this.transcriptWords = const <TranscriptWord>[],
    this.structureSections = const <StructureSection>[],
    this.instruments,
    this.analysisWarning,
    this.lastError,
    this.promotedProjectId,
  });

  final String id;
  final String accountId;
  final String displayName;
  final String storagePath;
  final SongAnalysisState state;
  final DateTime createdAt;
  final String? mimeType;
  final int? byteSize;
  final int? durationMs;
  final double? bpm;
  final String? musicalKey;
  final String? analyzerVersion;
  final double? chordConfidence;
  final String? transcriptText;
  final List<TranscriptWord> transcriptWords;
  final List<StructureSection> structureSections;
  final InstrumentSummary? instruments;
  final String? analysisWarning;
  final String? lastError;
  final String? promotedProjectId;

  bool get hasTranscript => (transcriptText?.trim().isNotEmpty ?? false);
  bool get isPromoted => promotedProjectId != null;
}

class StudioDraftBundle {
  const StudioDraftBundle({required this.draft, required this.chordCues});

  final StudioDraft draft;

  /// Reuses [ChordCue] as-is — it carries no projectId field, scoping happens
  /// purely at the query layer (studio_chord_cues.draft_id vs chord_cues.project_id).
  final List<ChordCue> chordCues;

  bool get ready {
    if (draft.state != SongAnalysisState.ready) return false;
    return chordCues.isNotEmpty || draft.hasTranscript;
  }
}
