import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';

import 'audio_analysis_utils.dart';
import 'latency_probe.dart';
import 'take_naming.dart';

/// Layered takes over one another: a riff, then a vocal over it, then a lead
/// over both.
///
/// The whole thing is local audio and arithmetic. No analysis runs, nothing
/// is uploaded, and no take means anything to the rest of the app until
/// somebody asks it to — record a riff and it is simply there.
///
/// **Why the mix is built here rather than played as separate tracks.**
/// stem_player_panel.dart plays one stem at a time on purpose: independent
/// players drift against each other on mobile with no shared clock, and that
/// drift is exactly what a layered take cannot survive. Summing the takes
/// into a single file removes the problem instead of managing it — one file
/// has nothing to drift against. It costs a pass over the samples, which for
/// a four-minute sketch is a fraction of a second, and it happens while
/// somebody is deciding what to play next.
class Multitrack {
  const Multitrack._();

  static const int rate = LatencyProbe.sampleRate;

  /// Sums [takes] into one signal.
  ///
  /// Each take is shifted earlier by its own [Take.offsetMs] — the latency
  /// correction — and skipped entirely when it is not [Take.enabled], which
  /// is what makes muting a layer while recording against the rest possible
  /// without deleting anything.
  static MixResult mix(
    List<Take> takes,
    List<Float64List> audio, {
    List<String> silentTakeIds = const <String>[],
  }) {
    assert(takes.length == audio.length);
    var longest = 0;
    final starts = List<int>.filled(takes.length, 0);
    for (var i = 0; i < takes.length; i += 1) {
      if (!takes[i].enabled) continue;
      // A take that came back late is pulled forward, so the first sample
      // kept is the one that was playing when the backing track started.
      final skip = math.max(0, (takes[i].offsetMs * rate / 1000).round());
      starts[i] = skip;
      longest = math.max(longest, math.max(0, audio[i].length - skip));
    }
    if (longest == 0) {
      return MixResult(Float64List(0),
          peak: 0, scaled: false, silentTakeIds: silentTakeIds);
    }

    final out = Float64List(longest);
    for (var i = 0; i < takes.length; i += 1) {
      if (!takes[i].enabled) continue;
      final source = audio[i];
      final gain = takes[i].gain;
      final skip = starts[i];
      final count = math.min(longest, source.length - skip);
      for (var s = 0; s < count; s += 1) {
        out[s] += source[skip + s] * gain;
      }
    }

    var peak = 0.0;
    for (final value in out) {
      final magnitude = value.abs();
      if (magnitude > peak) peak = magnitude;
    }

    // Scaled down rather than clipped. Four layers summed will pass 1.0 sooner
    // or later, and hard clipping turns that into audible crunch that sounds
    // like a bad take rather than a full mix. Scaling keeps the balance
    // between layers exactly as it was and only changes how loud the whole
    // thing is.
    var scaled = false;
    if (peak > 1.0) {
      final factor = 0.99 / peak;
      for (var s = 0; s < out.length; s += 1) {
        out[s] *= factor;
      }
      scaled = true;
    }
    return MixResult(out, peak: peak, scaled: scaled, silentTakeIds: silentTakeIds);
  }

  /// One take's audio as samples, whatever container it arrived in.
  ///
  /// Layers are recorded compressed — AAC, which is roughly seven times
  /// smaller than the wav this used to write and is the only compressed
  /// format both platforms record *and* both platforms can read. (Opus is
  /// smaller still, but record's iOS encoder wraps it in a CAF container that
  /// only iOS plays, which is no use to a band on mixed phones.)
  ///
  /// Mixing needs samples, so a compressed layer has to be decoded first. The
  /// result is cached beside the original: decoding eight layers on every
  /// change — and the mix is rebuilt on every mute, every volume change and
  /// before every new take — would make the screen feel broken. Decoded once,
  /// the cache is a plain wav and reads at the speed of the disk.
  static Future<Float64List> samplesFor(Take take) async {
    final file = File(take.path);
    if (!await file.exists()) return Float64List(0);

    final extension = audioFileExtension(take.path);
    if (extension == 'wav') {
      return LatencyProbe.fromWav(await file.readAsBytes());
    }

    final cachePath = '${take.path}.pcm.wav';
    final cache = File(cachePath);
    // Regenerated if the source is newer, so a re-recorded take under the
    // same name cannot be played back as the old one.
    if (await cache.exists() &&
        (await cache.lastModified()).isAfter(await file.lastModified())) {
      return LatencyProbe.fromWav(await cache.readAsBytes());
    }

    try {
      // Raw PCM, then a wav header written here.
      //
      // This asked the decoder for the header too, and got back something
      // fromWav could not parse — so every compressed layer decoded to an
      // empty list, and the mixer's own "a layer that will not decode is
      // silence" rule then hid that completely: the part was in the list,
      // muted nothing, and simply could not be heard. The one call to this
      // decoder that has been in production for months passes
      // includeHeader: false, and this now matches it.
      final pcm = await AudioDecoder.convertToWavBytes(
        await file.readAsBytes(),
        formatHint: extension,
        sampleRate: rate,
        channels: 1,
        bitDepth: 16,
        includeHeader: false,
      );
      final samples = pcmToSamples(pcm);
      if (samples.isEmpty) return Float64List(0);
      await cache.writeAsBytes(
        LatencyProbe.toWav(samples, rate: rate),
        flush: true,
      );
      return samples;
    } catch (_) {
      // Still silence rather than an exception mid-session — but no longer
      // silent about it: writeMixdown reports which layers produced nothing
      // so the screen can say so instead of leaving somebody wondering why
      // their part vanished.
      return Float64List(0);
    }
  }

  /// The loudest sample in a just-recorded file, or null if nothing decoded.
  ///
  /// The difference between those two answers is the whole point. A file that
  /// will not decode is a broken container; a file that decodes to a peak of
  /// zero is a microphone that was open, running and capturing nothing —
  /// which is what an audio session configured for playback does to a
  /// concurrent recording. Both used to reach the band as a take nobody could
  /// hear, and size alone cannot tell them apart: four seconds of encoded
  /// digital silence is a perfectly well-formed 2.5 KB m4a.
  static Future<double?> peakOfRecording(String path) async {
    final samples = await readRecording(path);
    return samples == null ? null : peakOf(samples);
  }

  /// A just-recorded file's samples, or null if nothing decoded.
  ///
  /// Separated from [peakOfRecording] so the one decode can answer more than
  /// one question. A take is checked for silence and aligned to the beat in
  /// the same breath, and decoding it twice to do that would double the wait
  /// between somebody stopping and the take appearing.
  static Future<Float64List?> readRecording(String path) async {
    final samples = await samplesFor(Take(
      id: path,
      path: path,
      label: '',
      recordedAt: DateTime.now(),
    ));
    return samples.isEmpty ? null : samples;
  }

  static double peakOf(Float64List samples) {
    var peak = 0.0;
    for (final value in samples) {
      final magnitude = value.abs();
      if (magnitude > peak) peak = magnitude;
    }
    return peak;
  }

  /// Below this, nothing was captured.
  ///
  /// Deliberately far under anything a person could play. A take recorded
  /// across a room at arm's length still peaks two orders of magnitude above
  /// this; -54 dBFS is not a quiet performance, it is an input that never
  /// opened. Set low on purpose — refusing to save something somebody
  /// actually played would be a worse bug than the one this catches.
  static const double silenceFloor = 0.002;

  /// Signed 16-bit little-endian PCM as samples.
  static Float64List pcmToSamples(Uint8List pcm) {
    final count = pcm.length ~/ 2;
    final data = ByteData.sublistView(pcm);
    final out = Float64List(count);
    for (var i = 0; i < count; i += 1) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// Reads every enabled take off disk and writes the mix to [outputPath].
  ///
  /// Returns null when there is nothing to play, which is the ordinary state
  /// before the first take rather than an error.
  static Future<MixResult?> writeMixdown({
    required List<Take> takes,
    required String outputPath,
  }) async {
    final wanted = takes.where((take) => take.enabled).toList(growable: false);
    if (wanted.isEmpty) return null;
    final audio = <Float64List>[];
    final silent = <String>[];
    for (final take in wanted) {
      final samples = await samplesFor(take);
      if (samples.isEmpty) silent.add(take.id);
      audio.add(samples);
    }
    final result = mix(wanted, audio, silentTakeIds: silent);
    if (result.samples.isEmpty) return null;
    await File(outputPath).writeAsBytes(
      LatencyProbe.toWav(result.samples, rate: rate),
      flush: true,
    );
    return result;
  }
}

/// One recorded layer.
class Take {
  const Take({
    required this.id,
    required this.path,
    required this.label,
    required this.recordedAt,
    this.durationMs = 0,
    this.offsetMs = 0,
    this.gain = 1.0,
    this.enabled = true,
    this.part = TakePart.other,
    this.performer,
    this.namedByHand = false,
  });

  final String id;
  final String path;
  final String label;
  final DateTime recordedAt;
  final int durationMs;

  /// How much of the front of this recording to drop, in milliseconds.
  ///
  /// The latency correction, stored per take rather than per session, because
  /// it is a property of the take: the phone may have been on speaker for one
  /// and on Bluetooth for the next, and a take recorded before the offset was
  /// known should not silently change when it becomes known.
  final int offsetMs;

  final double gain;

  /// Whether this take is in the mix. Muting is not deleting — playing
  /// against three of four layers is how you hear whether the fourth is
  /// carrying its weight.
  final bool enabled;

  /// What this layer is: a lead, a harmony, the bass. Picked from a short
  /// list in the second after recording stops, which is the only moment
  /// anybody will spend on it.
  final TakePart part;

  /// Who played it. Filled from the signed-in member by default, and
  /// editable — a phone gets handed around a room, and the person holding it
  /// is not always the person who played.
  final String? performer;

  /// Whether [label] was typed by a person.
  ///
  /// The distinction matters because a generated label should follow the
  /// part and performer when either changes, and a chosen one must never be
  /// overwritten by a rule.
  final bool namedByHand;

  Take copyWith({
    String? label,
    int? offsetMs,
    double? gain,
    bool? enabled,
    TakePart? part,
    String? performer,
    bool? namedByHand,
  }) {
    return Take(
      id: id,
      path: path,
      label: label ?? this.label,
      recordedAt: recordedAt,
      durationMs: durationMs,
      offsetMs: offsetMs ?? this.offsetMs,
      gain: gain ?? this.gain,
      enabled: enabled ?? this.enabled,
      part: part ?? this.part,
      performer: performer ?? this.performer,
      namedByHand: namedByHand ?? this.namedByHand,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'label': label,
        'recorded_at': recordedAt.toIso8601String(),
        'duration_ms': durationMs,
        'offset_ms': offsetMs,
        'gain': gain,
        'enabled': enabled,
        'part': part.name,
        if (performer != null) 'performer': performer,
        'named_by_hand': namedByHand,
      };

  factory Take.fromJson(Map<String, dynamic> json) {
    return Take(
      id: json['id'] as String? ?? '',
      path: json['path'] as String? ?? '',
      label: json['label'] as String? ?? 'Take',
      recordedAt:
          DateTime.tryParse(json['recorded_at'] as String? ?? '') ?? DateTime.now(),
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      offsetMs: (json['offset_ms'] as num?)?.toInt() ?? 0,
      gain: (json['gain'] as num?)?.toDouble() ?? 1.0,
      enabled: json['enabled'] as bool? ?? true,
      part: TakePart.parse(json['part'] as String?),
      performer: json['performer'] as String?,
      namedByHand: json['named_by_hand'] as bool? ?? false,
    );
  }
}

class MixResult {
  const MixResult(
    this.samples, {
    required this.peak,
    required this.scaled,
    this.silentTakeIds = const <String>[],
  });

  final Float64List samples;

  /// The loudest point before any scaling. Above 1.0 means the layers
  /// summed past full scale.
  final double peak;

  /// Whether the mix had to be turned down to fit.
  final bool scaled;

  /// Layers that contributed nothing — a missing file, or audio that would
  /// not decode. Reported rather than swallowed: a part that is in the list
  /// and cannot be heard is the most confusing possible failure, and the
  /// person looking at it has no way to tell it from a bad recording.
  final List<String> silentTakeIds;
}

/// The takes for one sketch, and where they live.
///
/// Deliberately a file on the device rather than a row in Supabase. Nothing
/// here needs an account, a project, or a network, and a riff captured in the
/// thirty seconds before it is forgotten should not wait for any of them.
/// Sharing a session with a bandmate is a later, separate step that can read
/// this same manifest.
class TakeSession {
  const TakeSession({required this.directory, required this.takes});

  final String directory;
  final List<Take> takes;

  static String manifestPathIn(String directory) => '$directory/takes.json';

  static Future<TakeSession> load(String directory) async {
    final file = File(manifestPathIn(directory));
    if (!await file.exists()) {
      return TakeSession(directory: directory, takes: const <Take>[]);
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final rows = decoded is List ? decoded : const <dynamic>[];
      return TakeSession(
        directory: directory,
        takes: rows
            .whereType<Map<String, dynamic>>()
            .map(Take.fromJson)
            .toList(growable: false),
      );
    } catch (_) {
      // A manifest that will not parse must not cost somebody their audio.
      // The wav files are still on disk and still named in the directory;
      // returning empty leaves them recoverable rather than deleting them.
      return TakeSession(directory: directory, takes: const <Take>[]);
    }
  }

  Future<void> save() async {
    await File(manifestPathIn(directory)).writeAsString(
      jsonEncode(takes.map((take) => take.toJson()).toList(growable: false)),
      flush: true,
    );
  }
}
