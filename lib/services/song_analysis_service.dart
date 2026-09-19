import 'dart:async';
import 'dart:io';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/music_models.dart';
import '../domain/song_analysis_models.dart';
import 'audio_analysis_utils.dart';
import 'chord_beat_grid.dart';
import 'chord_repeats.dart';
import 'error_reporter.dart';
import 'kept_songs.dart';
import 'song_language.dart';

export 'audio_analysis_utils.dart' show SongAnalysisProgress;

/// Millisecond timestamps out of a jsonb column, tolerating the doubles
/// Postgres may hand back for a numeric array.
List<int> _msList(dynamic value) {
  if (value is! List) return const <int>[];
  return value
      .whereType<num>()
      .map((n) => n.round())
      .toList(growable: false);
}

/// What fraction of the recording the model actually named a chord over.
///
/// The honest answer to "how well did this go". ChordMini reports labels
/// without confidence, so the pipeline used to stamp a constant on every cue
/// and average it — a number that read the same on every song. Coverage is
/// measured: stretches ChordMini marks "N" (no chord) don't count, so a
/// recording it mostly couldn't parse reports low, which is the point.
double chordCoverage(List<ChordCue> cues, int durationMs) {
  if (durationMs <= 0 || cues.isEmpty) return 0;
  var covered = 0;
  for (final cue in cues) {
    if (cue.chord.isEmpty || cue.chord == 'N') continue;
    final start = cue.startMs.clamp(0, durationMs);
    final end = cue.endMs.clamp(0, durationMs);
    if (end > start) covered += end - start;
  }
  return (covered / durationMs).clamp(0.0, 1.0);
}

/// Whisper accepts roughly 224 tokens of prompt; past that it's discarded.
/// 800 characters stays comfortably inside that with room for the framing
/// sentence the Edge Function prepends.
const int maxLyricsPromptChars = 800;

/// The song's own typed lyrics, as a hint for transcription.
///
/// Whisper decodes ambiguous audio toward words it has been primed with, and
/// the words a writer has already typed are the best possible prior for what
/// they sang. On a live recording — room reverb, crowd, an off-mic vocal —
/// this matters far more than any model change.
///
/// Returns null when the song has no typed lyrics, so the caller falls back
/// to the neutral prompt rather than sending an empty one. Sections and
/// notes are excluded: "[Chorus]" and a reminder to fix the bridge are not
/// things anyone sang.
String? lyricsPromptFor(SongProject project) {
  final lines = project.contributions
      .where((line) => line.kind == ContributionKind.lyric)
      .map((line) => line.body.trim())
      .where((body) => body.isNotEmpty);
  if (lines.isEmpty) return null;
  final text = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return text.length <= maxLyricsPromptChars ? text : text.substring(0, maxLyricsPromptChars);
}

/// What the `transcribe-audio` function is asked for: which recording, the
/// song's own words as a prior, and what the room said it is sung in.
///
/// A function of the song rather than three arguments assembled at each call
/// site, so there is one answer to "what does the transcriber get told about
/// this song" and both callers — the analysis pass and listening again —
/// cannot drift apart. It is also the only part of this worth a test: what
/// happens after it is a network call.
///
/// The language is left out entirely on a song nobody has answered for
/// (0163), which is what every song was before this: the transcriber then
/// decides the language itself, exactly as it always did.
Map<String, dynamic> transcribeRequest(
  SongProject project,
  String storagePath,
) {
  final hint = lyricsPromptFor(project);
  final language = languageTagTyped(project.language);
  return <String, dynamic>{
    'storagePath': storagePath,
    'bucket': 'room-files',
    if (hint != null) 'lyricsHint': hint,
    if (language != null) 'language': language,
  };
}

/// How long to keep waiting on separation before calling it.
///
/// Ten minutes. It was six, which covered a cold GPU worker plus a long take —
/// but the structure model runs a second source-separation pass of its own to
/// name the sections, so the job is now roughly twice the work. Past this
/// something is genuinely wrong, and saying so beats spinning forever.
const Duration separationTimeout = Duration(minutes: 10);

/// How long to wait before asking again.
///
/// Not a flat four seconds. At ten minutes that was 150 network round trips,
/// most of them during a stretch where the answer certainly hadn't changed —
/// and on a phone with its screen off, each one wakes the radio. That pattern
/// is what Android's battery monitor flags, and it was right to.
///
/// Quick at the start because a cached analysis or a warm worker really can
/// come back in seconds, then easing off once it's clear this is a long one.
/// Same ceiling, roughly a third of the wakeups.
Duration separationPollDelay(int attempt) {
  if (attempt < 10) return const Duration(seconds: 4);
  if (attempt < 25) return const Duration(seconds: 8);
  return const Duration(seconds: 15);
}

/// How many polls in a row may fail before the analysis gives up.
///
/// A phone whose screen has been off loses DNS the moment it dozes, which
/// surfaces as `SocketException: Failed host lookup` mid-job. One of those
/// used to end a multi-minute analysis. They come back the instant anything
/// wakes the radio, so the only correct response is to ask again.
const int separationMaxConsecutiveFailures = 8;

/// Progress while waiting on separation, spanning 0.15–0.50 so the bar keeps
/// moving through the longest part of the job. The wording changes once the
/// wait stops being typical, because a spinner that says the same thing for
/// four minutes reads as broken even when it isn't.
SongAnalysisProgress separationProgress(Duration elapsed) {
  final fraction = elapsed.inMilliseconds / separationTimeout.inMilliseconds;
  final label = elapsed < const Duration(seconds: 45)
      ? 'Separating the instruments'
      : elapsed < const Duration(minutes: 2)
          ? 'Still separating — waking up the GPU'
          : 'Still going. Long takes can take a few minutes';
  return SongAnalysisProgress(label, 0.15 + (0.35 * fraction.clamp(0, 1)));
}

/// The app stopped waiting; the job did not stop running.
///
/// Distinct from every other failure because it isn't one. The separation is
/// still on a GPU somewhere, the recording is untouched, and the job id is
/// still recorded — so the analysis must stay `processing` rather than being
/// marked failed, and the breadcrumb must survive so reopening the song
/// rejoins the job instead of paying for it again.
class AnalysisStillRunning implements Exception {
  const AnalysisStillRunning(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Is this the network being unavailable, rather than the service saying no?
///
/// The distinction decides whether an analysis retries or gives up, and — more
/// importantly — whether it falls back to the on-device chord detector. That
/// fallback exists for a pipeline outage. Handing it a dropped connection
/// instead means a phone that dozed for ten seconds quietly replaces a real
/// analysis with a much worse one, which is exactly what happened.
bool isConnectivityFailure(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  // http's ClientException and Supabase's own wrappers don't share a base
  // class worth catching, and their messages are the only thing they have in
  // common. Narrow deliberately: these are transport phrases, not the words a
  // working server uses to refuse a request.
  final text = error.toString().toLowerCase();
  return text.contains('failed host lookup') ||
      text.contains('no address associated with hostname') ||
      text.contains('connection closed') ||
      text.contains('connection refused') ||
      text.contains('connection reset') ||
      text.contains('network is unreachable') ||
      text.contains('software caused connection abort');
}

/// Hands the band's own section names back to the parts they belong to after
/// a re-analysis.
///
/// Names are matched on the model's label, not on position or timing. Rename
/// "Chorus" to "the big one" and *every* chorus becomes the big one — which
/// is right, because you renamed the part, not the third minute of the song.
/// It also survives the boundaries moving, a section being found that wasn't
/// before, or the count changing entirely, none of which a time-based match
/// would.
///
/// The cost of that choice: if the model decides on a later run that what it
/// used to call a Verse is a Chorus, your name follows the word rather than
/// the music. That's rare, it's visible, and it's undoable — where a silent
/// mismatch from time-matching would be none of those things.
List<StructureSection> carryCustomSectionNames(
  List<StructureSection> previous,
  List<StructureSection> next,
) {
  if (previous.isEmpty || next.isEmpty) return next;
  final namesByLabel = <String, String>{};
  for (final section in previous) {
    if (section.isRenamed) namesByLabel[section.label] = section.customLabel!.trim();
  }
  if (namesByLabel.isEmpty) return next;
  return <StructureSection>[
    for (final section in next)
      namesByLabel.containsKey(section.label)
          ? section.copyWith(customLabel: namesByLabel[section.label])
          : section,
  ];
}

/// Shown in place of separation progress when the Edge Function recognizes
/// the recording and hands back an analysis it already had (see migration
/// 0024). There is no GPU job to wait on, so the bar lands where separation
/// would have finished rather than animating through work that isn't
/// happening.
const SongAnalysisProgress reusedAnalysisProgress =
    SongAnalysisProgress('Heard this one before — reusing its analysis', 0.5);

/// Splits timed transcript words into lines, breaking on a real pause rather
/// than a fixed word count so the lines land where the singer breathed.
///
/// Top-level rather than a method because it needs nothing from the service
/// — and because [SongAnalysisService] resolves a Supabase client in its
/// constructor, which makes the class impossible to instantiate in a unit
/// test. Pure logic shouldn't be locked behind that.
List<List<TranscriptWord>> groupTranscriptWordsIntoLines(List<TranscriptWord> words) {
  if (words.isEmpty) return const <List<TranscriptWord>>[];
  const pauseGapMs = 650;
  const maxWordsPerLine = 12;
  const maxLineDurationMs = 9000;
  final lines = <List<TranscriptWord>>[];
  var current = <TranscriptWord>[];
  for (final word in words) {
    if (current.isNotEmpty) {
      final gap = word.startMs - current.last.endMs;
      final duration = word.endMs - current.first.startMs;
      if (gap >= pauseGapMs || current.length >= maxWordsPerLine || duration >= maxLineDurationMs) {
        lines.add(current);
        current = <TranscriptWord>[];
      }
    }
    current.add(word);
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}

/// What Perform opens with when it asks for a song's sheet.
///
/// Three honest answers. The sheet as the server has it; the copy kept on
/// this phone, when the server did not answer; or neither, with the sentence
/// Perform says about it, because a screen that opens words-only without a
/// word about why looks like a song that has no recording (Every Musician,
/// Same Song, 17 September 2026).
class PerformSheet {
  const PerformSheet({this.bundle, this.fromThisPhone = false, this.missing});

  final SongAnalysisBundle? bundle;

  /// True when the network did not answer and this is the copy kept here.
  final bool fromThisPhone;

  /// What Perform says when there is no sheet to be had, or null.
  final String? missing;
}

class SongAnalysisService {
  SongAnalysisService({SupabaseClient? client, ErrorReporter? reporter, KeptSongs? kept})
      : _clientOverride = client,
        _reporter = reporter ?? ErrorReporter(client: client),
        kept = kept ?? KeptSongs();

  final SupabaseClient? _clientOverride;
  final ErrorReporter _reporter;

  /// The songs kept on this phone. The audio loaders below ask it before
  /// they ask anything else, which is how Perform plays without signal.
  final KeptSongs kept;

  /// How long the server is given to answer for a song that is kept here.
  ///
  /// No signal fails at once. One bar in a basement does not: the request
  /// hangs until something gives up on it, which can be most of a minute,
  /// with a singer looking at a spinner and the song sitting on the phone
  /// the whole time. A song that is not kept has nothing else to open with,
  /// so it waits for the server exactly as long as it always did.
  static const Duration keptAnswersAfter = Duration(seconds: 3);

  /// The sheet for Perform: the server's when it answers, this phone's copy
  /// when it does not, and otherwise a sentence about what is missing.
  ///
  /// The phone is asked first, because whether there is a copy here decides
  /// how long the server is worth waiting for. A kept song follows the
  /// server while the server answers, so what plays in the basement tonight
  /// is the sheet as it was corrected this morning.
  Future<PerformSheet> sheetForPerform(SongProject project) async {
    final here = await kept.load(project.id);
    try {
      final asked = load(project.id);
      final bundle = await (here == null ? asked : asked.timeout(keptAnswersAfter));
      if (here != null) unawaited(kept.refresh(project, bundle));
      return PerformSheet(bundle: bundle);
    } catch (error) {
      if (here != null) return PerformSheet(bundle: here.sheet, fromThisPhone: true);
      return PerformSheet(
        missing: isConnectivityFailure(error)
            ? KeptSongs.notKeptOffline
            : KeptSongs.sheetNotLoaded,
      );
    }
  }

  /// Just the counting for several songs at once: what each one's passages
  /// are named from, and nothing else.
  ///
  /// Home has the songs but not their grids, so a practice card could only
  /// repeat the words the mark was kept under, and those go stale the moment
  /// somebody says where bar 1 is (#385's known limit). This is the cheapest
  /// honest way to fix that: four columns of one row per song, in one
  /// request, rather than [load]'s four round trips a song for a transcript,
  /// a melody and every chord cue that no card will ever draw.
  ///
  /// A song kept on this phone answers from the phone, so the cards read
  /// right in the van as well. Songs with no row, or a request that fails,
  /// are simply absent: a card with no grid behind it keeps its own words
  /// rather than guessing at new ones.
  Future<Map<String, SongGrid>> gridsFor(Iterable<String> projectIds) async {
    final wanted = projectIds.toSet();
    if (wanted.isEmpty) return const <String, SongGrid>{};
    final grids = <String, SongGrid>{};
    try {
      final rows = await client
          .from('project_audio_references')
          .select('project_id, beats_ms, downbeats_ms, structure_sections')
          .inFilter('project_id', wanted.toList(growable: false));
      for (final value in rows as List<dynamic>) {
        final row = Map<String, dynamic>.from(value as Map);
        final id = row['project_id'] as String?;
        if (id == null) continue;
        grids[id] = SongGrid(
          beatsMs: _msList(row['beats_ms']),
          downbeatsMs: _msList(row['downbeats_ms']),
          sections: (row['structure_sections'] as List<dynamic>? ??
                  const <dynamic>[])
              .map((section) =>
                  StructureSection.fromJson(Map<String, dynamic>.from(section as Map)))
              .toList(growable: false),
        );
      }
    } catch (_) {
      // Left to the phone's own copies below. A card that could not be
      // renamed says what it always said, which is never a reason to put an
      // error in front of somebody looking at their own songs.
    }
    for (final id in wanted) {
      if (grids.containsKey(id)) continue;
      try {
        final here = await kept.load(id);
        final reference = here?.sheet.reference;
        if (reference != null) grids[id] = reference.grid;
      } catch (_) {
        // Nothing kept for this one, or nothing readable. Same bargain.
      }
    }
    return grids;
  }

  /// Resolved on use rather than at construction, so building this service
  /// somewhere Supabase isn't initialized (previews, widget tests) doesn't
  /// throw before a single call has been made.
  SupabaseClient get client => _clientOverride ?? Supabase.instance.client;

  Future<SongAnalysisBundle> load(String projectId) async {
    final refs = await client
        .from('project_audio_references')
        .select()
        .eq('project_id', projectId)
        .limit(1);
    ReferenceTrack? reference;
    if ((refs as List<dynamic>).isNotEmpty) {
      final row = Map<String, dynamic>.from(refs.first as Map);
      final fileRow = await client
          .from('files')
          .select('id, storage_path, display_name')
          .eq('id', row['file_id'] as String)
          .single();
      reference = ReferenceTrack(
        projectId: projectId,
        fileId: row['file_id'] as String,
        storagePath: fileRow['storage_path'] as String,
        displayName: fileRow['display_name'] as String? ?? 'Reference track',
        state: SongAnalysisState.values.byName(
          row['analysis_state'] as String? ?? SongAnalysisState.uploaded.name,
        ),
        durationMs: row['duration_ms'] as int?,
        musicalKey: row['musical_key'] as String?,
        lyricConfidence: (row['lyric_confidence'] as num?)?.toDouble(),
        chordConfidence: (row['chord_confidence'] as num?)?.toDouble(),
        chordCoverage: (row['chord_coverage'] as num?)?.toDouble(),
        beatsMs: _msList(row['beats_ms']),
        downbeatsMs: _msList(row['downbeats_ms']),
        beatsPerBar: (row['beats_per_bar'] as num?)?.toInt(),
        transcriptText: row['transcript_text'] as String?,
        transcriptWords: (row['transcript_words'] as List<dynamic>? ?? const <dynamic>[])
            .map((value) => TranscriptWord.fromJson(Map<String, dynamic>.from(value as Map)))
            .toList(growable: false),
        analysisWarning: row['analysis_warning'] as String?,
        lastError: row['last_error'] as String?,
        bpm: (row['bpm'] as num?)?.toDouble(),
        structureSections: (row['structure_sections'] as List<dynamic>? ?? const <dynamic>[])
            .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
            .toList(growable: false),
        instruments: row['instruments'] is Map
            ? InstrumentSummary.fromJson(Map<String, dynamic>.from(row['instruments'] as Map))
            : null,
        melody: row['melody'] is Map
            ? Melody.fromJson(Map<String, dynamic>.from(row['melody'] as Map))
            : null,
      );
    }

    final lyricRows = await client
        .from('lyric_sync_cues')
        .select('contribution_id, start_ms, end_ms, confidence')
        .eq('project_id', projectId)
        .order('start_ms');
    // id and source were never in this select, so every cue the app loaded
    // came back with no id and as 'automatic' — which read a hand-typed chord
    // as a detected one everywhere the difference matters, and this is the
    // first place it decides anything (a correction may not spread over a
    // chord somebody typed; see chord_repeats.dart).
    final chordRows = await client
        .from('chord_cues')
        .select('id, start_ms, end_ms, chord, confidence, source')
        .eq('project_id', projectId)
        .order('start_ms');

    final stemRows = await client
        .from('project_stems')
        .select('stem, storage_path, byte_size')
        .eq('project_id', projectId);

    return SongAnalysisBundle(
      stems: (stemRows as List<dynamic>)
          .map((value) {
            final row = Map<String, dynamic>.from(value as Map);
            return SongStem(
              projectId: projectId,
              kind: StemKind.values.byName(row['stem'] as String),
              storagePath: row['storage_path'] as String,
              byteSize: row['byte_size'] as int?,
            );
          })
          .toList(growable: false)
        ..sort((left, right) => left.kind.index.compareTo(right.kind.index)),
      reference: reference,
      lyricCues: (lyricRows as List<dynamic>)
          .map((value) {
            final row = Map<String, dynamic>.from(value as Map);
            return LyricSyncCue(
              contributionId: row['contribution_id'] as String,
              startMs: row['start_ms'] as int,
              endMs: row['end_ms'] as int,
              confidence: (row['confidence'] as num).toDouble(),
            );
          })
          .toList(growable: false),
      chordCues: (chordRows as List<dynamic>)
          .map((value) {
            final row = Map<String, dynamic>.from(value as Map);
            return ChordCue(
              id: row['id'] as int?,
              startMs: row['start_ms'] as int,
              endMs: row['end_ms'] as int,
              chord: row['chord'] as String,
              confidence: (row['confidence'] as num).toDouble(),
              source: row['source'] as String? ?? 'automatic',
            );
          })
          .toList(growable: false),
    );
  }

  Future<void> _deleteChordRow({
    required String projectId,
    int? cueId,
    int? startMs,
    String? chord,
  }) async {
    if (cueId == null && (startMs == null || chord == null)) return;
    var query = client.from('chord_cues').delete().eq('project_id', projectId);
    if (cueId != null) {
      query = query.eq('id', cueId);
    } else {
      query = query.eq('start_ms', startMs!).eq('chord', chord!);
    }
    await query;
  }

  Future<SongAnalysisBundle> deleteChordCue({
    required String projectId,
    int? cueId,
    required int originalStartMs,
    required String originalChord,
  }) async {
    await _deleteChordRow(
      projectId: projectId,
      cueId: cueId,
      startMs: originalStartMs,
      chord: originalChord,
    );
    return load(projectId);
  }

  Future<SongAnalysisBundle> saveManualChordCue({
    required String projectId,
    int? cueId,
    int? originalStartMs,
    String? originalChord,
    required String chord,
    required int startMs,
    required int endMs,
  }) async {
    if (cueId != null || (originalStartMs != null && originalChord != null)) {
      await _deleteChordRow(
        projectId: projectId,
        cueId: cueId,
        startMs: originalStartMs,
        chord: originalChord,
      );
    }
    await client.from('chord_cues').insert(<String, dynamic>{
      'project_id': projectId,
      'start_ms': startMs,
      'end_ms': endMs,
      'chord': chord,
      'confidence': 1.0,
      'source': 'manual',
    });
    return load(projectId);
  }

  /// The same correction, in every place the passage repeats.
  ///
  /// Each target is what findChordRepeats worked out: the detected cue that
  /// stood there goes, and the corrected chord is written in its place as
  /// the same manual row a single correction writes, so nothing reading the
  /// cues afterwards can tell the two apart (Every Musician, Same Song, 17
  /// September 2026). Only ever called after the person said yes.
  Future<SongAnalysisBundle> applyChordToRepeats({
    required String projectId,
    required String chord,
    required List<ChordRepeatTarget> targets,
  }) async {
    if (targets.isEmpty) return load(projectId);
    for (final target in targets) {
      final gone = target.replaces;
      if (gone == null) continue;
      await _deleteChordRow(
        projectId: projectId,
        cueId: gone.id,
        startMs: gone.startMs,
        chord: gone.chord,
      );
    }
    await client.from('chord_cues').insert(<Map<String, dynamic>>[
      for (final target in targets)
        <String, dynamic>{
          'project_id': projectId,
          'start_ms': target.startMs,
          'end_ms': target.endMs,
          'chord': chord,
          'confidence': 1.0,
          'source': 'manual',
        },
    ]);
    return load(projectId);
  }

  Future<ReferenceTrack> attachReference({
    required SongProject project,
    required String localPath,
    required String displayName,
  }) async {
    if (kIsWeb) throw UnsupportedError('Song analysis is currently available on the mobile tester.');
    final file = File(localPath);
    if (!await file.exists()) throw StateError('The selected audio file is no longer available.');
    final byteSize = await file.length();
    if (byteSize > 80 * 1024 * 1024) {
      throw StateError('A reference recording has to be under 80 MB.');
    }
    // Length matters more than size and was only being checked after the
    // upload, at analysis time — so an hour of rehearsal tape uploaded in
    // full, started a job nothing could finish, and left somebody watching a
    // progress bar that was never going to complete. Checked here it costs a
    // second and refuses before anything is spent.
    await _requireAnalyzableLength(localPath);

    final previous = await load(project.id);
    final ext = audioFileExtension(localPath);
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final storagePath = '${project.roomId}/${project.id}/analysis/reference_$timestamp.$ext';
    final bytes = await file.readAsBytes();
    await client.storage.from('room-files').uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(contentType: mimeTypeForExtension(ext), upsert: false),
        );

    Map<String, dynamic>? fileRow;
    try {
      fileRow = await client
          .from('files')
          .insert(<String, dynamic>{
            'project_id': project.id,
            'uploaded_by': client.auth.currentUser!.id,
            'storage_path': storagePath,
            'display_name': displayName,
            'mime_type': mimeTypeForExtension(ext),
            'byte_size': byteSize,
          })
          .select()
          .single();
      await client.from('project_audio_references').upsert(
        <String, dynamic>{
          'project_id': project.id,
          'file_id': fileRow['id'],
          'uploaded_by': client.auth.currentUser!.id,
          'analysis_state': 'uploaded',
          'duration_ms': null,
          'bpm': null,
          'musical_key': null,
          'analyzer_version': null,
          'lyric_confidence': null,
          'chord_confidence': null,
          'last_error': null,
        },
        onConflict: 'project_id',
      );
      await client.from('lyric_sync_cues').delete().eq('project_id', project.id);
      await client.from('chord_cues').delete().eq('project_id', project.id);
      // Stems belong to the recording that produced them — a new reference
      // makes the old ones wrong, not just stale.
      await _clearStems(project.id);
    } catch (_) {
      if (fileRow != null) {
        await client.from('files').delete().eq('id', fileRow['id'] as Object);
      }
      await client.storage.from('room-files').remove(<String>[storagePath]);
      rethrow;
    }

    final old = previous.reference;
    if (old != null && old.fileId != fileRow['id']) {
      try {
        await client.storage.from('room-files').remove(<String>[old.storagePath]);
        await client.from('files').delete().eq('id', old.fileId);
      } catch (error) {
        // The new reference is already valid. Old-file cleanup can be retried
        // later — but nothing retries it, and nothing counted it either, so
        // "later" has never happened. Storage is billed monthly on everything
        // ever uploaded; a cleanup failing quietly is a bill that only grows.
        unawaited(ErrorReporter().reportWarning(
          service: 'analysis', stage: 'old_file_cleanup',
          message: error.toString()));
      }
    }

    return ReferenceTrack(
      projectId: project.id,
      fileId: fileRow['id'] as String,
      storagePath: storagePath,
      displayName: displayName,
      state: SongAnalysisState.uploaded,
    );
  }

  /// Removes the reference recording and any analysis derived from it,
  /// returning the project to the "no reference yet" state.
  Future<void> removeReference(ReferenceTrack reference) async {
    await client.from('lyric_sync_cues').delete().eq('project_id', reference.projectId);
    await client.from('chord_cues').delete().eq('project_id', reference.projectId);
    await _clearStems(reference.projectId);
    await client.from('project_audio_references').delete().eq('project_id', reference.projectId);
    try {
      await client.from('files').delete().eq('id', reference.fileId);
    } catch (_) {
      // Non-fatal: the reference row above is what the app actually reads from.
    }
    try {
      await client.storage.from('room-files').remove(<String>[reference.storagePath]);
    } catch (_) {
      // Non-fatal: an orphaned storage object doesn't affect app behavior.
    }
  }

  /// A playable handle on the reference recording.
  ///
  /// A local file on a phone, and a **signed URL** in a browser, where there
  /// is no filesystem to put one in. It used to throw on the web, which is
  /// why the Takes screen said "The song has a recording but it could not be
  /// loaded here" for every song, to everybody, on app.colabroom.com.
  ///
  /// Both are handed to `audioSourceFor`, which builds the right kind of
  /// source without the caller needing to know which it got.
  ///
  /// A song kept on this phone answers first, from the app's own storage,
  /// and needs neither the temp directory nor the network. The temp cache
  /// below is the OS's to clear; the kept copy is the person's.
  Future<String> ensureLocalReference(ReferenceTrack reference) async {
    if (kIsWeb) return _signedUrl(reference.storagePath);
    final here = await kept.audioPath(reference.projectId, reference.storagePath);
    if (here != null) return here;
    final directory = await getTemporaryDirectory();
    final ext = audioFileExtension(reference.storagePath);
    final path = '${directory.path}/colabroom_reference_${reference.fileId}.$ext';
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    final bytes = await client.storage.from('room-files').download(reference.storagePath);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  /// A URL the browser can stream, good for two hours.
  ///
  /// Short-lived because after signing, the URL itself is the credential.
  /// Long enough to listen to a song and the few after it without a re-sign
  /// mid-listen.
  Future<String> _signedUrl(String storagePath) async {
    return client.storage
        .from('room-files')
        .createSignedUrl(storagePath, const Duration(hours: 2).inSeconds);
  }

  Future<Uint8List> downloadReferenceBytes(ReferenceTrack reference) {
    return client.storage.from('room-files').download(reference.storagePath);
  }

  /// Caches a separated stem to a local file so it can be handed to the
  /// audio player by path, mirroring [ensureLocalReference]. Stems are
  /// always MP3 (the worker encodes them before upload).
  Future<String> ensureLocalStem(SongStem stem) async {
    if (kIsWeb) return _signedUrl(stem.storagePath);
    final here = await kept.audioPath(stem.projectId, stem.storagePath);
    if (here != null) return here;
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/colabroom_stem_${stem.projectId}_${stem.kind.name}.mp3';
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    final bytes = await client.storage.from('room-files').download(stem.storagePath);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Drops a project's stem rows and their storage objects. Re-analysis
  /// replaces them through the Edge Function instead, so this is only for
  /// the paths that genuinely discard them.
  Future<void> _clearStems(String projectId) async {
    try {
      final rows = await client
          .from('project_stems')
          .select('storage_path')
          .eq('project_id', projectId);
      final paths = (rows as List<dynamic>)
          .map((value) => (value as Map)['storage_path'] as String)
          .toList(growable: false);
      if (paths.isNotEmpty) {
        await client.storage.from('room-files').remove(paths);
      }
      await client.from('project_stems').delete().eq('project_id', projectId);
    } catch (error) {
      // Non-fatal: orphaned stems cost storage but don't affect correctness,
      // and the next analysis clears the rows anyway. Counted, because stems
      // are the largest objects this app writes and "the next analysis" only
      // happens for songs somebody analyses again.
      unawaited(ErrorReporter().reportWarning(
        service: 'analysis', stage: 'stem_cleanup', message: error.toString()));
    }
  }

  /// Groups a transcript's words back into line-sized chunks by pause gaps —
  /// shared by the explicit "Replace project lyrics with this" action and
  /// the lyric review screen. Pure/no DB access.
  List<List<TranscriptWord>> groupTranscriptWords(List<TranscriptWord> words) {
    return groupTranscriptWordsIntoLines(words);
  }

  /// Text form of [groupTranscriptWords], for the explicit "Replace project
  /// lyrics with this" action — the caller is responsible for actually
  /// writing these as Contributions (via MusicBetaController, so existing
  /// lines get cleaned up correctly, voice notes included).
  ///
  /// [language] is what the room said the song is sung in (0163), and it is
  /// asked for rather than defaulted because these lines become the song's
  /// own words: the transcriber's tokens in Chinese or Japanese are one or
  /// two characters each, and joining them with spaces would write the
  /// room's lyrics as 月光 落在 窗前 — spaced out in a way no reader of them
  /// has ever seen, and then printed and exported that way (review, 18
  /// September 2026).
  List<String> transcriptLyricLines(
    ReferenceTrack reference, {
    required String? language,
  }) {
    return groupTranscriptWords(reference.transcriptWords)
        .map((line) => joinLyricUnits(
              line.map((word) => word.word).toList(growable: false),
              language,
            ).trim())
        .where((body) => body.isNotEmpty)
        .toList(growable: false);
  }

  /// Overwrites the saved transcript itself (not the manual workspace) —
  /// used by the lyric review screen so corrections show up on the Song
  /// Sheet and in Live Performance's "Song Sheet" source, both of which
  /// read from this transcript rather than from project.contributions.
  Future<SongAnalysisBundle> updateTranscript({
    required String projectId,
    required List<TranscriptWord> words,
  }) async {
    await client.from('project_audio_references').update(<String, dynamic>{
      'transcript_words': words.map((word) => word.toJson()).toList(growable: false),
      'transcript_text': words.map((word) => word.word).join(' '),
    }).eq('project_id', projectId);
    return load(projectId);
  }

  /// Listens to the recording again, this time told what language it is
  /// sung in (0163).
  ///
  /// The transcript already on the song was made before anybody said, so
  /// Whisper decided the language itself from the first few seconds — and on
  /// a song with an instrumental intro, or a voice it finds hard, that is
  /// where it decides wrong and writes fluent nonsense in the wrong
  /// language. Being told removes the guess.
  ///
  /// Offered, never automatic. Saying what a song is sung in must not
  /// silently spend money and replace words somebody may have corrected by
  /// hand; the sheet asks once and this runs only on a yes (Every Musician,
  /// Same Song, 17 September 2026).
  ///
  /// Only the words are rewritten. Chords, structure, key and the stems are
  /// not about language and are left exactly as they are, which is also why
  /// this is not a re-analysis: it is one call to the transcriber.
  ///
  /// Throws a sentence when nothing came back, because this was asked for
  /// and an empty page with no explanation reads as the app having lost the
  /// words it already had.
  Future<SongAnalysisBundle> transcribeAgain({
    required SongProject project,
    required SongAnalysisBundle bundle,
  }) async {
    final reference = bundle.reference;
    if (reference == null) {
      throw StateError('There is no recording to listen to.');
    }
    // The isolated vocal where separation left one, exactly as the first
    // pass chose it: transcribing the vocal stem rather than the full mix is
    // most of the accuracy, and listening again to a worse source would be a
    // strange thing to call an improvement.
    String? vocalPath;
    for (final stem in bundle.stems) {
      if (stem.kind == StemKind.vocals) {
        vocalPath = stem.storagePath;
        break;
      }
    }
    final result = await _transcribeViaCloud(
      project,
      vocalPath ?? reference.storagePath,
    );
    final rejected = (result['rejected'] as String?)?.trim();
    if (rejected != null && rejected.isNotEmpty) {
      throw StateError(
        'The words came back garbled rather than sung — this happens '
        'occasionally on a hard recording. What was already on the sheet is '
        'still there.',
      );
    }
    final words = (result['words'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .where((row) => looksLikeSpeech(row['word'] as String? ?? ''))
        .map(TranscriptWord.fromJson)
        .toList(growable: false);
    if (words.isEmpty) {
      throw StateError(
        'No sung words were heard this time. What was already on the sheet '
        'is still there.',
      );
    }
    return updateTranscript(projectId: project.id, words: words);
  }

  /// Calls the `transcribe-audio` Supabase Edge Function, which forwards
  /// an already-uploaded recording to OpenAI's Whisper API and returns
  /// word-level timestamps. The OpenAI API key lives only in that
  /// function's server-side secrets — never in the app — so this is a
  /// network call, not a local model.
  ///
  /// [storagePath] is the isolated vocal stem when separation produced one,
  /// and only falls back to the full mix otherwise. Transcribing the
  /// separated vocal rather than the raw mix measurably cuts word errors:
  /// most of Whisper's mistakes on singing come from backing instrumentation
  /// bleeding into the signal, not from the words being unclear.
  ///
  /// What it is told about the song — the song's own words, and what the
  /// room said it is sung in (0163) — is [transcribeRequest].
  Future<Map<String, dynamic>> _transcribeViaCloud(
    SongProject project,
    String storagePath,
  ) async {
    final response = await client.functions.invoke(
      'transcribe-audio',
      body: transcribeRequest(project, storagePath),
    );
    final data = response.data;
    if (data is! Map) {
      throw StateError('The transcription service returned an unexpected response.');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['error'] != null) {
      throw StateError(map['error'].toString());
    }
    return map;
  }

  /// Calls the `analyze-chords` Supabase Edge Function, which runs
  /// [reference]'s recording through the self-hosted Demucs -> ChordMini
  /// pipeline (see supabase/functions/analyze-chords) instead of the
  /// on-device chroma heuristic. Returns the same {cues, key} shape
  /// analyzeChordsOnDevice does, so callers don't need to care which one ran.
  Future<Map<String, dynamic>> _invokeAnalyze(Map<String, dynamic> body) async {
    final response = await client.functions.invoke('analyze-chords', body: body);
    final data = response.data;
    if (data is! Map) {
      throw StateError('The chord detection service returned an unexpected response.');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['error'] != null) {
      throw StateError(map['error'].toString());
    }
    return map;
  }

  Future<Map<String, dynamic>> _detectChordsViaCloud(
    ReferenceTrack reference, {
    required int durationMs,
    required AnalysisDepth depth,
    String? resumeJobId,
    String? lyricsHint,
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    final request = <String, dynamic>{
      'projectId': reference.projectId,
      'storagePath': reference.storagePath,
      'bucket': 'room-files',
      // Reaches the transcriber as an initial prompt, biasing spelling and
      // names toward the words this song actually uses. Sent with the job
      // rather than with a later call because the job is what transcribes now.
      if (lyricsHint != null) 'lyricsHint': lyricsHint,
      // Tells the Edge Function this build can handle `start` coming back
      // finished instead of with a job id. Builds that predate the analysis
      // cache would read that as "no job was started" and fail, and a
      // bandmate on last week's APK shouldn't break the moment the function
      // is deployed.
      'acceptsCachedAnalysis': true,
      // Only for the usage log — this is what the vendors bill on, and the
      // Edge Function has no way to know it.
      'durationMs': durationMs,
      'depth': depth.wireName,
    };

    // A job this project already started and never collected. Rejoining it
    // costs one poll; starting over costs another few minutes on a GPU.
    if (resumeJobId != null) {
      onProgress?.call(const SongAnalysisProgress('Picking up where this left off', 0.15));
      return _awaitSeparation(request, resumeJobId, onProgress: onProgress);
    }

    // The Edge Function starts the separation job and hands back its id
    // rather than waiting for it. Supabase kills a function that goes 150s
    // without producing output, and separating a four-minute song on a cold
    // GPU worker comfortably exceeds that — so the waiting happens here,
    // where it can take as long as it needs and show progress meanwhile.
    final started = await _invokeAnalyze(<String, dynamic>{...request, 'action': 'start'});
    // A recording that has been through the pipeline before comes back
    // finished from this first call — same bytes, same answer, no GPU job.
    if (started['status'] == 'complete') {
      onProgress?.call(reusedAnalysisProgress);
      return started;
    }
    final jobId = started['jobId'] as String?;
    if (jobId == null) {
      throw StateError('The separation service did not start a job.');
    }

    // Written down before the wait begins, so if the app never comes back
    // from here the job isn't lost — reopening the song picks it up rather
    // than paying for the whole thing again.
    await _rememberJob(reference.projectId, jobId);
    return _awaitSeparation(request, jobId, onProgress: onProgress);
  }

  /// Reads the file's length and refuses it if it's too long to analyze.
  ///
  /// A decode failure here is not treated as a rejection: the file may still
  /// be perfectly analyzable, and refusing it because one decoder couldn't
  /// read its metadata would be a worse bug than the one this prevents.
  Future<void> _requireAnalyzableLength(String localPath) async {
    Duration duration;
    try {
      duration = (await AudioDecoder.getAudioInfo(localPath)).duration;
    } catch (_) {
      return;
    }
    requireAnalyzableDuration(duration);
  }

  Future<void> _rememberJob(String projectId, String? jobId) async {
    try {
      await client.from('project_audio_references').update(<String, dynamic>{
        'analysis_job_id': jobId,
        'analysis_started_at': jobId == null ? null : DateTime.now().toUtc().toIso8601String(),
      }).eq('project_id', projectId);
    } catch (_) {
      // Losing the breadcrumb costs a re-run in the rare case the app dies
      // mid-analysis. Failing the analysis over it would cost one every time.
    }
  }

  /// A separation job this project started and never collected.
  ///
  /// Null when there isn't one, or when it's old enough that RunPod will have
  /// forgotten it — resuming that is just a slower way to fail.
  Future<String?> resumableJobId(String projectId) async {
    try {
      final row = await client
          .from('project_audio_references')
          .select('analysis_job_id, analysis_started_at')
          .eq('project_id', projectId)
          .maybeSingle();
      final jobId = row?['analysis_job_id'] as String?;
      final startedAt = DateTime.tryParse(row?['analysis_started_at'] as String? ?? '');
      if (jobId == null || startedAt == null) return null;
      return DateTime.now().toUtc().difference(startedAt) < const Duration(hours: 1)
          ? jobId
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Waits out the GPU job, forgiving the network for going away.
  ///
  /// The job itself is running on RunPod and does not care what the phone is
  /// doing. All that's happening here is asking whether it's finished — so a
  /// failed ask is not a failed analysis, it's a question that needs asking
  /// again. Losing DNS the moment the screen goes off is normal Android
  /// behaviour, not an error condition, and treating it as one threw away
  /// minutes of finished GPU work.
  Future<Map<String, dynamic>> _awaitSeparation(
    Map<String, dynamic> request,
    String jobId, {
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    var elapsed = Duration.zero;
    var attempt = 0;
    var consecutiveFailures = 0;
    while (elapsed < separationTimeout) {
      final delay = separationPollDelay(attempt);
      await Future<void>.delayed(delay);
      elapsed += delay;
      attempt += 1;
      try {
        final poll = await _invokeAnalyze(
          <String, dynamic>{...request, 'action': 'poll', 'jobId': jobId},
        );
        consecutiveFailures = 0;
        if (poll['status'] != 'pending') return poll;
      } on StateError {
        // The service answered, and the answer was no. Asking again won't
        // change it.
        rethrow;
      } catch (error) {
        if (!isConnectivityFailure(error)) rethrow;
        consecutiveFailures += 1;
        if (consecutiveFailures >= separationMaxConsecutiveFailures) rethrow;
      }
      onProgress?.call(separationProgress(elapsed));
    }
    // Giving up waiting is not the same as the job failing, and that
    // distinction is the difference between a bug and a delay. The GPU job is
    // still running, the recording is untouched, and the job id is still on
    // the row — reopening the song rejoins it (see resumableJobId), so
    // nothing is lost and nothing is paid for twice.
    //
    // Its own type, because the caller has to treat it differently: this must
    // not mark the analysis failed, and must not clear the job id.
    throw const AnalysisStillRunning(
      'This is taking longer than usual — the first analysis after a quiet '
      'spell has to wake the server up. It is still running: come back to this '
      'song in a few minutes and it will carry on where it left off.',
    );
  }

  Future<SongAnalysisBundle> analyze({
    required SongProject project,
    required ReferenceTrack reference,
    required String localPath,
    AnalysisDepth depth = AnalysisDepth.full,
    /// A separation job this project started and never collected — see
    /// resumableJobId. Rejoining it costs one poll; starting over costs
    /// another few minutes of GPU time the user already paid for.
    String? resumeJobId,
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    await _setState(project.id, SongAnalysisState.processing);
    try {
      onProgress?.call(const SongAnalysisProgress('Preparing audio', 0.05));
      final info = await AudioDecoder.getAudioInfo(localPath);
      final durationMs = info.duration.inMilliseconds;

      // Separation runs first now, because the lyrics pass depends on it:
      // the isolated vocal stem it produces is what Whisper transcribes.
      //
      // Chords don't need singing at all (they come from the harmonic stems,
      // independent of speech), so a lyrics failure of any kind —
      // instrumental audio, empty transcription, the request itself failing —
      // must never block chord detection. Every failure mode below adds to
      // lyricsWarning and falls through, surfaced as a non-fatal
      // analysis_warning rather than a hard error.
      String? lyricsWarning;
      onProgress?.call(const SongAnalysisProgress('Separating the instruments', 0.15));
      Map<String, dynamic> chordResult;
      var usedFallback = false;
      try {
        chordResult = await _detectChordsViaCloud(
          reference,
          durationMs: durationMs,
          depth: depth,
          resumeJobId: resumeJobId,
          lyricsHint: lyricsPromptFor(project),
          onProgress: onProgress,
        );
      } catch (error) {
        // The fallback is for the pipeline being down, not for the phone
        // being off the network. Substituting a much worse analysis because
        // a connection dropped means losing the good one you already paid
        // for — and it happens silently, which is how a screen going to
        // sleep replaced a real analysis with an on-device guess.
        //
        // Offline, stop and say so. Nothing is lost: the recording is still
        // there, the cache means a retry costs almost nothing, and "you went
        // offline" is a thing the musician can actually act on.
        if (isConnectivityFailure(error)) {
          throw StateError(
            'Lost the connection while analyzing this recording. Nothing was '
            'lost — try again once you have signal, and it will pick up much '
            'faster the second time.',
          );
        }
        // An outage in the Demucs/ChordMini pipeline shouldn't turn "no
        // chords this time" into "no analysis at all". Falls back to the
        // on-device heuristic, which is worse but still functional — and
        // produces no stems, so lyrics fall back to the full mix below.
        usedFallback = true;
        final rawPcm = await AudioDecoder.convertToWavBytes(
          await File(localPath).readAsBytes(),
          formatHint: audioFileExtension(localPath),
          sampleRate: 11025,
          channels: 1,
          bitDepth: 16,
          includeHeader: false,
        );
        chordResult = await compute(analyzeChordsOnDevice, <String, dynamic>{
          'pcm': rawPcm,
          'sampleRate': 11025,
          'durationMs': durationMs,
        });
        lyricsWarning =
            'Cloud chord detection was unavailable, so a less accurate on-device fallback was used. Details: $error';
        // The degradation that matters most: analysis will still "succeed"
        // from here, just with materially worse chords and no stems, so this
        // is invisible unless it's reported on its own.
        await _reporter.reportWarning(
          service: 'analysis',
          stage: 'separation',
          message: 'Cloud chord detection unavailable, used on-device fallback: $error',
          projectId: project.id,
        );
      }

      // The isolated vocal stem when separation produced one, the raw mix
      // otherwise. This is the single biggest lyric-accuracy lever in the
      // pipeline and it costs nothing extra — separation already produced
      // this stem, it was just being discarded before.
      final vocalStemPath = chordResult['vocalStemPath'] as String?;
      List<TranscriptWord> transcriptWords = const <TranscriptWord>[];
      String? transcriptText;
      // The analysis job transcribes the vocal stem itself now, on the GPU
      // that just separated it, with a model already resident in the worker
      // image. Measured against the lyrics these songs' writers typed, that
      // model recalls 68.5% of written lines to whisper-1's 60.2% — and it
      // costs nothing, because the GPU is running either way.
      //
      // Absent means three different things, all handled the same way: an
      // instrumental, a worker image that predates transcription, and the
      // on-device chord fallback, which never touched a worker at all. Each
      // falls through to the API path below, so a band on mixed builds and a
      // pipeline outage both still get lyrics.
      final inlineTranscript = chordResult['transcript'];
      final rejected = chordResult['transcriptRejected'] as String?;
      // Not thrown. The catch below wraps whatever reaches it in
      // "Could not transcribe... Details: $error", and a StateError stringifies
      // with a "Bad state:" prefix — so throwing here would have shown a
      // musician a Dart exception name inside a sentence written for them.
      // This is an expected outcome with a known cause, not an error.
      //
      // Deliberately not retried against the paid API either: this is the
      // failure where a model returns confident nonsense, and the recovery
      // that actually works is re-running the analysis — which only stays
      // useful because nothing cached the rejection as though it were an
      // answer.
      if (rejected != null) {
        const note = 'The words came back garbled rather than sung — this '
            'happens occasionally on a hard recording. Chords and structure '
            'are unaffected; run the analysis again to retry the lyrics.';
        lyricsWarning = lyricsWarning == null ? note : '$lyricsWarning\n\n$note';
        await _reporter.reportWarning(
          service: 'analysis',
          stage: 'lyrics',
          message: 'Transcript rejected by the hallucination guard: $rejected',
          projectId: project.id,
        );
      }
      try {
        if (rejected != null) throw const _TranscriptionSkipped();
        onProgress?.call(SongAnalysisProgress(
          vocalStemPath == null ? 'Listening for the words' : 'Listening to the isolated vocal',
          0.55,
        ));
        final cloudResult = inlineTranscript is Map
            ? Map<String, dynamic>.from(inlineTranscript)
            : await _transcribeViaCloud(
                project,
                vocalStemPath ?? reference.storagePath,
              );
        // Whisper (cloud, same as on-device) emits literal "♪" placeholder
        // tokens as "words" for non-lexical/instrumental stretches instead
        // of just leaving them out — filter those out here so they don't
        // get treated as real sung lyrics.
        final rawWords = (cloudResult['words'] as List<dynamic>? ?? const <dynamic>[])
            .map((value) => Map<String, dynamic>.from(value as Map))
            .where((row) => looksLikeSpeech((row['word'] as String? ?? '')))
            .toList(growable: false);
        if (rawWords.isEmpty) {
          final heard = (cloudResult['text'] as String? ?? '').trim();
          // Surfacing what Whisper actually returned (rather than just "no
          // words") makes it possible to tell a real instrumental apart from
          // Whisper mis-hearing an unusual voice (e.g. AI-generated vocals)
          // as non-speech — worth seeing the raw snippet either way.
          final heardSnippet = heard.isEmpty
              ? ''
              : ' Whisper heard: "${heard.length > 80 ? '${heard.substring(0, 80)}…' : heard}"';
          final note = heard.isNotEmpty && !looksLikeSpeech(heard)
              ? 'This recording sounds instrumental — chords were detected, but '
                  'there are no words to sync lyrics to.$heardSnippet'
              : 'Not enough sung words were heard to sync lyrics, but chords were still detected.'
                  '$heardSnippet';
          // Append rather than assign: the chord stage runs first now, so a
          // separation outage may already have left a note here worth keeping.
          lyricsWarning = lyricsWarning == null ? note : '$lyricsWarning\n\n$note';
        } else {
          onProgress?.call(const SongAnalysisProgress('Writing down the lyrics', 0.75));
          // Analysis always transcribes fresh from the recording — it never
          // reads from or writes to `contributions` (the collaborative
          // lyric-editing document). The two are deliberately independent:
          // one is the manual workspace, the other is what the app heard.
          // The song sheet renders straight from transcriptWords (see
          // musician_sheet_logic.dart's buildMusicianSheetLines/_transcriptLines).
          transcriptWords = rawWords
              .map((row) => TranscriptWord(
                    word: (row['word'] as String? ?? '').trim(),
                    startMs: (row['start_ms'] as num?)?.toInt() ?? 0,
                    endMs: (row['end_ms'] as num?)?.toInt() ?? 0,
                  ))
              .where((word) => word.word.isNotEmpty)
              .toList(growable: false);
          transcriptText = transcriptWords.map((word) => word.word).join(' ');
        }
      } on _TranscriptionSkipped {
        // Already reported before the block was entered. Nothing to add,
        // and deliberately not folded into the catch below: this is an
        // expected outcome with a known cause, not a failure.
      } catch (error) {
        final note = 'Could not transcribe this recording\'s speech, so only chords were '
            'detected. Details: $error';
        lyricsWarning = lyricsWarning == null ? note : '$lyricsWarning\n\n$note';
        await _reporter.reportWarning(
          service: 'analysis',
          stage: 'lyrics',
          message: 'Transcription failed: $error',
          projectId: project.id,
        );
      }

      onProgress?.call(const SongAnalysisProgress('Saving song map', 0.9));
      // lyric_sync_cues is no longer written to — it existed to key timing
      // off a Contribution row, which analysis-generated lyrics never have.
      // Still clearing it so a project analyzed under the old aligned-mode
      // doesn't keep stale, now-orphaned cues around.
      await client.from('lyric_sync_cues').delete().eq('project_id', project.id);
      await client.from('chord_cues').delete().eq('project_id', project.id);
      final detectedCues = (chordResult['cues'] as List<dynamic>)
          .map((value) {
            final row = Map<String, dynamic>.from(value as Map);
            return ChordCue(
              startMs: row['startMs'] as int,
              endMs: row['endMs'] as int,
              chord: row['chord'] as String,
              confidence: (row['confidence'] as num).toDouble(),
            );
          })
          .toList(growable: false);
      // Put the chords on the song's grid before storing them. The model
      // reports boundaries to the analysis frame; the song happens in beats.
      // The on-device fallback produces no beat grid, so its chords stay
      // exactly where it heard them.
      final beatsMs = usedFallback ? const <int>[] : _msList(chordResult['beatsMs']);
      final chordCues = snapChordsToBeatGrid(detectedCues, beatsMs);
      if (chordCues.isNotEmpty) {
        await client.from('chord_cues').insert(
              chordCues
                  .map((cue) => <String, dynamic>{
                        'project_id': project.id,
                        'start_ms': cue.startMs,
                        'end_ms': cue.endMs,
                        'chord': cue.chord,
                        'confidence': cue.confidence,
                        // Which beat of the song the chord lands on. This
                        // column has been holding the cue's position in the
                        // list, which was never a beat index at all.
                        'beat_index': beatIndexAt(cue.startMs, beatsMs),
                        'source': 'automatic',
                      })
                  .toList(growable: false),
            );
      }

      // Averaging per-cue confidence produced a constant, because every cue
      // carries the same placeholder. Coverage is measured from the cues that
      // actually name a chord.
      final coverage = chordCoverage(chordCues, durationMs);
      // The on-device fallback only ever computes {cues, key} — bpm/structure/
      // instruments come exclusively from the cloud pipeline, so they're left
      // unavailable rather than guessed whenever the fallback ran.
      final bpm = usedFallback ? null : (chordResult['bpm'] as num?)?.toDouble();
      // Whatever the band called these parts last time survives the
      // re-analysis. Read from the row rather than carried through the method,
      // so it works no matter how the analysis got here.
      final structureSections = carryCustomSectionNames(
        await _savedStructureSections(project.id),
        usedFallback
            ? const <StructureSection>[]
            : (chordResult['structure'] as List<dynamic>? ?? const <dynamic>[])
                .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
                .toList(growable: false),
      );
      final instruments = usedFallback || chordResult['instruments'] is! Map
          ? null
          : InstrumentSummary.fromJson(Map<String, dynamic>.from(chordResult['instruments'] as Map));
      // The tune, when the worker heard one. Null is the honest answer for
      // an instrumental and for the on-device fallback, which has no stem.
      final melody = usedFallback || chordResult['melody'] is! Map
          ? null
          : Melody.fromJson(Map<String, dynamic>.from(chordResult['melody'] as Map));
      await client
          .from('project_audio_references')
          .update(<String, dynamic>{
            'analysis_state': 'ready',
            'duration_ms': durationMs,
            'bpm': bpm,
            'musical_key': chordResult['key'],
            // 0.2: htdemucs_6s separation, Whisper reads the isolated vocal
            // stem, Krumhansl-Schmuckler key. Worth distinguishing from 0.1
            // results, which were produced by a materially different pipeline.
            'analyzer_version': 'colabroom-cloud-0.2',
            // No longer a meaningful "match against existing text" score
            // now that lyrics are always transcribed fresh rather than
            // aligned to something else — nothing to compare against.
            'lyric_confidence': null,
            // Deliberately null: the number this column used to hold was a
            // placeholder averaged into a percentage, and stale 0.8s are
            // worse than an honest blank.
            'chord_confidence': null,
            'chord_coverage': coverage,
            'beats_ms': usedFallback ? null : chordResult['beatsMs'],
            'downbeats_ms': usedFallback ? null : chordResult['downbeatsMs'],
            'beats_per_bar': usedFallback ? null : chordResult['beatsPerBar'],
            'transcript_text': transcriptText,
            'transcript_words': transcriptWords.map((word) => word.toJson()).toList(growable: false),
            'structure_sections': structureSections.map((s) => s.toJson()).toList(growable: false),
            'instruments': instruments?.toJson() ?? <String, dynamic>{},
            'melody': melody?.toJson(),
            'melody_low_midi': melody?.lowMidi,
            'melody_high_midi': melody?.highMidi,
            'analysis_warning': lyricsWarning,
            'last_error': null,
          })
          .eq('project_id', project.id);
      // Collected. Nothing left to resume.
      await _rememberJob(project.id, null);
      onProgress?.call(const SongAnalysisProgress('Ready', 1));
      // Awaited so a failure reloading the saved bundle still lands in the
      // catch below and marks the analysis failed, rather than escaping as
      // an unhandled future while the row claims 'ready'.
      return await load(project.id);
    } on AnalysisStillRunning {
      // The one case that must not be recorded as a failure: the job is still
      // running and the breadcrumb has to survive so reopening the song
      // rejoins it. Leaves the state as `processing`, which is the truth.
      rethrow;
    } catch (error) {
      // A job id left behind here would be resumed forever against a job
      // that already failed.
      await _rememberJob(project.id, null);
      await client
          .from('project_audio_references')
          .update(<String, dynamic>{
            'analysis_state': 'failed',
            'last_error': error.toString(),
          })
          .eq('project_id', project.id);
      await _reporter.reportError(
        service: 'analysis',
        message: error.toString(),
        projectId: project.id,
      );
      rethrow;
    }
  }

  /// The structure currently stored for a project, custom names and all.
  Future<List<StructureSection>> _savedStructureSections(String projectId) async {
    try {
      final row = await client
          .from('project_audio_references')
          .select('structure_sections')
          .eq('project_id', projectId)
          .maybeSingle();
      final saved = row?['structure_sections'] as List<dynamic>? ?? const <dynamic>[];
      return saved
          .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList(growable: false);
    } catch (_) {
      // Losing a custom name is a nuisance; failing the analysis that
      // produced everything else would be worse.
      return const <StructureSection>[];
    }
  }

  /// Renames a part of the song — every occurrence of it.
  ///
  /// You rename the *part*, not one stretch of the recording: call the chorus
  /// "the big one" and all of them are the big one. Passing a blank name puts
  /// the model's own word back.
  Future<SongAnalysisBundle> renameSection({
    required String projectId,
    required String label,
    required String? name,
  }) async {
    final saved = await _savedStructureSections(projectId);
    final trimmed = name?.trim() ?? '';
    final updated = <StructureSection>[
      for (final section in saved)
        section.label == label
            ? section.copyWith(
                customLabel: trimmed.isEmpty ? null : trimmed,
                clearCustomLabel: trimmed.isEmpty,
              )
            : section,
    ];
    await client.from('project_audio_references').update(<String, dynamic>{
      'structure_sections': updated.map((s) => s.toJson()).toList(growable: false),
    }).eq('project_id', projectId);
    return load(projectId);
  }

  Future<void> _setState(String projectId, SongAnalysisState state) async {
    await client
        .from('project_audio_references')
        .update(<String, dynamic>{'analysis_state': state.name, 'last_error': null})
        .eq('project_id', projectId);
  }
}

/// Thrown to leave the transcription block early when the guard has already
/// rejected the transcript, and caught by name immediately below it.
///
/// A sentinel rather than a StateError because the general `catch` there
/// formats whatever reaches it into a sentence a musician reads, and every
/// real exception type stringifies with a prefix — "Bad state: " — that has
/// no business appearing inside one. Catching this by name keeps a deliberate
/// skip out of the path built for genuine failures.
class _TranscriptionSkipped implements Exception {
  const _TranscriptionSkipped();
}
