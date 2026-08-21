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

/// The Studio's pre-project counterpart to [SongAnalysisService] — same
/// analysis pipeline (same Edge Functions, same on-device fallback), but
/// keyed by an account-scoped draft instead of an existing project, since a
/// draft has no room/project to hang off yet. See studio_draft_models.dart
/// and supabase/migrations/0017_studio_drafts.sql for the parallel schema.
class StudioDraftService {
  StudioDraftService({SupabaseClient? client}) : client = client ?? Supabase.instance.client;

  final SupabaseClient client;

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
    return StudioDraftBundle(
      draft: _draftFromRow(Map<String, dynamic>.from(row)),
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

  Future<Map<String, dynamic>> _detectChordsViaCloud(StudioDraft draft) async {
    final response = await client.functions.invoke(
      'analyze-chords',
      body: <String, dynamic>{'storagePath': draft.storagePath, 'bucket': 'studio-drafts'},
    );
    final data = response.data;
    if (data is! Map) {
      throw StateError('The chord detection service returned an unexpected response.');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['error'] != null) throw StateError(map['error'].toString());
    return map;
  }

  Future<StudioDraftBundle> analyze({
    required StudioDraft draft,
    required String localPath,
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
      }

      onProgress?.call(const SongAnalysisProgress('Finding chord changes', 0.55));
      Map<String, dynamic> chordResult;
      var usedFallback = false;
      try {
        chordResult = await _detectChordsViaCloud(draft);
      } catch (error) {
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
      }

      onProgress?.call(const SongAnalysisProgress('Listening for the beat and structure', 0.75));
      // The on-device fallback only ever computes {cues, key} — bpm/structure/
      // instruments come exclusively from the cloud pipeline, so they're left
      // unavailable (shown as such in the UI) rather than guessed whenever the
      // fallback ran.
      final bpm = usedFallback ? null : (chordResult['bpm'] as num?)?.toDouble();
      final structureSections = usedFallback
          ? const <StructureSection>[]
          : (chordResult['structure'] as List<dynamic>? ?? const <dynamic>[])
              .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
              .toList(growable: false);
      final instruments = usedFallback || chordResult['instruments'] is! Map
          ? null
          : InstrumentSummary.fromJson(Map<String, dynamic>.from(chordResult['instruments'] as Map));

      onProgress?.call(const SongAnalysisProgress('Saving song map', 0.9));
      await client.from('studio_chord_cues').delete().eq('draft_id', draft.id);
      final chordCues = (chordResult['cues'] as List<dynamic>)
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
      if (chordCues.isNotEmpty) {
        await client.from('studio_chord_cues').insert(
              chordCues
                  .asMap()
                  .entries
                  .map((entry) => <String, dynamic>{
                        'draft_id': draft.id,
                        'start_ms': entry.value.startMs,
                        'end_ms': entry.value.endMs,
                        'chord': entry.value.chord,
                        'confidence': entry.value.confidence,
                        'beat_index': entry.key,
                        'source': 'automatic',
                      })
                  .toList(growable: false),
            );
      }

      final chordConfidence = chordCues.isEmpty
          ? 0.0
          : chordCues.map((cue) => cue.confidence).reduce((a, b) => a + b) / chordCues.length;
      await client.from('studio_drafts').update(<String, dynamic>{
        'analysis_state': 'ready',
        'duration_ms': durationMs,
        'bpm': bpm,
        'musical_key': chordResult['key'],
        'analyzer_version': 'colabroom-cloud-0.1',
        'chord_confidence': chordConfidence,
        'transcript_text': transcriptText,
        'transcript_words': transcriptWords.map((word) => word.toJson()).toList(growable: false),
        'structure_sections': structureSections.map((s) => s.toJson()).toList(growable: false),
        'instruments': instruments?.toJson() ?? <String, dynamic>{},
        'analysis_warning': warning,
        'last_error': null,
      }).eq('id', draft.id);
      onProgress?.call(const SongAnalysisProgress('Ready', 1));
      return load(draft.id);
    } catch (error) {
      await client.from('studio_drafts').update(<String, dynamic>{
        'analysis_state': 'failed',
        'last_error': error.toString(),
      }).eq('id', draft.id);
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
      if (fileRow != null) await client.from('files').delete().eq('id', fileRow['id']);
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
