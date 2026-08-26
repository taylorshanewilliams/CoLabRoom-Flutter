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
  /// Two different numbers sit at the front of every take and they must not
  /// be confused, which is easy because both are milliseconds:
  ///
  ///   * [Take.offsetMs] is the latency **trim** — how much of the front of
  ///     the recording to throw away, because a phone records a moment behind
  ///     what it plays.
  ///   * [Take.startMs] is **where the take belongs**, measured from the top
  ///     of the song. Zero for anything recorded from the beginning, which is
  ///     every take that existed before punching in did.
  ///
  /// A take is skipped entirely when it is not [Take.enabled], which is what
  /// makes muting a layer while recording against the rest possible without
  /// deleting anything.
  static MixResult mix(
    List<Take> takes,
    List<Float64List> audio, {
    List<String> silentTakeIds = const <String>[],
  }) {
    assert(takes.length == audio.length);
    var longest = 0;
    final trims = List<int>.filled(takes.length, 0);
    final places = List<int>.filled(takes.length, 0);
    for (var i = 0; i < takes.length; i += 1) {
      if (!takes[i].enabled) continue;
      // A take that came back late is pulled forward, so the first sample
      // kept is the one that was playing when the backing track started.
      final trim = math.max(0, (takes[i].offsetMs * rate / 1000).round());
      final place = math.max(0, (takes[i].startMs * rate / 1000).round());
      trims[i] = trim;
      places[i] = place;
      // The mix has to be long enough to hold a take that starts late as well
      // as one that runs long. A harmony punched in over the last chorus ends
      // after the song does if it overruns.
      longest = math.max(longest, place + math.max(0, audio[i].length - trim));
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
      final trim = trims[i];
      final place = places[i];
      final count = math.min(longest - place, source.length - trim);
      for (var s = 0; s < count; s += 1) {
        out[place + s] += source[trim + s] * gain;
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

  /// The shape of a take, as loudness over time.
  ///
  /// Cheap because the expensive part is already done: every take is decoded
  /// to samples and cached beside itself so the mixer can sum it, so drawing
  /// a waveform costs one pass over data this file already holds rather than
  /// a second decode. That is the whole reason a phone app can afford
  /// waveforms at all.
  ///
  /// **Root-mean-square, not peak, and that distinction was a bug.** Peak is
  /// the obvious choice and it drew a solid fence: a three-and-a-half-minute
  /// song across 56 buckets is 3.6 seconds a bucket, and the loudest
  /// *instant* in any 3.6 seconds of a mixed record is essentially always
  /// full scale, so every bar came out the same height. A four-second take,
  /// at 70 ms a bucket, kept its detail and looked like a waveform — which is
  /// what made the difference visible.
  ///
  /// RMS asks how loud the bucket *is* rather than how loud its loudest
  /// sample was, so it keeps saying something however long the window gets:
  /// a verse reads quieter than a chorus, and silence reads as silence.
  ///
  /// Absolute, not normalised per take. A take normalised to its own loudest
  /// moment draws a whisper the same height as a shout, which is exactly the
  /// comparison a mixer exists to make.
  static List<double> envelope(Float64List samples, {int buckets = 56}) {
    if (samples.isEmpty || buckets <= 0) return const <double>[];
    final out = List<double>.filled(buckets, 0);
    final per = samples.length / buckets;
    for (var b = 0; b < buckets; b += 1) {
      final from = (b * per).floor();
      final to =
          math.max(from + 1, math.min(samples.length, ((b + 1) * per).ceil()));
      var sum = 0.0;
      for (var i = from; i < to; i += 1) {
        sum += samples[i] * samples[i];
      }
      final rms = math.sqrt(sum / (to - from));
      out[b] = rms > 1 ? 1 : rms;
    }
    return out;
  }

  /// A take's shape, read through the same cache the mixer uses.
  ///
  /// The bucket count follows the take's length — roughly one per quarter
  /// second — rather than being fixed. A fixed count makes the window length
  /// depend on how long the take is, which is the other half of why the
  /// reference averaged into a straight line while a short take did not.
  /// Floored so a two-second stab still has a shape, capped so a ten-minute
  /// jam does not draw thousands of bars nobody can see.
  static Future<List<double>> envelopeFor(Take take, {int? buckets}) async {
    final samples = await samplesFor(take);
    final wanted =
        buckets ?? (samples.length / rate * 4).round().clamp(48, 260);
    return envelope(samples, buckets: wanted);
  }

  /// A click track, as samples.
  ///
  /// Generated rather than played, so that it can be summed into the mix like
  /// any other layer. That is the same argument the rest of this file makes:
  /// a second player has its own clock and drifts against the first, and a
  /// metronome that drifts is worse than no metronome — it teaches somebody
  /// their timing is wrong when it is the app's.
  ///
  /// [beatsPerBar] accents the downbeat, which is what makes a click
  /// countable rather than a texture. Zero or one means every beat is the
  /// same, for anyone who finds the accent worse than the alternative.
  /// Clicks on beats the analysis actually found.
  ///
  /// The tempo version below counts from zero, and a song's first downbeat is
  /// almost never at zero — an intro, a count-in, half a second of room. A
  /// click that starts at zero is then wrong against the record for its whole
  /// length by however long that was, at every tempo, and no amount of
  /// getting the bpm right fixes it.
  ///
  /// These beats also drift with the band, which a fixed tempo cannot. For
  /// playing along to your own record that is the point; for practising
  /// steady time it is not, which is why the fixed-tempo version stays.
  static Float64List clickOnBeats({
    required List<int> beatsMs,
    required int lengthSamples,
    int beatsPerBar = 4,
    double level = 0.32,
  }) {
    final out = Float64List(lengthSamples);
    if (beatsMs.isEmpty || lengthSamples <= 0) return out;
    for (var beat = 0; beat < beatsMs.length; beat += 1) {
      final at = (beatsMs[beat] * rate / 1000).round();
      if (at >= lengthSamples) break;
      _strike(
        out,
        at,
        accent: beatsPerBar > 1 && beat % beatsPerBar == 0,
        level: level,
      );
    }
    return out;
  }

  /// One tick, written into [out] at [at].
  static void _strike(
    Float64List out,
    int at, {
    required bool accent,
    required double level,
  }) {
    // Short enough to be a tick rather than a note. A long click smears
    // across the beat it is supposed to mark.
    final tickSamples = (rate * 0.035).round();
    // A fifth apart, so the downbeat is recognisable without being a
    // different instrument.
    final frequency = accent ? 1800.0 : 1200.0;
    final gain = accent ? level : level * 0.62;
    for (var i = 0; i < tickSamples; i += 1) {
      final index = at + i;
      if (index >= out.length) break;
      // Exponential decay: a struck sound, not a beep held open.
      final envelope = math.exp(-i / (tickSamples * 0.28));
      out[index] +=
          math.sin(2 * math.pi * frequency * i / rate) * envelope * gain;
    }
  }

  static Float64List click({
    required double bpm,
    required int lengthSamples,
    int beatsPerBar = 4,
    double level = 0.32,
  }) {
    final out = Float64List(lengthSamples);
    if (bpm <= 0 || lengthSamples <= 0) return out;

    final samplesPerBeat = 60.0 / bpm * rate;
    // Short enough to be a tick rather than a note. A long click smears
    // across the beat it is supposed to mark.
    final tickSamples = (rate * 0.035).round();

    var beat = 0;
    for (var start = 0.0;
        start < lengthSamples;
        start += samplesPerBeat, beat += 1) {
      final accent = beatsPerBar > 1 && beat % beatsPerBar == 0;
      // A fifth apart, so the downbeat is recognisable without being a
      // different instrument.
      final frequency = accent ? 1800.0 : 1200.0;
      final gain = accent ? level : level * 0.62;
      final from = start.round();
      for (var i = 0; i < tickSamples; i += 1) {
        final at = from + i;
        if (at >= lengthSamples) break;
        // Exponential decay: a struck sound, not a beep held open.
        final envelope = math.exp(-i / (tickSamples * 0.28));
        out[at] += math.sin(2 * math.pi * frequency * i / rate) *
            envelope *
            gain;
      }
    }
    return out;
  }

  /// Where the beats fall for a given tempo, in milliseconds from zero.
  ///
  /// The grid a click track implies. Recording against a metronome means the
  /// tempo is known exactly rather than inferred, so a take on a song with no
  /// analysis can still be timed to the beat — which is the one case
  /// automatic alignment could not answer before.
  static List<int> beatsForTempo({
    required double bpm,
    required int throughMs,
    int beatsPerBar = 4,
  }) {
    if (bpm <= 0 || throughMs <= 0) return const <int>[];
    final beatMs = 60000 / bpm;
    final count = (throughMs / beatMs).floor() + 1;
    return <int>[for (var i = 0; i < count; i += 1) (i * beatMs).round()];
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

  /// A click and nothing else, a whole number of bars long.
  ///
  /// For the first take of a song that has no recording to play along to.
  /// Written as an exact number of bars so the file loops seamlessly — and
  /// looping is safe here in a way it never is for a backing track, because a
  /// click on its own has nothing to drift against.
  static Future<void> writeClickOnly({
    required double bpm,
    required String outputPath,
    int beatsPerBar = 4,
    int bars = 8,
  }) async {
    final beats = math.max(1, beatsPerBar) * bars;
    final lengthSamples = (60.0 / bpm * rate * beats).round();
    final samples = click(
      bpm: bpm,
      lengthSamples: lengthSamples,
      beatsPerBar: beatsPerBar,
    );
    await File(outputPath).writeAsBytes(
      LatencyProbe.toWav(samples, rate: rate),
      flush: true,
    );
  }

  /// The click's id inside a mix. Not a uuid, so it cannot collide with a
  /// real layer, and never written anywhere — a metronome is a way of
  /// listening, not a part of the song.
  static const String clickTakeId = 'click';

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
    double? clickBpm,
    int clickBeatsPerBar = 4,
    List<int> clickBeatsMs = const <int>[],
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

    // The click joins the mix as another layer rather than as another player,
    // for the reason at the top of this file: one file has nothing to drift
    // against. It is added before the peak is measured, so a mix that was
    // already near full scale is turned down to fit the click rather than
    // clipping on every beat.
    var wantedWithClick = wanted;
    var audioWithClick = audio;
    final followsSong = clickBeatsMs.length > 1;
    if (followsSong || (clickBpm != null && clickBpm > 0)) {
      var longest = 0;
      for (var i = 0; i < wanted.length; i += 1) {
        final trim = math.max(0, (wanted[i].offsetMs * rate / 1000).round());
        final place = math.max(0, (wanted[i].startMs * rate / 1000).round());
        longest =
            math.max(longest, place + math.max(0, audio[i].length - trim));
      }
      if (longest > 0) {
        wantedWithClick = <Take>[
          ...wanted,
          Take(
            id: clickTakeId,
            path: '',
            label: 'Click',
            recordedAt: DateTime.now(),
          ),
        ];
        audioWithClick = <Float64List>[
          ...audio,
          // The song's own beats when the analysis found them, because a
          // click counted from zero lands wherever the intro leaves it and
          // stays wrong for the whole song.
          if (followsSong)
            clickOnBeats(
              beatsMs: clickBeatsMs,
              lengthSamples: longest,
              beatsPerBar: clickBeatsPerBar,
            )
          else
            click(
              bpm: clickBpm!,
              lengthSamples: longest,
              beatsPerBar: clickBeatsPerBar,
            ),
        ];
      }
    }

    final result = mix(wantedWithClick, audioWithClick, silentTakeIds: silent);
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
    this.startMs = 0,
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

  /// Where this take begins, in milliseconds from the top of the song.
  ///
  /// Zero for anything recorded from the beginning — which is every take that
  /// existed before punching in did, and the reason this defaults rather than
  /// being nullable.
  ///
  /// Not [offsetMs]. That one throws away the front of the recording to
  /// correct for latency; this one says where the recording sits. Both are
  /// milliseconds at the front of a take, which is precisely why they are
  /// named differently.
  final int startMs;

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
    int? startMs,
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
      startMs: startMs ?? this.startMs,
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
        'start_ms': startMs,
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
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
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
