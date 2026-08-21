import 'dart:io';
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/music_models.dart';
import '../domain/song_analysis_models.dart';
import 'audio_analysis_utils.dart';

export 'audio_analysis_utils.dart' show SongAnalysisProgress;

class SongAnalysisService {
  SongAnalysisService({SupabaseClient? client}) : client = client ?? Supabase.instance.client;

  final SupabaseClient client;

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
      );
    }

    final lyricRows = await client
        .from('lyric_sync_cues')
        .select('contribution_id, start_ms, end_ms, confidence')
        .eq('project_id', projectId)
        .order('start_ms');
    final chordRows = await client
        .from('chord_cues')
        .select('start_ms, end_ms, chord, confidence')
        .eq('project_id', projectId)
        .order('start_ms');

    return SongAnalysisBundle(
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
      throw StateError('For this beta, use a reference recording smaller than 80 MB.');
    }

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
    } catch (_) {
      if (fileRow != null) await client.from('files').delete().eq('id', fileRow['id']);
      await client.storage.from('room-files').remove(<String>[storagePath]);
      rethrow;
    }

    final old = previous.reference;
    if (old != null && old.fileId != fileRow['id']) {
      try {
        await client.storage.from('room-files').remove(<String>[old.storagePath]);
        await client.from('files').delete().eq('id', old.fileId);
      } catch (_) {
        // The new reference is already valid. Old-file cleanup can be retried later.
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

  Future<String> ensureLocalReference(ReferenceTrack reference) async {
    if (kIsWeb) throw UnsupportedError('Reference download is not available on web yet.');
    final directory = await getTemporaryDirectory();
    final ext = audioFileExtension(reference.storagePath);
    final path = '${directory.path}/colabroom_reference_${reference.fileId}.$ext';
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    final bytes = await client.storage.from('room-files').download(reference.storagePath);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<Uint8List> downloadReferenceBytes(ReferenceTrack reference) {
    return client.storage.from('room-files').download(reference.storagePath);
  }

  /// Groups a transcript's words back into line-sized chunks by pause gaps —
  /// shared by the explicit "Replace project lyrics with this" action and
  /// the lyric review screen. Pure/no DB access.
  List<List<TranscriptWord>> groupTranscriptWords(List<TranscriptWord> words) {
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

  /// Text form of [groupTranscriptWords], for the explicit "Replace project
  /// lyrics with this" action — the caller is responsible for actually
  /// writing these as Contributions (via MusicBetaController, so existing
  /// lines get cleaned up correctly, voice notes included).
  List<String> transcriptLyricLines(ReferenceTrack reference) {
    return groupTranscriptWords(reference.transcriptWords)
        .map((line) => line.map((word) => word.word).join(' ').trim())
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

  /// Calls the `transcribe-audio` Supabase Edge Function, which forwards
  /// [reference]'s already-uploaded recording to OpenAI's Whisper API and
  /// returns word-level timestamps. The OpenAI API key lives only in that
  /// function's server-side secrets — never in the app — so this is a
  /// network call, not a local model.
  Future<Map<String, dynamic>> _transcribeViaCloud(ReferenceTrack reference) async {
    final response = await client.functions.invoke(
      'transcribe-audio',
      body: <String, dynamic>{
        'storagePath': reference.storagePath,
        'bucket': 'room-files',
      },
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
  Future<Map<String, dynamic>> _detectChordsViaCloud(ReferenceTrack reference) async {
    final response = await client.functions.invoke(
      'analyze-chords',
      body: <String, dynamic>{
        'storagePath': reference.storagePath,
        'bucket': 'room-files',
      },
    );
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

  Future<SongAnalysisBundle> analyze({
    required SongProject project,
    required ReferenceTrack reference,
    required String localPath,
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    await _setState(project.id, SongAnalysisState.processing);
    try {
      onProgress?.call(const SongAnalysisProgress('Preparing audio', 0.05));
      final info = await AudioDecoder.getAudioInfo(localPath);
      final durationMs = info.duration.inMilliseconds;

      // Chords don't need singing at all (they come from the raw audio via
      // FFT/chroma, independent of speech), so a lyrics/transcription
      // failure of any kind — instrumental audio, empty transcription, the
      // transcription request itself failing — should never block chord
      // detection. Every failure mode below sets lyricsWarning and falls
      // through to chord analysis instead of throwing, surfaced as a
      // non-fatal analysis_warning rather than a hard error.
      String? lyricsWarning;
      List<TranscriptWord> transcriptWords = const <TranscriptWord>[];
      String? transcriptText;
      try {
        onProgress?.call(const SongAnalysisProgress('Listening for the words', 0.2));
        final cloudResult = await _transcribeViaCloud(reference);
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
          if (heard.isNotEmpty && !looksLikeSpeech(heard)) {
            lyricsWarning = 'This recording sounds instrumental — chords were detected, but '
                'there are no words to sync lyrics to.$heardSnippet';
          } else {
            lyricsWarning =
                'Not enough sung words were heard to sync lyrics, but chords were still detected.'
                '$heardSnippet';
          }
        } else {
          onProgress?.call(const SongAnalysisProgress('Writing down the lyrics', 0.5));
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
      } catch (error) {
        lyricsWarning = 'Could not transcribe this recording\'s speech, so only chords were '
            'detected. Details: $error';
      }

      onProgress?.call(const SongAnalysisProgress('Finding chord changes', 0.62));
      Map<String, dynamic> chordResult;
      var usedFallback = false;
      try {
        chordResult = await _detectChordsViaCloud(reference);
      } catch (error) {
        // Same resilience shape as the lyrics path above — an outage in
        // the new Demucs/ChordMini pipeline shouldn't turn "no chords
        // this time" into "no analysis at all". Falls back to the
        // on-device heuristic, which is worse but still functional.
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
        lyricsWarning = lyricsWarning == null ? fallbackNote : '$lyricsWarning\n\n$fallbackNote';
      }

      onProgress?.call(const SongAnalysisProgress('Saving song map', 0.9));
      // lyric_sync_cues is no longer written to — it existed to key timing
      // off a Contribution row, which analysis-generated lyrics never have.
      // Still clearing it so a project analyzed under the old aligned-mode
      // doesn't keep stale, now-orphaned cues around.
      await client.from('lyric_sync_cues').delete().eq('project_id', project.id);
      await client.from('chord_cues').delete().eq('project_id', project.id);
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
        await client.from('chord_cues').insert(
              chordCues
                  .asMap()
                  .entries
                  .map((entry) => <String, dynamic>{
                        'project_id': project.id,
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
      // The on-device fallback only ever computes {cues, key} — bpm/structure/
      // instruments come exclusively from the cloud pipeline, so they're left
      // unavailable rather than guessed whenever the fallback ran.
      final bpm = usedFallback ? null : (chordResult['bpm'] as num?)?.toDouble();
      final structureSections = usedFallback
          ? const <StructureSection>[]
          : (chordResult['structure'] as List<dynamic>? ?? const <dynamic>[])
              .map((value) => StructureSection.fromJson(Map<String, dynamic>.from(value as Map)))
              .toList(growable: false);
      final instruments = usedFallback || chordResult['instruments'] is! Map
          ? null
          : InstrumentSummary.fromJson(Map<String, dynamic>.from(chordResult['instruments'] as Map));
      await client
          .from('project_audio_references')
          .update(<String, dynamic>{
            'analysis_state': 'ready',
            'duration_ms': durationMs,
            'bpm': bpm,
            'musical_key': chordResult['key'],
            'analyzer_version': 'colabroom-cloud-0.1',
            // No longer a meaningful "match against existing text" score
            // now that lyrics are always transcribed fresh rather than
            // aligned to something else — nothing to compare against.
            'lyric_confidence': null,
            'chord_confidence': chordConfidence,
            'transcript_text': transcriptText,
            'transcript_words': transcriptWords.map((word) => word.toJson()).toList(growable: false),
            'structure_sections': structureSections.map((s) => s.toJson()).toList(growable: false),
            'instruments': instruments?.toJson() ?? <String, dynamic>{},
            'analysis_warning': lyricsWarning,
            'last_error': null,
          })
          .eq('project_id', project.id);
      onProgress?.call(const SongAnalysisProgress('Ready', 1));
      return load(project.id);
    } catch (error) {
      await client
          .from('project_audio_references')
          .update(<String, dynamic>{
            'analysis_state': 'failed',
            'last_error': error.toString(),
          })
          .eq('project_id', project.id);
      rethrow;
    }
  }

  Future<void> _setState(String projectId, SongAnalysisState state) async {
    await client
        .from('project_audio_references')
        .update(<String, dynamic>{'analysis_state': state.name, 'last_error': null})
        .eq('project_id', projectId);
  }
}
