import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:fftea/fftea.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

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

  Future<SongAnalysisBundle> analyze({
    required SongProject project,
    required ReferenceTrack reference,
    required String localPath,
    ValueChanged<SongAnalysisProgress>? onProgress,
  }) async {
    if (project.contributions.where((line) => _visibleLine(line)).isEmpty) {
      throw StateError('Add some lyrics before syncing a reference recording.');
    }
    await _setState(project.id, SongAnalysisState.processing);
    try {
      onProgress?.call(const SongAnalysisProgress('Preparing audio', 0.05));
      final info = await AudioDecoder.getAudioInfo(localPath);
      final durationMs = info.duration.inMilliseconds;

      final whisper = WhisperController();

      onProgress?.call(const SongAnalysisProgress('Downloading speech model', 0.13));
      try {
        await whisper.downloadModel(WhisperModel.tinyEn);
      } catch (error) {
        throw StateError(
          'Could not download the on-device speech model. Check your internet '
          'connection and try again. Details: $error',
        );
      }

      onProgress?.call(const SongAnalysisProgress('Loading speech model', 0.16));
      try {
        await whisper.initModel(WhisperModel.tinyEn);
      } catch (error) {
        throw StateError(
          'The on-device speech model downloaded but failed to load on this '
          'device. Details: $error',
        );
      }

      onProgress?.call(const SongAnalysisProgress('Listening for the words', 0.2));
      final prompt = project.contributions
          .where(_visibleLine)
          .map((line) => line.body.replaceAll('\u200B', ''))
          .join(' ');
      dynamic result;
      try {
        result = await whisper.transcribe(
          model: WhisperModel.tinyEn,
          audioPath: localPath,
          lang: 'en',
          withSegments: true,
          splitOnWord: true,
          suppressNonSpeechTokens: true,
          initialPrompt: prompt.length > 1800 ? prompt.substring(0, 1800) : prompt,
          onProgress: (percent) {
            onProgress?.call(SongAnalysisProgress(
              'Listening for the words',
              0.2 + (percent.clamp(0, 100) / 100) * 0.3,
            ));
          },
        );
      } catch (error) {
        throw StateError('Transcription failed while listening to the recording. Details: $error');
      }
      await whisper.releaseModel();
      if (result == null) {
        // The engine completed without throwing but still returned nothing
        // — distinct from "transcribed but heard no words" (handled below).
        throw StateError(
          'The speech model finished processing but returned no result for this recording.',
        );
      }
      final words = _transcribedWords(result);
      if (words.isEmpty) {
        // If Whisper actually produced text but our segment-based extraction
        // found nothing, that's a parsing bug on our side, not a "couldn't
        // hear you" situation — surface that distinction instead of masking
        // it with the generic message.
        final dynamic wholeText = result.transcription?.text;
        if (wholeText is String && wholeText.trim().isNotEmpty) {
          throw StateError(
            'Heard "${wholeText.trim()}" but could not extract word timings from it '
            '(a bug in ColabRoom, not your recording).',
          );
        }
        throw StateError('I could not hear enough sung words to sync these lyrics.');
      }

      onProgress?.call(const SongAnalysisProgress('Matching lyrics to the performance', 0.54));
      final lyricResult = _alignLyrics(project, words, durationMs);

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
      await client.from('lyric_sync_cues').delete().eq('project_id', project.id);
      await client.from('chord_cues').delete().eq('project_id', project.id);
      if (lyricResult.cues.isNotEmpty) {
        await client.from('lyric_sync_cues').insert(
              lyricResult.cues
                  .map((cue) => <String, dynamic>{
                        'contribution_id': cue.contributionId,
                        'project_id': project.id,
                        'start_ms': cue.startMs,
                        'end_ms': cue.endMs,
                        'confidence': cue.confidence,
                        'source': 'automatic',
                      })
                  .toList(growable: false),
            );
      }
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
            'analyzer_version': 'colabroom-device-0.1',
            'lyric_confidence': lyricResult.confidence,
            'chord_confidence': chordConfidence,
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

  static bool _visibleLine(Contribution line) {
    final body = line.body.replaceAll('\u200B', '').trim();
    if (body.isEmpty) return false;
    if (line.kind == ContributionKind.section) return false;
    return !RegExp(r'^\s*\[[^\]]+\]\s*$').hasMatch(body);
  }
}

class _TimedWord {
  const _TimedWord(this.word, this.startMs, this.endMs);

  final String word;
  final int startMs;
  final int endMs;
}

List<_TimedWord> _transcribedWords(dynamic result) {
  final dynamic transcription = result?.transcription;
  final dynamic rawSegments = transcription?.segments;
  if (rawSegments == null) return const <_TimedWord>[];
  final words = <_TimedWord>[];
  for (final dynamic segment in rawSegments as Iterable<dynamic>) {
    final token = _normalizeToken(segment.text?.toString() ?? '');
    if (token.isEmpty) continue;
    final dynamic from = segment.fromTs;
    final dynamic to = segment.toTs;
    final int start = from is Duration ? from.inMilliseconds : 0;
    final int end = to is Duration ? to.inMilliseconds : start + 300;
    words.add(_TimedWord(token, start, math.max(start + 40, end)));
  }
  return words;
}

class _LyricAlignmentResult {
  const _LyricAlignmentResult(this.cues, this.confidence);

  final List<LyricSyncCue> cues;
  final double confidence;
}

_LyricAlignmentResult _alignLyrics(
  SongProject project,
  List<_TimedWord> transcript,
  int durationMs,
) {
  final canonical = <String>[];
  final lineForToken = <String>[];
  final tokenCountByLine = <String, int>{};
  for (final line in project.contributions) {
    if (!SongAnalysisService._visibleLine(line)) continue;
    final tokens = _tokenize(line.body);
    tokenCountByLine[line.id] = tokens.length;
    for (final token in tokens) {
      canonical.add(token);
      lineForToken.add(line.id);
    }
  }
  if (canonical.isEmpty || transcript.isEmpty) {
    return const _LyricAlignmentResult(<LyricSyncCue>[], 0);
  }

  final n = canonical.length;
  final m = transcript.length;
  final score = List<List<double>>.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
  final trace = List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 1; i <= n; i++) {
    score[i][0] = -i * 1.05;
    trace[i][0] = 1;
  }
  for (var j = 1; j <= m; j++) {
    score[0][j] = -j * 0.75;
    trace[0][j] = 2;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final similarity = _tokenSimilarity(canonical[i - 1], transcript[j - 1].word);
      final diagonal = score[i - 1][j - 1] + (similarity >= 0.99 ? 3.2 : similarity >= 0.72 ? 1.7 : -1.35);
      final up = score[i - 1][j] - 1.05;
      final left = score[i][j - 1] - 0.75;
      if (diagonal >= up && diagonal >= left) {
        score[i][j] = diagonal;
        trace[i][j] = 0;
      } else if (up >= left) {
        score[i][j] = up;
        trace[i][j] = 1;
      } else {
        score[i][j] = left;
        trace[i][j] = 2;
      }
    }
  }

  final mapping = <int, int>{};
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    final direction = trace[i][j];
    if (i > 0 && j > 0 && direction == 0) {
      if (_tokenSimilarity(canonical[i - 1], transcript[j - 1].word) >= 0.58) {
        mapping[i - 1] = j - 1;
      }
      i--;
      j--;
    } else if (i > 0 && (j == 0 || direction == 1)) {
      i--;
    } else if (j > 0) {
      j--;
    } else {
      break;
    }
  }

  final grouped = <String, List<int>>{};
  mapping.forEach((canonicalIndex, transcriptIndex) {
    grouped.putIfAbsent(lineForToken[canonicalIndex], () => <int>[]).add(transcriptIndex);
  });
  final cues = <LyricSyncCue>[];
  for (final line in project.contributions) {
    final hits = grouped[line.id];
    if (hits == null || hits.isEmpty) continue;
    hits.sort();
    final total = math.max(1, tokenCountByLine[line.id] ?? hits.length);
    final confidence = (hits.length / total).clamp(0.15, 1.0).toDouble();
    cues.add(LyricSyncCue(
      contributionId: line.id,
      startMs: transcript[hits.first].startMs,
      endMs: math.min(durationMs, transcript[hits.last].endMs + 180),
      confidence: confidence,
    ));
  }
  cues.sort((a, b) => a.startMs.compareTo(b.startMs));
  if (cues.isEmpty) return const _LyricAlignmentResult(<LyricSyncCue>[], 0);
  final confidence = cues.map((cue) => cue.confidence).reduce((a, b) => a + b) / cues.length;
  return _LyricAlignmentResult(cues, confidence);
}

List<String> _tokenize(String text) => text
    .split(RegExp(r'\s+'))
    .map(_normalizeToken)
    .where((word) => word.isNotEmpty)
    .toList(growable: false);

String _normalizeToken(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9']"), '')
    .replaceAll(RegExp(r"^'+|'+$"), '');

double _tokenSimilarity(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  final distance = _levenshtein(a, b);
  return 1 - distance / math.max(a.length, b.length);
}

int _levenshtein(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (index) => index);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    previous = current;
  }
  return previous.last;
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
  final raw = <Map<String, dynamic>>[];
  final chordHistogram = <String, double>{};
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
    for (var i = 0; i < 12; i++) chroma[i] /= norm;
    final detected = _bestChord(chroma);
    final startMs = (start * 1000 / sampleRate).round();
    final endMs = math.min(durationMs, ((start + hop) * 1000 / sampleRate).round());
    raw.add(<String, dynamic>{
      'startMs': startMs,
      'endMs': endMs,
      'chord': detected.$1,
      'confidence': detected.$2,
    });
    chordHistogram[detected.$1] = (chordHistogram[detected.$1] ?? 0) + detected.$2;
  }

  if (raw.length >= 3) {
    for (var i = 1; i < raw.length - 1; i++) {
      final previous = raw[i - 1]['chord'];
      final next = raw[i + 1]['chord'];
      if (previous == next && raw[i]['chord'] != previous) raw[i]['chord'] = previous;
    }
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

  String? key;
  if (chordHistogram.isNotEmpty) {
    final entries = chordHistogram.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    key = entries.first.key;
  }
  return <String, dynamic>{'cues': merged, 'key': key};
}

(String, double) _bestChord(List<double> chroma) {
  const names = <String>['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  var bestName = 'C';
  var best = -1.0;
  var second = -1.0;
  for (var root = 0; root < 12; root++) {
    for (final minor in <bool>[false, true]) {
      final third = (root + (minor ? 3 : 4)) % 12;
      final fifth = (root + 7) % 12;
      final score = chroma[root] * 1.0 + chroma[third] * 0.78 + chroma[fifth] * 0.86;
      if (score > best) {
        second = best;
        best = score;
        bestName = '${names[root]}${minor ? 'm' : ''}';
      } else if (score > second) {
        second = score;
      }
    }
  }
  final margin = math.max(0.0, best - second);
  final confidence = (margin * 2.6 + (best - 0.65) * 0.22).clamp(0.05, 0.92).toDouble();
  return (bestName, confidence);
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
