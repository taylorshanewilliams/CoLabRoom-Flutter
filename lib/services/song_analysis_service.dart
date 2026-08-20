import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:fftea/fftea.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/music_models.dart';
import '../domain/song_analysis_models.dart';

class SongAnalysisProgress {
  const SongAnalysisProgress(this.label, this.fraction);

  final String label;
  final double fraction;
}

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
    final ext = _extension(localPath);
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final storagePath = '${project.roomId}/${project.id}/analysis/reference_$timestamp.$ext';
    final bytes = await file.readAsBytes();
    await client.storage.from('room-files').uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(contentType: _mimeFor(ext), upsert: false),
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
            'mime_type': _mimeFor(ext),
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
    final ext = _extension(reference.storagePath);
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

  /// Groups a saved transcript's words back into line-sized chunks by pause
  /// gaps, for the explicit "Replace project lyrics with this" action —
  /// mirrors the grouping heuristic used when generating the song sheet in
  /// the first place. Pure/no DB access; the caller is responsible for
  /// actually writing these as Contributions (via MusicBetaController, so
  /// existing lines get cleaned up correctly, voice notes included).
  List<String> transcriptLyricLines(ReferenceTrack reference) {
    final words = reference.transcriptWords;
    if (words.isEmpty) return const <String>[];
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
    return lines
        .map((line) => line.map((word) => word.word).join(' ').trim())
        .where((body) => body.isNotEmpty)
        .toList(growable: false);
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
            .where((row) => _looksLikeSpeech((row['word'] as String? ?? '')))
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
          if (heard.isNotEmpty && !_looksLikeSpeech(heard)) {
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
      final rawPcm = await AudioDecoder.convertToWavBytes(
        await File(localPath).readAsBytes(),
        formatHint: _extension(localPath),
        sampleRate: 11025,
        channels: 1,
        bitDepth: 16,
        includeHeader: false,
      );
      final chordResult = await compute(_analyzeChords, <String, dynamic>{
        'pcm': rawPcm,
        'sampleRate': 11025,
        'durationMs': durationMs,
      });

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
      await client
          .from('project_audio_references')
          .update(<String, dynamic>{
            'analysis_state': 'ready',
            'duration_ms': durationMs,
            'musical_key': chordResult['key'],
            'analyzer_version': 'colabroom-cloud-0.1',
            // No longer a meaningful "match against existing text" score
            // now that lyrics are always transcribed fresh rather than
            // aligned to something else — nothing to compare against.
            'lyric_confidence': null,
            'chord_confidence': chordConfidence,
            'transcript_text': transcriptText,
            'transcript_words': transcriptWords.map((word) => word.toJson()).toList(growable: false),
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

/// True if [text] contains a letter/digit outside of Whisper's non-speech
/// placeholder markers (bracketed annotations like "[Music]"/"(applause)",
/// and musical note glyphs like "♪♪♪") — those show up instead of real
/// words when a recording is purely instrumental, and shouldn't be
/// mistaken for lost/garbled speech.
bool _looksLikeSpeech(String text) {
  final cleaned = text
      .replaceAll(RegExp(r'[\[(][^\])]*[\])]'), '')
      .replaceAll(RegExp(r'[♩-♯]'), '')
      .trim();
  return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(cleaned);
}

Map<String, dynamic> _analyzeChords(Map<String, dynamic> input) {
  final pcm = input['pcm'] as Uint8List;
  final sampleRate = input['sampleRate'] as int;
  final durationMs = input['durationMs'] as int;
  final data = ByteData.sublistView(pcm);
  final samples = Float64List(pcm.length ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
  }

  const frameSize = 4096;
  const hop = 2048;
  final fft = FFT(frameSize);
  final window = Window.hanning(frameSize);

  // Pass 1: extract a chroma vector per frame, and accumulate a song-wide
  // chroma profile for key detection alongside it.
  final frames = <_ChromaFrame>[];
  final globalChroma = List<double>.filled(12, 0);
  for (var start = 0; start + frameSize <= samples.length; start += hop) {
    final frame = List<double>.filled(frameSize, 0);
    var rms = 0.0;
    for (var i = 0; i < frameSize; i++) {
      final sample = samples[start + i];
      rms += sample * sample;
      frame[i] = sample * window[i];
    }
    rms = math.sqrt(rms / frameSize);
    if (rms < 0.008) continue;
    final magnitudes = fft.realFft(frame).discardConjugates().magnitudes();
    final chroma = List<double>.filled(12, 0);
    for (var bin = 1; bin < magnitudes.length; bin++) {
      final frequency = bin * sampleRate / frameSize;
      if (frequency < 65 || frequency > 2100) continue;
      final midi = (69 + 12 * math.log(frequency / 440) / math.ln2).round();
      final pc = ((midi % 12) + 12) % 12;
      chroma[pc] += math.sqrt(magnitudes[bin]);
    }
    final norm = math.sqrt(chroma.fold<double>(0, (sum, value) => sum + value * value));
    if (norm <= 0) continue;
    for (var i = 0; i < 12; i++) {
      chroma[i] /= norm;
      globalChroma[i] += chroma[i];
    }
    final startMs = (start * 1000 / sampleRate).round();
    final endMs = math.min(durationMs, ((start + hop) * 1000 / sampleRate).round());
    frames.add(_ChromaFrame(startMs: startMs, endMs: endMs, chroma: chroma));
  }

  if (frames.isEmpty) {
    return <String, dynamic>{'cues': <Map<String, dynamic>>[], 'key': null};
  }

  final key = _detectKey(globalChroma);

  // Pass 2: score every chord candidate (now a full major/minor/7th/sus/
  // dim/aug vocabulary, key-biased toward chords diatonic to the detected
  // key) per frame, then decode the most consistent chord sequence with a
  // lightweight Viterbi pass instead of picking each frame's raw best
  // match in isolation — a self-transition bonus/switch penalty replaces
  // the old single-outlier-flip smoothing with something that actually
  // models "chords don't flicker frame to frame."
  const beamWidth = 3;
  final beams = frames.map((f) => _topChords(f.chroma, key, beamWidth)).toList(growable: false);
  final path = _decodeChordPath(beams);

  final raw = <Map<String, dynamic>>[];
  for (var i = 0; i < frames.length; i++) {
    raw.add(<String, dynamic>{
      'startMs': frames[i].startMs,
      'endMs': frames[i].endMs,
      'chord': path[i].$1,
      'confidence': path[i].$2,
    });
  }

  final merged = <Map<String, dynamic>>[];
  for (final cue in raw) {
    if ((cue['confidence'] as double) < 0.12) continue;
    if (merged.isNotEmpty &&
        merged.last['chord'] == cue['chord'] &&
        (cue['startMs'] as int) - (merged.last['endMs'] as int) < 700) {
      final oldConfidence = merged.last['confidence'] as double;
      merged.last['endMs'] = cue['endMs'];
      merged.last['confidence'] = (oldConfidence + cue['confidence'] as double) / 2;
    } else {
      merged.add(Map<String, dynamic>.from(cue));
    }
  }

  return <String, dynamic>{'cues': merged, 'key': key.label};
}

class _ChromaFrame {
  const _ChromaFrame({required this.startMs, required this.endMs, required this.chroma});

  final int startMs;
  final int endMs;
  final List<double> chroma;
}

class _KeyEstimate {
  const _KeyEstimate(this.root, this.minor, this.label);

  final int root;
  final bool minor;
  final String label;
}

// Krumhansl & Kessler (1982) key profiles — how strongly each pitch class
// "belongs" to a major/minor key, used to correlate against a song's
// overall chroma profile and pick the most likely key.
const _majorKeyProfile = <double>[6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const _minorKeyProfile = <double>[6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

_KeyEstimate _detectKey(List<double> globalChroma) {
  const names = <String>['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  var bestScore = double.negativeInfinity;
  var bestRoot = 0;
  var bestMinor = false;
  for (var root = 0; root < 12; root++) {
    for (final minor in <bool>[false, true]) {
      final profile = minor ? _minorKeyProfile : _majorKeyProfile;
      final rotated = List<double>.generate(12, (i) => profile[(i - root + 12) % 12]);
      final score = _pearson(globalChroma, rotated);
      if (score > bestScore) {
        bestScore = score;
        bestRoot = root;
        bestMinor = minor;
      }
    }
  }
  return _KeyEstimate(bestRoot, bestMinor, '${names[bestRoot]}${bestMinor ? 'm' : ''}');
}

double _pearson(List<double> a, List<double> b) {
  final meanA = a.reduce((x, y) => x + y) / a.length;
  final meanB = b.reduce((x, y) => x + y) / b.length;
  var numerator = 0.0, denomA = 0.0, denomB = 0.0;
  for (var i = 0; i < a.length; i++) {
    final da = a[i] - meanA;
    final db = b[i] - meanB;
    numerator += da * db;
    denomA += da * da;
    denomB += db * db;
  }
  final denom = math.sqrt(denomA * denomB);
  return denom == 0 ? 0 : numerator / denom;
}

Set<int> _diatonicPitchClasses(_KeyEstimate key) {
  const majorScale = <int>[0, 2, 4, 5, 7, 9, 11];
  const minorScale = <int>[0, 2, 3, 5, 7, 8, 10];
  final scale = key.minor ? minorScale : majorScale;
  return scale.map((interval) => (key.root + interval) % 12).toSet();
}

class _ChordQuality {
  const _ChordQuality(this.suffix, this.intervals, this.weights);

  final String suffix;
  final List<int> intervals;
  final List<double> weights;
}

// Weights follow the original root/third/fifth balance (1.0/0.78/0.86);
// 7ths get a lighter weight than the triad tones they're added to, so a
// faint 7th doesn't outvote a clear underlying major/minor triad.
final _chordQualities = <_ChordQuality>[
  _ChordQuality('', <int>[0, 4, 7], <double>[1.0, 0.78, 0.86]),
  _ChordQuality('m', <int>[0, 3, 7], <double>[1.0, 0.78, 0.86]),
  _ChordQuality('7', <int>[0, 4, 7, 10], <double>[1.0, 0.7, 0.78, 0.5]),
  _ChordQuality('maj7', <int>[0, 4, 7, 11], <double>[1.0, 0.7, 0.78, 0.45]),
  _ChordQuality('m7', <int>[0, 3, 7, 10], <double>[1.0, 0.7, 0.78, 0.5]),
  _ChordQuality('sus2', <int>[0, 2, 7], <double>[1.0, 0.72, 0.86]),
  _ChordQuality('sus4', <int>[0, 5, 7], <double>[1.0, 0.72, 0.86]),
  _ChordQuality('dim', <int>[0, 3, 6], <double>[1.0, 0.78, 0.7]),
  _ChordQuality('aug', <int>[0, 4, 8], <double>[1.0, 0.78, 0.7]),
];

// Original triad weight sum (1.0 + 0.78 + 0.86) — every candidate's
// average matched-energy score is rescaled back onto this reference so a
// 4-note 7th chord isn't unfairly favored over a 3-note triad just for
// having more terms in its raw sum, while keeping scores numerically
// compatible with the confidence formula below (tuned against this scale).
const _referenceWeightSum = 2.64;

List<(String, double)> _topChords(List<double> chroma, _KeyEstimate key, int count) {
  const names = <String>['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  final diatonic = _diatonicPitchClasses(key);
  final scored = <(String, double)>[];
  for (var root = 0; root < 12; root++) {
    for (final quality in _chordQualities) {
      var weighted = 0.0;
      var weightSum = 0.0;
      for (var i = 0; i < quality.intervals.length; i++) {
        final pc = (root + quality.intervals[i]) % 12;
        weighted += chroma[pc] * quality.weights[i];
        weightSum += quality.weights[i];
      }
      var score = (weighted / weightSum) * _referenceWeightSum;
      if (diatonic.contains(root)) score += 0.05;
      scored.add(('${names[root]}${quality.suffix}', score));
    }
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return scored.take(count).toList(growable: false);
}

/// Lightweight Viterbi decode: picks the highest-scoring path through each
/// frame's top chord candidates, biased by a self-transition bonus so a
/// chord that was already winning tends to keep winning against a
/// marginally-better one-frame blip, rather than flickering.
List<(String, double)> _decodeChordPath(List<List<(String, double)>> beams) {
  if (beams.isEmpty) return const <(String, double)>[];
  const selfBonus = 0.12;
  const switchPenalty = 0.12;
  final dp = List<List<double>>.generate(beams.length, (i) => List<double>.filled(beams[i].length, 0));
  final back = List<List<int>>.generate(beams.length, (i) => List<int>.filled(beams[i].length, -1));
  for (var k = 0; k < beams[0].length; k++) {
    dp[0][k] = beams[0][k].$2;
  }
  for (var i = 1; i < beams.length; i++) {
    for (var k = 0; k < beams[i].length; k++) {
      var bestPrev = double.negativeInfinity;
      var bestJ = 0;
      for (var j = 0; j < beams[i - 1].length; j++) {
        final transition = beams[i - 1][j].$1 == beams[i][k].$1 ? selfBonus : -switchPenalty;
        final value = dp[i - 1][j] + transition;
        if (value > bestPrev) {
          bestPrev = value;
          bestJ = j;
        }
      }
      dp[i][k] = beams[i][k].$2 + bestPrev;
      back[i][k] = bestJ;
    }
  }
  var lastBest = 0;
  var lastScore = double.negativeInfinity;
  for (var k = 0; k < beams.last.length; k++) {
    if (dp.last[k] > lastScore) {
      lastScore = dp.last[k];
      lastBest = k;
    }
  }
  final path = List<int>.filled(beams.length, 0);
  path[beams.length - 1] = lastBest;
  for (var i = beams.length - 1; i > 0; i--) {
    path[i - 1] = back[i][path[i]];
  }

  final result = <(String, double)>[];
  for (var i = 0; i < beams.length; i++) {
    final chosen = beams[i][path[i]];
    final top = beams[i][0].$2;
    final second = beams[i].length > 1 ? beams[i][1].$2 : 0.0;
    final margin = math.max(0.0, top - second);
    final confidence = (margin * 2.6 + (chosen.$2 - 0.65) * 0.22).clamp(0.05, 0.92).toDouble();
    result.add((chosen.$1, confidence));
  }
  return result;
}

String _extension(String path) {
  final clean = path.split('?').first;
  final dot = clean.lastIndexOf('.');
  if (dot < 0 || dot == clean.length - 1) return 'mp3';
  return clean.substring(dot + 1).toLowerCase();
}

String _mimeFor(String ext) => switch (ext) {
      'wav' => 'audio/wav',
      'm4a' || 'mp4' => 'audio/mp4',
      'flac' => 'audio/flac',
      'ogg' || 'oga' || 'opus' => 'audio/ogg',
      _ => 'audio/mpeg',
    };
