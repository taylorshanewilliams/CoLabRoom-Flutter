import 'dart:io';

import 'package:archive/archive.dart';

import 'latency_probe.dart';
import 'multitrack.dart';
import 'take_naming.dart';

/// Getting the work back out.
///
/// This exists so the retention policy can be a fair one. "We will expire
/// layers nobody has opened in months" is a reasonable thing to do with
/// storage and an unreasonable thing to do to a band, unless taking a copy
/// is one tap away at any point. It is the difference between a service that
/// tidies up and a service that loses your work.
///
/// Two shapes, because two things get asked for. The mix is what the song
/// sounds like and goes to whoever asked to hear it. The layers are what the
/// song is *made of* and go into a DAW — separate files, plus the settings
/// needed to rebuild the mix, so the export is not a dead end.
class TakeExport {
  const TakeExport._();

  /// The enabled layers, summed, as a single wav.
  static Future<File?> mixdown({
    required List<Take> takes,
    required String outputPath,
  }) async {
    final result = await Multitrack.writeMixdown(
      takes: takes,
      outputPath: outputPath,
    );
    return result == null ? null : File(outputPath);
  }

  /// Every layer as its own file, zipped, with a note describing how they fit
  /// together.
  ///
  /// Muted layers are included deliberately. Somebody exporting to keep their
  /// work wants all of it — a layer switched off today is still a take
  /// somebody played, and the point of this is that nothing is lost. The
  /// manifest records which were on.
  static Future<File?> layerArchive({
    required List<Take> takes,
    required String outputPath,
    String? songTitle,
  }) async {
    if (takes.isEmpty) return null;
    final archive = Archive();
    var index = 1;
    var added = 0;

    for (final take in takes) {
      final file = File(take.path);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(
        // Numbered so the files sort in the order they were recorded, which
        // is the order they make sense in. Sanitised because a layer can be
        // called anything and a zip entry cannot.
        '${index.toString().padLeft(2, '0')}_${_safeName(TakeNaming.describe(take))}.wav',
        bytes.length,
        bytes,
      ));
      index += 1;
      added += 1;
    }
    if (added == 0) return null;

    final notes = describeSession(takes: takes, songTitle: songTitle);
    final noteBytes = notes.codeUnits;
    archive.addFile(ArchiveFile('mix-notes.txt', noteBytes.length, noteBytes));

    final encoded = ZipEncoder().encode(archive);
    final out = File(outputPath);
    await out.writeAsBytes(encoded, flush: true);
    return out;
  }

  /// The plain-text note that rides along with the layers.
  ///
  /// Everything needed to rebuild the mix somewhere else: the order, who
  /// played what, the volume each layer sat at, and how much was trimmed off
  /// its front for latency. Without the trims the layers do not line up when
  /// imported, which would make the export technically complete and
  /// practically useless.
  static String describeSession({
    required List<Take> takes,
    String? songTitle,
  }) {
    final buffer = StringBuffer();
    final title = songTitle?.trim();
    buffer.writeln(title == null || title.isEmpty ? 'CoLabRoom layers' : title);
    buffer.writeln('Exported ${DateTime.now().toIso8601String().split('T').first}');
    buffer.writeln();
    buffer.writeln('Each layer is a separate mono wav at ${Multitrack.rate} Hz.');
    buffer.writeln('Line them all up at zero — the trim below is already applied.');
    buffer.writeln();

    var index = 1;
    for (final take in takes) {
      final number = index.toString().padLeft(2, '0');
      buffer.writeln('$number  ${TakeNaming.describe(take)}');
      final details = <String>[
        'volume ${(take.gain * 100).round()}%',
        if (take.offsetMs > 0) 'trimmed ${take.offsetMs} ms from the start',
        if (!take.enabled) 'muted in the last mix',
        if (take.performer != null) 'played by ${take.performer}',
      ];
      buffer.writeln('    ${details.join(' · ')}');
      index += 1;
    }
    return buffer.toString();
  }

  /// A filename that will survive a zip, a Windows share, and an email.
  static String _safeName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r"[^A-Za-z0-9 _-]"), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .trim();
    if (cleaned.isEmpty) return 'layer';
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }
}
