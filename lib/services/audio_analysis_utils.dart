import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Shared between [SongAnalysisService] (per-project) and [StudioDraftService]
/// (pre-project drafts) — both run the exact same analysis pipeline, just
/// against different storage paths and DB tables, so the actual audio-crunching
/// logic (on-device chord fallback, file-extension/mime helpers, Whisper
/// placeholder-token filtering) lives here once instead of twice.
class SongAnalysisProgress {
  const SongAnalysisProgress(this.label, this.fraction);

  final String label;
  final double fraction;
}

/// True if [text] contains a letter/digit outside of Whisper's non-speech
/// placeholder markers (bracketed annotations like "[Music]"/"(applause)",
/// and musical note glyphs like "♪♪♪") — those show up instead of real
/// words when a recording is purely instrumental, and shouldn't be
/// mistaken for lost/garbled speech.
bool looksLikeSpeech(String text) {
  final cleaned = text
      .replaceAll(RegExp(r'[\[(][^\])]*[\])]'), '')
      .replaceAll(RegExp(r'[♩-♯]'), '')
      .trim();
  return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(cleaned);
}

String audioFileExtension(String path) {
  final clean = path.split('?').first;
  final dot = clean.lastIndexOf('.');
  if (dot < 0 || dot == clean.length - 1) return 'mp3';
  return clean.substring(dot + 1).toLowerCase();
}

String mimeTypeForExtension(String ext) => switch (ext) {
      'wav' => 'audio/wav',
      'm4a' || 'mp4' => 'audio/mp4',
      'flac' => 'audio/flac',
      'ogg' || 'oga' || 'opus' => 'audio/ogg',
      _ => 'audio/mpeg',
    };

/// On-device chroma/FFT chord + key fallback, used when the cloud
/// Demucs->ChordMini pipeline is unavailable. Meant to run inside
/// `compute()` (a background isolate) — takes/returns only primitive-ish
/// data (a byte buffer in, a JSON-ish map out) for that reason.
Map<String, dynamic> analyzeChordsOnDevice(Map<String, dynamic> input) {
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
