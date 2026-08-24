import 'dart:io';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/music_beta_controller.dart';
import '../domain/music_models.dart';
import '../domain/song_analysis_models.dart';
import '../domain/studio_draft_models.dart';
import '../features/home/new_song_flow.dart';
import 'audio_analysis_utils.dart';
import 'chord_beat_grid.dart';
import 'error_reporter.dart';
import 'song_analysis_service.dart'
    show
        AnalysisStillRunning,
        carryCustomSectionNames,
        chordCoverage,
        isConnectivityFailure,
        reusedAnalysisProgress,
        separationMaxConsecutiveFailures,
        separationPollDelay,
        separationProgress,
        separationTimeout;

List<int> _msList(dynamic value) {
  if (value is! List) return const <int>[];
  return value.whereType<num>().map((n) => n.round()).toList(growable: false);
}

/// Does this name carry any information, or is it just when the file
/// happened to be created?
///
/// "Recording 8/23 11:40", "New Recording 12", "audio_2026_08_23.m4a" — the
/// universal failure mode of idea capture is a library of eighty files named
/// like this, none of which anyone can identify without playing them. A name
/// matching one of these shapes is safe to replace with something the
/// recording actually says.
bool looksAutoNamed(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final withoutExtension = trimmed.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '');
  // No \b after the keyword: underscore is a word character, so `audio\b`
  // refuses to match "audio_2026_08_23" — one of the commonest shapes there
  // is. The trailing character class does the work instead, which also keeps
  // "Audiophile demo" from being treated as a placeholder.
  return RegExp(
    r'^(new\s+)?(recording|voice\s*memo|audio|track|untitled|idea)[\s\d/:._-]*$',
    caseSensitive: false,
  ).hasMatch(withoutExtension);
}

/// A name for an idea, taken from the first words actually sung in it.
///
/// Returns null when there's nothing usable, so the caller keeps whatever
/// name it already had rather than replacing a real title with a fragment.
String? nameFromTranscript(String? transcript, {int maxWords = 6, int maxChars = 48}) {
  final cleaned = (transcript ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length < 3) return null;
  final words = cleaned.split(' ').where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return null;
  var title = words.take(maxWords).join(' ');
  if (title.length > maxChars) title = title.substring(0, maxChars).trimRight();
  // Strip trailing punctuation so a title doesn't end mid-sentence on a comma.
  title = title.replaceFirst(RegExp(r'[,;:.\-—]+$'), '').trim();
  return title.isEmpty ? null : title;
}

/// The Studio's pre-project counterpart to [SongAnalysisService] — same
/// analysis pipeline (same Edge Functions, same on-device fallback), but
/// keyed by an account-scoped draft instead of an existing project, since a
/// draft has no room/project to hang off yet. See studio_draft_models.dart
/// and supabase/migrations/0017_studio_drafts.sql for the parallel schema.
class StudioDraftService {
  StudioDraftService({SupabaseClient? client, ErrorReporter? reporter})
      : _clientOverride = client,
        _reporter = reporter ?? ErrorReporter(client: client);

  final SupabaseClient? _clientOverride;
  final ErrorReporter _reporter;

  /// Resolved on use, not at construction. StudioHomeScreen builds this in a
  /// state field, and IndexedStack instantiates every tab whether or not
  /// it's the visible one — so an eager `Supabase.instance` here threw on
  /// the very first frame in the preview/test configuration, before anyone
  /// had asked the service to do anything.
  SupabaseClient get client => _clientOverride ?? Supabase.instance.client;

  Future<List<StudioDraft>> listDrafts() async {
    final accountId = client.auth.currentUser!.id;
    final rows = await client
        .from('studio_drafts')
        .select()
        .eq('account_id', accountId)
        .order('created_at', ascending: false);
    return (rows as List<dynamic>)
        .map((value) => _draftFromRow(Map<String, dynamic>.from(value as Map)))
        .toList(growable: false);
  }

  Future<StudioDraftBundle> load(String draftId) async {
    final row = await client.from('studio_drafts').select().eq('id', draftId).single();
    final chordRows = await client
        .from('studio_chord_cues')
        .select('start_ms, end_ms, chord, confidence, source')
        .eq('draft_id', draftId)
        .order('start_ms');
    final stemRows = await client
        .from('studio_draft_stems')
        .select('stem, storage_path, byte_size')
        .eq('draft_id', draftId);

    return StudioDraftBundle(
      draft: _draftFromRow(Map<String, dynamic>.from(row)),
      stems: (stemRows as List<dynamic>)
          .map((value) {
            final stemRow = Map<String, dynamic>.from(value as Map);
            return SongStem(
              projectId: draftId,
              kind: StemKind.values.byName(stemRow['stem'] as String),
              storagePath: stemRow['storage_path'] as String,
              byteSize: stemRow['byte_size'] as int?,
            );
          })
          .toList(growable: false)
        ..sort((left, right) => left.kind.index.compareTo(right.kind.index)),
      chordCues: (chordRows as List<dynamic>)
          .map((value) {
            final row = Map<String, dynamic>.from(value as Map);
            return ChordCue(
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

  Future<StudioDraft> createDraftAndUpload({
    required String localPath,
    required String displayName,
  }) async {
    if (kIsWeb) throw UnsupportedError('The Studio is currently available on the mobile tester.');
    final file = File(localPath);
    if (!await file.exists()) throw StateError('The selected audio file is no longer available.');
    final byteSize = await file.length();
    if (byteSize > 80 * 1024 * 1024) {
      throw StateError('For this beta, use a recording smaller than 80 MB.');
    }
    // See SongAnalysisService.attachReference: length is the limit that
    // matters, and checking it before the upload is what stops somebody
    // watching a progress bar for a job that could never finish.
    try {
      requireAnalyzableDuration((await AudioDecoder.getAudioInfo(localPath)).duration);
    } on StateError {
      rethrow;
    } catch (_) {
      // Couldn't read the length. Let it through rather than refuse a real
      // recording over a metadata quirk.
    }
    final accountId = client.auth.currentUser!.id;
    final ext = audioFileExtension(localPath);

    final row = await client
        .from('studio_drafts')
        .insert(<String, dynamic>{
          'account_id': accountId,
          'display_name': displayName,
          // Filled in below once the draft id is known and the upload
          // succeeds — the row needs to exist first to get that id.
          'storage_path': '',
          'mime_type': mimeTypeForExtension(ext),
          'byte_size': byteSize,
          'analysis_state': 'uploaded',
        })
        .select()
        .single();
    final draftId = row['id'] as String;
    final storagePath = '$accountId/$draftId/reference.$ext';

    try {
      final bytes = await file.readAsBytes();
      await client.storage.from('studio-drafts').uploadBinary(
            storagePath,
            bytes,
            fileOptions: FileOptions(contentType: mimeTypeForExtension(ext), upsert: true),
          );
      await client.from('studio_drafts').update(<String, dynamic>{
        'storage_path': storagePath,
      }).eq('id', draftId);
    } catch (_) {
      await client.from('studio_drafts').delete().eq('id', draftId);
      rethrow;
    }

    return _draftFromRow(<String, dynamic>{...row, 'storage_path': storagePath});
  }

  Future<void> deleteDraft(StudioDraft draft) async {
    await client.from('studio_drafts').delete().eq('id', draft.id);
    try {
      await client.storage.from('studio-drafts').remove(<String>[draft.storagePath]);
    } catch (_) {
      // Non-fatal: an orphaned storage object doesn't affect app behavior.
    }
  }

  /// See SongAnalysisService._rememberJob — same breadcrumb, same reasons.
  Future<void> _rememberJob(String draftId, String? jobId) async {
    try {
      await client.from('studio_drafts').update(<String, dynamic>{
        'analysis_job_id': jobId,
        'analysis_started_at': jobId == null ? null : DateTime.now().toUtc().toIso8601String(),
      }).eq('id', draftId);
    } catch (_) {
      // Losing the breadcrumb costs a re-run in the rare case the app dies
      // mid-analysis. Failing the analysis over it would cost one every time.
    }
  }

  /// A separation job this idea started and never collected, if it's recent
  /// enough that RunPod still remembers it.
  Future<String?> resumableJobId(String draftId) async {
    try {
      final row = await client
          .from('studio_drafts')
          .select('analysis_job_id, analysis_started_at')
          .eq('id', draftId)
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

  Future<void> renameDraft(StudioDraft draft, String displayName) async {
    await client
        .from('studio_drafts')
        .update(<String, dynamic>{'display_name': displayName})
        .eq('id', draft.id);
  }

  /// Renames a part of the idea — every occurrence of it. See
  /// SongAnalysisService.renameSection; a blank name restores the model's own
  /// word.
  Future<void> renameSection({
    required StudioDraft draft,
    required String label,
    required String? name,
  }) async {
    final trimmed = name?.trim() ?? '';
    final updated = <StructureSection>[
      for (final section in draft.structureSections)
        section.label == label
            ? section.copyWith(
                customLabel: trimmed.isEmpty ? null : trimmed,
                clearCustomLabel: trimmed.isEmpty,
              )
            : section,
    ];
    await client.from('studio_drafts').update(<String, dynamic>{
      'structure_sections': updated.map((s) => s.toJson()).toList(growable: false),
    }).eq('id', draft.id);
  }

  Future<String> ensureLocalDraftFile(StudioDraft draft) async {
    if (kIsWeb) throw UnsupportedError('Draft download is not available on web yet.');
    final directory = await getTemporaryDirectory();
    final ext = audioFileExtension(draft.storagePath);
    final path = '${directory.path}/colabroom_studio_draft_${draft.id}.$ext';
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    final bytes = await client.storage.from('studio-drafts').download(draft.storagePath);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Caches a separated stem locally so it can be played by path. Mirrors
  /// SongAnalysisService.ensureLocalStem, against the drafts bucket.
  Future<String> ensureLocalStem(SongStem stem) async {
    if (kIsWeb) throw UnsupportedError('Stem playback is not available on web yet.');
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/colabroom_draft_stem_${stem.projectId}_${stem.kind.name}.mp3';
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    final bytes = await client.storage.from('studio-drafts').download(stem.storagePath);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<Map<String, dynamic>> _transcribeViaCloud(StudioDraft draft) async {
    final response = await client.functions.invoke(
      'transcribe-audio',
      body: <String, dynamic>{'storagePath': draft.storagePath, 'bucket': 'studio-drafts'},
    );
    final data = response.data;
    if (data is! Map) {
      throw StateError('The transcription service returned an unexpected response.');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['error'] != null) throw StateError(map['error'].toString());
    return map;
  }

  Future<Map<String, dynamic>> _invokeAnalyze(Map<String, dynamic> body) async {
    final response = await client.functions.invoke('analyze-chords', body: body);
    final data = response.data;
    if (data is! Map) {
      throw StateError('The chord detection service returned an unexpected response.');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['error'] != null) throw StateError(map['error'].toString());
    return map;
  }

  /// Same start-then-poll protocol the project analysis path uses — see
  /// SongAnalysisService for why the Edge Function no longer waits on the
  /// separation job itself.
  Future<Map<String, dynamic>> _detectChordsViaCloud(
    StudioDraft draft, {
    required int durationMs,
    String? resumeJobId,
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    final request = <String, dynamic>{
      'draftId': draft.id,
      'storagePath': draft.storagePath,
      'bucket': 'studio-drafts',
      // See the note on the project path: older builds can't read a `start`
      // that comes back already finished.
      'acceptsCachedAnalysis': true,
      // See SongAnalysisService: for the usage log only.
      'durationMs': durationMs,
    };
    // A job this idea already started and never collected — rejoining costs
    // one poll, starting over costs another few minutes on a GPU.
    if (resumeJobId != null) {
      onProgress?.call(const SongAnalysisProgress('Picking up where this left off', 0.15));
      return _awaitDraftSeparation(request, resumeJobId, onProgress: onProgress);
    }

    final started = await _invokeAnalyze(<String, dynamic>{...request, 'action': 'start'});
    // Recognized from an earlier run — the idea you already analyzed, or the
    // same take sitting in a project. Finished before the first poll.
    if (started['status'] == 'complete') {
      onProgress?.call(reusedAnalysisProgress);
      return started;
    }
    final jobId = started['jobId'] as String?;
    if (jobId == null) {
      throw StateError('The separation service did not start a job.');
    }

    // Written down before the wait, so the app being killed doesn't strand a
    // job that is still running. See SongAnalysisService._rememberJob.
    await _rememberJob(draft.id, jobId);
    return _awaitDraftSeparation(request, jobId, onProgress: onProgress);
  }

  /// See SongAnalysisService._awaitSeparation: the GPU job doesn't care what
  /// the phone is doing, so a failed poll is a question to ask again rather
  /// than a failed analysis.
  Future<Map<String, dynamic>> _awaitDraftSeparation(
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
        rethrow;
      } catch (error) {
        if (!isConnectivityFailure(error)) rethrow;
        consecutiveFailures += 1;
        if (consecutiveFailures >= separationMaxConsecutiveFailures) rethrow;
      }
      onProgress?.call(separationProgress(elapsed));
    }
    // Not a failure — see SongAnalysisService. The job is still running and
    // the id is still on the row, so reopening the idea rejoins it.
    throw const AnalysisStillRunning(
      'This is taking longer than usual — the first analysis after a quiet '
      'spell has to wake the server up. It is still running: come back to this '
      'idea in a few minutes and it will carry on where it left off.',
    );
  }

  Future<StudioDraftBundle> analyze({
    required StudioDraft draft,
    required String localPath,
    /// A job this idea started and never collected — see resumableJobId.
    String? resumeJobId,
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    await client.from('studio_drafts').update(<String, dynamic>{
      'analysis_state': 'processing',
      'last_error': null,
    }).eq('id', draft.id);
    try {
      onProgress?.call(const SongAnalysisProgress('Preparing audio', 0.05));
      final info = await AudioDecoder.getAudioInfo(localPath);
      final durationMs = info.duration.inMilliseconds;

      // Same lyrics/chords independence as SongAnalysisService.analyze —
      // a lyrics failure of any kind should never block chord detection.
      String? warning;
      List<TranscriptWord> transcriptWords = const <TranscriptWord>[];
      String? transcriptText;
      try {
        onProgress?.call(const SongAnalysisProgress('Listening for the words', 0.2));
        final cloudResult = await _transcribeViaCloud(draft);
        final rawWords = (cloudResult['words'] as List<dynamic>? ?? const <dynamic>[])
            .map((value) => Map<String, dynamic>.from(value as Map))
            .where((row) => looksLikeSpeech((row['word'] as String? ?? '')))
            .toList(growable: false);
        if (rawWords.isEmpty) {
          final heard = (cloudResult['text'] as String? ?? '').trim();
          final heardSnippet = heard.isEmpty
              ? ''
              : ' Whisper heard: "${heard.length > 80 ? '${heard.substring(0, 80)}…' : heard}"';
          warning = heard.isNotEmpty && !looksLikeSpeech(heard)
              ? 'This recording sounds instrumental — chords were detected, but '
                  'there are no words to sync lyrics to.$heardSnippet'
              : 'Not enough sung words were heard to sync lyrics, but chords were still detected.'
                  '$heardSnippet';
        } else {
          onProgress?.call(const SongAnalysisProgress('Writing down the lyrics', 0.5));
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
      } catch (error) {
        warning = 'Could not transcribe this recording\'s speech, so only chords were '
            'detected. Details: $error';
        await _reporter.reportWarning(
          service: 'studio_analysis',
          stage: 'lyrics',
          message: 'Transcription failed: $error',
        );
      }

      onProgress?.call(const SongAnalysisProgress('Finding chord changes', 0.55));
      Map<String, dynamic> chordResult;
      var usedFallback = false;
      try {
        chordResult = await _detectChordsViaCloud(
          draft,
          durationMs: durationMs,
          resumeJobId: resumeJobId,
          onProgress: onProgress,
        );
      } catch (error) {
        // See SongAnalysisService: the on-device fallback is for the pipeline
        // being down, never for the phone being off the network. Substituting
        // it because a connection dropped silently loses the better analysis.
        if (isConnectivityFailure(error)) {
          throw StateError(
            'Lost the connection while analyzing this idea. Nothing was lost — '
            'try again once you have signal, and it will pick up much faster '
            'the second time.',
          );
        }
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
        final fallbackNote =
            'Cloud chord detection was unavailable, so a less accurate on-device fallback was used. Details: $error';
        warning = warning == null ? fallbackNote : '$warning\n\n$fallbackNote';
        // The Studio path was never instrumented, which is why the failure a
        // user hit here produced no telemetry at all and had to be reported
        // by screenshot.
        await _reporter.reportWarning(
          service: 'studio_analysis',
          stage: 'separation',
          message: 'Cloud chord detection unavailable, used on-device fallback: $error',
        );
      }

      onProgress?.call(const SongAnalysisProgress('Listening for the beat and structure', 0.75));
      // The on-device fallback only ever computes {cues, key} — bpm/structure/
      // instruments come exclusively from the cloud pipeline, so they're left
      // unavailable (shown as such in the UI) rather than guessed whenever the
      // fallback ran.
      final bpm = usedFallback ? null : (chordResult['bpm'] as num?)?.toDouble();
      // See SongAnalysisService: names you gave the parts outlive a
      // re-analysis.
      final structureSections = carryCustomSectionNames(
        draft.structureSections,
        usedFallback
            ? const <StructureSection>[]
            : (chordResult['structure'] as List<dynamic>? ?? const <dynamic>[])
                .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
                .toList(growable: false),
      );
      final instruments = usedFallback || chordResult['instruments'] is! Map
          ? null
          : InstrumentSummary.fromJson(Map<String, dynamic>.from(chordResult['instruments'] as Map));

      onProgress?.call(const SongAnalysisProgress('Saving song map', 0.9));
      await client.from('studio_chord_cues').delete().eq('draft_id', draft.id);
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
      // See SongAnalysisService: chord changes go on the beat grid before
      // they're stored, and the on-device fallback has no grid to go on.
      final beatsMs = usedFallback ? const <int>[] : _msList(chordResult['beatsMs']);
      final chordCues = snapChordsToBeatGrid(detectedCues, beatsMs);
      if (chordCues.isNotEmpty) {
        await client.from('studio_chord_cues').insert(
              chordCues
                  .map((cue) => <String, dynamic>{
                        'draft_id': draft.id,
                        'start_ms': cue.startMs,
                        'end_ms': cue.endMs,
                        'chord': cue.chord,
                        'confidence': cue.confidence,
                        'beat_index': beatIndexAt(cue.startMs, beatsMs),
                        'source': 'automatic',
                      })
                  .toList(growable: false),
            );
      }

      // See SongAnalysisService: averaging per-cue confidence produced a
      // constant, because every cue carries the same placeholder.
      final coverage = chordCoverage(chordCues, durationMs);

      // Name the idea after what's in it. A library of "Recording 8/23
      // 11:40" is the single most common reason captured ideas are never
      // revisited — you can't skim audio, so an un-named take is one you
      // have to play to identify, and eighty of them is a pile nobody digs
      // through. Only ever replaces a placeholder name, never one the
      // musician typed themselves.
      final suggestedName = nameFromTranscript(transcriptText);
      final rename = suggestedName != null && looksAutoNamed(draft.displayName);

      await client.from('studio_drafts').update(<String, dynamic>{
        'analysis_state': 'ready',
        if (rename) 'display_name': suggestedName,
        'duration_ms': durationMs,
        'bpm': bpm,
        'musical_key': chordResult['key'],
        'analyzer_version': 'colabroom-cloud-0.2',
        'chord_confidence': null,
        'chord_coverage': coverage,
        'beats_ms': usedFallback ? null : chordResult['beatsMs'],
        'downbeats_ms': usedFallback ? null : chordResult['downbeatsMs'],
        'beats_per_bar': usedFallback ? null : chordResult['beatsPerBar'],
        'transcript_text': transcriptText,
        'transcript_words': transcriptWords.map((word) => word.toJson()).toList(growable: false),
        'structure_sections': structureSections.map((s) => s.toJson()).toList(growable: false),
        'instruments': instruments?.toJson() ?? <String, dynamic>{},
        'analysis_warning': warning,
        'last_error': null,
      }).eq('id', draft.id);
      onProgress?.call(const SongAnalysisProgress('Ready', 1));
      // Awaited so a failure here is caught below and marks the draft
      // failed, instead of escaping while the row claims 'ready'.
      await _rememberJob(draft.id, null);
      return await load(draft.id);
    } on AnalysisStillRunning {
      // Still running, so it must not be recorded as failed and the job id
      // has to survive for the resume.
      rethrow;
    } catch (error) {
      await _rememberJob(draft.id, null);
      await client.from('studio_drafts').update(<String, dynamic>{
        'analysis_state': 'failed',
        'last_error': error.toString(),
      }).eq('id', draft.id);
      await _reporter.reportError(
        service: 'studio_analysis',
        message: error.toString(),
      );
      rethrow;
    }
  }

  /// "Create Song Project" — collects room+title via the existing, unmodified
  /// new-song flow, then copies the draft's analysis into that project.
  /// Returns null if the user cancelled room/title selection (not an error).
  Future<SongProject?> promoteToProject(
    BuildContext context,
    MusicBetaController controller,
    StudioDraft draft,
  ) async {
    final project = await showNewSongFlow(context, controller);
    if (project == null) return null;
    final bundle = await load(draft.id);
    await _writeAnalysisIntoProject(project: project, bundle: bundle);
    await client.from('studio_drafts').update(<String, dynamic>{
      'promoted_project_id': project.id,
    }).eq('id', draft.id);
    return project;
  }

  /// "Explain My Song" -> "Put that into my song" — same write path as
  /// [promoteToProject], targeting an existing project instead of a new one.
  Future<void> putIntoProject({
    required SongProject project,
    required StudioDraftBundle draftBundle,
  }) {
    return _writeAnalysisIntoProject(project: project, bundle: draftBundle);
  }

  Future<void> _writeAnalysisIntoProject({
    required SongProject project,
    required StudioDraftBundle bundle,
  }) async {
    final draft = bundle.draft;
    final ext = audioFileExtension(draft.storagePath);
    final bytes = await client.storage.from('studio-drafts').download(draft.storagePath);
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final storagePath = '${project.roomId}/${project.id}/analysis/reference_$timestamp.$ext';

    // putIntoProject can target a project that already has a reference
    // recording (attached via the normal Analyze flow, or a previous
    // Studio write) — note its old file/storage now so it can be cleaned
    // up after the new one lands, same as attachReference does. promoteToProject
    // never has one (the project was just created), so this is just empty there.
    final existingRefRows = await client
        .from('project_audio_references')
        .select('file_id')
        .eq('project_id', project.id)
        .limit(1);
    final oldFileId = (existingRefRows as List<dynamic>).isNotEmpty
        ? (Map<String, dynamic>.from(existingRefRows.first as Map))['file_id'] as String?
        : null;
    String? oldStoragePath;
    if (oldFileId != null) {
      final oldFileRow = await client
          .from('files')
          .select('storage_path')
          .eq('id', oldFileId)
          .maybeSingle();
      oldStoragePath = oldFileRow?['storage_path'] as String?;
    }

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
            'display_name': draft.displayName,
            'mime_type': mimeTypeForExtension(ext),
            'byte_size': draft.byteSize,
          })
          .select()
          .single();
      await client.from('project_audio_references').upsert(
        <String, dynamic>{
          'project_id': project.id,
          'file_id': fileRow['id'],
          'uploaded_by': client.auth.currentUser!.id,
          'analysis_state': draft.state.name,
          'duration_ms': draft.durationMs,
          'bpm': draft.bpm,
          'musical_key': draft.musicalKey,
          'analyzer_version': draft.analyzerVersion,
          'chord_confidence': draft.chordConfidence,
          'chord_coverage': draft.chordCoverage,
          'transcript_text': draft.transcriptText,
          'transcript_words': draft.transcriptWords.map((w) => w.toJson()).toList(growable: false),
          'structure_sections':
              draft.structureSections.map((s) => s.toJson()).toList(growable: false),
          'instruments': draft.instruments?.toJson() ?? <String, dynamic>{},
          'analysis_warning': draft.analysisWarning,
          'last_error': null,
        },
        onConflict: 'project_id',
      );
      await client.from('lyric_sync_cues').delete().eq('project_id', project.id);
      await client.from('chord_cues').delete().eq('project_id', project.id);
      if (bundle.chordCues.isNotEmpty) {
        await client.from('chord_cues').insert(
              bundle.chordCues
                  .map((cue) => <String, dynamic>{
                        'project_id': project.id,
                        'start_ms': cue.startMs,
                        'end_ms': cue.endMs,
                        'chord': cue.chord,
                        'confidence': cue.confidence,
                        'source': cue.source,
                      })
                  .toList(growable: false),
            );
      }
    } catch (_) {
      if (fileRow != null) {
        await client.from('files').delete().eq('id', fileRow['id'] as Object);
      }
      await client.storage.from('room-files').remove(<String>[storagePath]);
      rethrow;
    }

    if (oldFileId != null && oldFileId != fileRow['id']) {
      try {
        if (oldStoragePath != null) {
          await client.storage.from('room-files').remove(<String>[oldStoragePath]);
        }
        await client.from('files').delete().eq('id', oldFileId);
      } catch (_) {
        // The new reference is already valid. Old-file cleanup can be retried later.
      }
    }
  }

  StudioDraft _draftFromRow(Map<String, dynamic> row) {
    return StudioDraft(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      displayName: row['display_name'] as String,
      storagePath: row['storage_path'] as String,
      state: SongAnalysisState.values.byName(row['analysis_state'] as String? ?? 'uploaded'),
      createdAt: DateTime.parse(row['created_at'] as String),
      mimeType: row['mime_type'] as String?,
      byteSize: (row['byte_size'] as num?)?.toInt(),
      durationMs: (row['duration_ms'] as num?)?.toInt(),
      bpm: (row['bpm'] as num?)?.toDouble(),
      musicalKey: row['musical_key'] as String?,
      analyzerVersion: row['analyzer_version'] as String?,
      chordConfidence: (row['chord_confidence'] as num?)?.toDouble(),
      chordCoverage: (row['chord_coverage'] as num?)?.toDouble(),
      beatsMs: _msList(row['beats_ms']),
      downbeatsMs: _msList(row['downbeats_ms']),
      beatsPerBar: (row['beats_per_bar'] as num?)?.toInt(),
      transcriptText: row['transcript_text'] as String?,
      transcriptWords: (row['transcript_words'] as List<dynamic>? ?? const <dynamic>[])
          .map((value) => TranscriptWord.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList(growable: false),
      structureSections: (row['structure_sections'] as List<dynamic>? ?? const <dynamic>[])
          .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList(growable: false),
      instruments: row['instruments'] is Map
          ? InstrumentSummary.fromJson(Map<String, dynamic>.from(row['instruments'] as Map))
          : null,
      analysisWarning: row['analysis_warning'] as String?,
      lastError: row['last_error'] as String?,
      promotedProjectId: row['promoted_project_id'] as String?,
    );
  }
}
