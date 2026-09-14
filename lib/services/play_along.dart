import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/song_analysis_models.dart';
import 'latency_probe.dart';
import 'multitrack.dart';

/// The band without you.
///
/// The one thing every musician wants from a recording of their own song
/// is to play along with everyone else on it -- the whole band, minus the
/// part they are holding. The separation already produced the parts; this
/// puts them back together with one left out, and hands back a single
/// file. A single file, not five players: simultaneous players drift on a
/// phone and a mix that drifts is worse than no mix (see
/// stem_player_panel.dart for the same reasoning). Summed here rather than
/// on the server because the stems are already on the phone by the time
/// anybody asks, and a sum is cheap next to the separation that made them.
///
/// Mono at 44.1 kHz, the rate the rest of the app's audio path runs at. A
/// practice mix does not need stereo; it needs to exist in a few seconds.
class PlayAlong {
  const PlayAlong._();

  /// How loud the sum may get. The stems were normalised apart, so their
  /// sum can exceed full scale; it is turned down to this rather than
  /// clipped on every chorus.
  static const double ceiling = 0.9;

  /// The path of a mix of every stem except [without], building it if it
  /// does not exist yet.
  ///
  /// [ensureLocalStem] is the same callback the stem player uses: it
  /// downloads and caches a stem and returns its local path. [directory] is
  /// where the mix is kept. Throws when no stem could be decoded -- an
  /// empty mix would play as silence and read as a broken button.
  static Future<String> mixWithout({
    required List<SongStem> stems,
    required StemKind without,
    required Future<String> Function(SongStem) ensureLocalStem,
    required String directory,
    void Function(String stage)? onProgress,
  }) async {
    final kept = stems.where((stem) => stem.kind != without).toList(growable: false);
    if (kept.isEmpty) {
      throw StateError(
        'The ${without.label.toLowerCase()} track is the only one kept, '
        'so there is nothing to play without it.',
      );
    }
    final projectId = kept.first.projectId;
    final path = '$directory/colabroom_playalong_${projectId}_without_${without.name}.wav';
    final file = File(path);
    if (await file.exists() && await file.length() > 44) return path;

    final parts = <Float64List>[];
    for (final stem in kept) {
      onProgress?.call('Fetching the ${stem.kind.label.toLowerCase()}…');
      final local = await ensureLocalStem(stem);
      onProgress?.call('Reading the ${stem.kind.label.toLowerCase()}…');
      final samples = await Multitrack.readRecording(local);
      if (samples != null && samples.isNotEmpty) parts.add(samples);
    }
    if (parts.isEmpty) {
      throw StateError('None of the parts could be read.');
    }
    onProgress?.call('Mixing the band without the ${without.label.toLowerCase()}…');
    final mixed = sum(parts);
    await file.writeAsBytes(LatencyProbe.toWav(mixed, rate: Multitrack.rate), flush: true);
    return path;
  }

  /// [parts] added sample by sample, the longest deciding the length, and
  /// the whole thing turned down if it would exceed [ceiling].
  static Float64List sum(List<Float64List> parts) {
    var longest = 0;
    for (final part in parts) {
      longest = math.max(longest, part.length);
    }
    final out = Float64List(longest);
    for (final part in parts) {
      for (var i = 0; i < part.length; i += 1) {
        out[i] += part[i];
      }
    }
    var peak = 0.0;
    for (final value in out) {
      final magnitude = value.abs();
      if (magnitude > peak) peak = magnitude;
    }
    if (peak > ceiling && peak > 0) {
      final gain = ceiling / peak;
      for (var i = 0; i < out.length; i += 1) {
        out[i] *= gain;
      }
    }
    return out;
  }
}
