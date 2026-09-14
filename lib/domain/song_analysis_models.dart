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
    this.beatsMs = const <int>[],
    this.downbeatsMs = const <int>[],
    this.beatsPerBar,
    this.transcriptText,
    this.transcriptWords = const <TranscriptWord>[],
    this.analysisWarning,
    this.lastError,
    this.bpm,
    this.structureSections = const <StructureSection>[],
    this.instruments,
    this.melody,
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

  /// Every beat in the recording, in milliseconds.
  final List<int> beatsMs;

  /// The first beat of each bar. What turns "at 1.847 seconds" into "bar 12",
  /// and the prerequisite for bar lines and a count-in.
  final List<int> downbeatsMs;

  /// Counted from the gaps between downbeats, not assumed to be four. Null
  /// when the recording gave no confident answer.
  final int? beatsPerBar;

  /// How many bars the recording runs to, or null without downbeats.
  int? get barCount => downbeatsMs.isEmpty ? null : downbeatsMs.length;
  final String? transcriptText;
  final List<TranscriptWord> transcriptWords;
  final String? analysisWarning;
  final String? lastError;
  final double? bpm;
  final List<StructureSection> structureSections;
  final InstrumentSummary? instruments;

  /// What was sung, as notes. Null for an instrumental or an analysis from
  /// before the pipeline could hear a tune.
  final Melody? melody;

  bool get hasTranscript => (transcriptText?.trim().isNotEmpty ?? false);
}

/// Note names with sharps, C first, so `midiNoteNames[midi % 12]`.
const List<String> midiNoteNames = <String>[
  'C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B',
];

/// "A4", "F♯3": a MIDI number the way a singer says it (C4 is middle C).
String midiNoteLabel(int midi) => '${midiNoteNames[midi % 12]}${midi ~/ 12 - 1}';

/// One sung note: where it runs, the nearest pitch, and how far from it.
class MelodyNote {
  const MelodyNote({
    required this.startMs,
    required this.endMs,
    required this.midi,
    this.cents = 0,
  });

  factory MelodyNote.fromJson(Map<String, dynamic> json) => MelodyNote(
        startMs: (json['start_ms'] as num).round(),
        endMs: (json['end_ms'] as num).round(),
        midi: (json['midi'] as num).round(),
        cents: (json['cents'] as num?)?.round() ?? 0,
      );

  final int startMs;
  final int endMs;
  final int midi;
  final int cents;

  String get label => midiNoteLabel(midi);
  int get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start_ms': startMs,
        'end_ms': endMs,
        'midi': midi,
        'cents': cents,
      };
}

/// The tune the pipeline heard on the vocal stem.
///
/// The pipeline has separated the vocal, timed every word and named every
/// chord since the first sheet, and never once heard a note. This is the
/// missing sense: what the singer sang, so the app can say what range a song
/// sits in, which note is being sung right now, and -- eventually -- what a
/// harmony *of the tune* would be, rather than of the chord.
class Melody {
  const Melody({
    required this.notes,
    this.lowMidi,
    this.highMidi,
    this.voicedRatio,
  });

  /// Reads the notes and works the range out from them, trusting the
  /// worker's own low/high only when there are no notes to work from.
  ///
  /// The app decides, not the worker, because the app is what writes the
  /// range to the profile -- and a recording analysed by an older worker
  /// (min and max, C2 – C6) should read the same as one analysed today
  /// without being paid for again.
  factory Melody.fromJson(Map<String, dynamic> json) {
    final notes = (json['notes'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => MelodyNote.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList(growable: false);
    final range = notes.isEmpty ? null : sungRange(notes);
    return Melody(
      notes: notes,
      lowMidi: range?.$1 ?? (json['low_midi'] as num?)?.round(),
      highMidi: range?.$2 ?? (json['high_midi'] as num?)?.round(),
      voicedRatio: (json['voiced_ratio'] as num?)?.toDouble(),
    );
  }

  /// A note shorter than this is where a pitch tracker is likeliest to be an
  /// octave out, and it is left out of the range.
  static const int steadyNoteMs = 120;

  /// The share of sung time trimmed from each end of the range.
  static const double rangeTrim = 0.05;

  /// The lowest and highest notes that were actually sung, as the singer
  /// would give them -- the same rule as `sung_range` in melody.py.
  ///
  /// Not the minimum and maximum. The first real song through the pipeline
  /// came back as C2 – C6, four octaves, because a tracker over a separated
  /// vocal is wrong somewhere in every song: an octave low on a breathy
  /// onset, an octave high on a consonant, a guitar bleed that lasted. Each
  /// is a sliver of the sung time, and a range is a claim about where the
  /// voice *lives*, so the notes are sorted by pitch and the lowest and
  /// highest 5 % of sung milliseconds are left out. A note held for a fifth
  /// of the song stays in, however low; a flicker never widens anything.
  static (int, int)? sungRange(List<MelodyNote> notes) {
    var steady = notes.where((n) => n.durationMs >= steadyNoteMs).toList();
    if (steady.isEmpty) steady = notes.toList();
    if (steady.isEmpty) return null;
    steady.sort((a, b) => a.midi.compareTo(b.midi));
    final total = steady.fold<int>(0, (sum, n) => sum + n.durationMs);
    if (total <= 0) return (steady.first.midi, steady.last.midi);
    int? low;
    var high = steady.last.midi;
    var seen = 0;
    for (final note in steady) {
      seen += note.durationMs;
      if (low == null && seen >= total * rangeTrim) low = note.midi;
      if (seen >= total * (1 - rangeTrim)) {
        high = note.midi;
        break;
      }
    }
    return (low ?? steady.first.midi, high);
  }

  final List<MelodyNote> notes;

  /// Where the voice lives: the lowest and highest notes that were really
  /// sung (see [sungRange]), or null when nothing was.
  final int? lowMidi;
  final int? highMidi;

  /// How much of the stem was sung at all, 0..1.
  final double? voicedRatio;

  bool get isEmpty => notes.isEmpty;

  /// "E3 – A4", or null when there is no range to speak of.
  String? get rangeLabel {
    final low = lowMidi;
    final high = highMidi;
    if (low == null || high == null) return null;
    return low == high ? midiNoteLabel(low) : '${midiNoteLabel(low)} – ${midiNoteLabel(high)}';
  }

  /// The note sounding at [elapsedMs], or null between notes.
  MelodyNote? noteAt(int elapsedMs) {
    for (final note in notes) {
      if (note.startMs > elapsedMs) return null;
      if (elapsedMs < note.endMs) return note;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'notes': notes.map((note) => note.toJson()).toList(growable: false),
        'low_midi': lowMidi,
        'high_midi': highMidi,
        'voiced_ratio': voicedRatio,
      };
}

/// One named part of the song — "Verse", "Chorus", "Bridge" — and where it
/// runs.
///
/// The names are real now. They come from a model trained on around 900 pop
/// songs that people annotated by hand (see handler.py's _detect_structure),
/// which is the only way anything can name a chorus: nothing in the audio
/// itself says which repeated idea is the chorus and which is the verse.
/// Earlier analyses lettered their sections "A", "B", "C" instead, and those
/// still load and render — the label is just a string.
///
/// It is a good guess rather than a fact, and the UI says so where it's
/// shown. [repeatsSectionLabel] is a legacy hint from the lettered era.
class StructureSection {
  const StructureSection({
    required this.startMs,
    required this.endMs,
    required this.label,
    this.groupIndex = 0,
    this.repeatsSectionLabel,
    this.customLabel,
  });

  final int startMs;
  final int endMs;

  /// What this part is called — "Intro", "Verse", "Chorus". Every occurrence
  /// of the same part shares a label, so the sequence reads as the song's
  /// form. Older analyses carry a letter here instead.
  final String label;

  /// [label] shortened to fit inside a narrow block on the timeline, where a
  /// four-minute song's intro is a few millimetres wide and "Instrumental"
  /// scaled down to fit is a grey smudge. Two letters keep a shape you can
  /// recognise; the full word is still right there in the form and the key
  /// below it.
  String get shortLabel {
    final label = displayLabel;
    if (label.length <= 2) return label;
    switch (label) {
      case 'Intro':
        return 'In';
      case 'Verse':
        return 'V';
      case 'Chorus':
        return 'Ch';
      case 'Bridge':
        return 'Br';
      case 'Instrumental':
        return 'Inst';
      case 'Solo':
        return 'Solo';
      case 'Break':
        return 'Bk';
      case 'Outro':
        return 'Out';
    }
    return label.substring(0, 2);
  }

  /// Which distinct idea this is, in order of first appearance. Drives
  /// colour so repeats are recognisable at a glance.
  final int groupIndex;

  /// Legacy: analyses written before parts were grouped pointed each repeat
  /// at whichever earlier section it resembled, which had to be traced
  /// backwards to be understood. Kept so old saved analyses still render.
  final String? repeatsSectionLabel;

  /// What the band calls this part, when they've said.
  ///
  /// The model's word is "Chorus". Yours might be "the big one", or "Kate's
  /// bit", or "Verse 2 (fast)". Kept beside the model's label rather than
  /// overwriting it, so re-analysis can hand the name back to the part it
  /// belongs to — see carryCustomSectionNames.
  final String? customLabel;

  /// What to show. A name someone chose beats a name a model guessed.
  String get displayLabel => (customLabel?.trim().isNotEmpty ?? false) ? customLabel!.trim() : label;

  bool get isRenamed => customLabel?.trim().isNotEmpty ?? false;

  int get durationMs => endMs - startMs;

  StructureSection copyWith({String? customLabel, bool clearCustomLabel = false}) {
    return StructureSection(
      startMs: startMs,
      endMs: endMs,
      label: label,
      groupIndex: groupIndex,
      repeatsSectionLabel: repeatsSectionLabel,
      customLabel: clearCustomLabel ? null : (customLabel ?? this.customLabel),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start_ms': startMs,
        'end_ms': endMs,
        'label': label,
        'group_index': groupIndex,
        if (repeatsSectionLabel != null) 'repeats_section_label': repeatsSectionLabel,
        if (customLabel != null) 'custom_label': customLabel,
      };

  factory StructureSection.fromJson(Map<String, dynamic> json) {
    return StructureSection(
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      label: json['label'] as String? ?? '',
      groupIndex: (json['group_index'] as num?)?.toInt() ?? 0,
      repeatsSectionLabel: json['repeats_section_label'] as String?,
      customLabel: json['custom_label'] as String?,
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
