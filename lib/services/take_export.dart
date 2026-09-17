import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../domain/song_analysis_models.dart';
import 'latency_probe.dart';
import 'midi_file.dart';
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

  /// What the tempo and the section names are called inside the zip.
  static const String tempoFileName = 'tempo-and-sections.mid';

  /// Every layer as its own file, zipped, with the tempo, the sections and a
  /// note describing how they fit together.
  ///
  /// A pack to drop into a DAW rather than a folder of audio (Every Musician,
  /// Same Song, 17 September 2026: build the bridge, not the destination).
  /// The difference is whether the first ten minutes in Ableton are spent
  /// playing or spent tapping tempo and nudging regions.
  ///
  /// Muted layers are included deliberately. Somebody exporting to keep their
  /// work wants all of it — a layer switched off today is still a take
  /// somebody played, and the point of this is that nothing is lost. The
  /// manifest records which were on.
  ///
  /// The analysis arguments are all optional and all skipped when absent. A
  /// song nobody has analyzed still exports; it simply arrives without a
  /// tempo map, which is better than arriving with a guessed one.
  static Future<File?> layerArchive({
    required List<Take> takes,
    required String outputPath,
    String? songTitle,
    double? bpm,
    String? musicalKey,
    List<StructureSection> sections = const <StructureSection>[],
    List<int> downbeatsMs = const <int>[],
    int? beatsPerBar,
  }) async {
    if (takes.isEmpty) return null;

    // The tempo is settled before a single byte is written, because the file
    // names carry it and the README quotes it, and two numbers disagreeing
    // inside one zip is worse than neither being there. [SongTempoMap] is the
    // one thing that decides what the tempo is — including whether the
    // analysis's answer is a tempo a song could be at — and everything below
    // quotes it rather than the raw argument.
    final map = (SongTempoMap.isMusicalTempo(bpm) || downbeatsMs.length >= 2)
        ? SongTempoMap.forSong(
            bpm: bpm,
            downbeatsMs: downbeatsMs,
            beatsPerBar: beatsPerBar,
          )
        : null;

    // Written into the zip take by take rather than gathered up and zipped at
    // the end.
    //
    // Each wav now runs from the top of the song, so a harmony punched in
    // over the last chorus is a file the length of the whole song. Holding
    // every one of those in an [Archive] and then building the zip beside
    // them is a hundred megabytes and more for a band with a few overdubs,
    // and a phone with 2 GB answers that by killing the app mid-export.
    // Streaming keeps one wav in memory at a time.
    final output = OutputFileStream(outputPath);
    final encoder = ZipEncoder()..startEncode(output);
    final used = <String>{};
    // Which take ended up as which file, so mix-notes.txt can name the file
    // rather than count down the list — see [describeSession].
    final fileNames = <String, String>{};

    try {
      for (final take in takes) {
        if (!await File(take.path).exists()) continue;
        // Decoded to wav on the way out rather than copied as-is.
        //
        // Layers are stored as AAC to save space, and an export exists to be
        // opened somewhere else — a DAW, another phone, in ten years. Wav is
        // the format that will still open, and this is the one moment where
        // size matters less than certainty.
        final samples = await Multitrack.samplesFor(take);
        if (samples.isEmpty) continue;
        final bytes = alignedWav(take, samples);
        final name = '${_unique(used, takeFileName(
          take: take,
          songTitle: songTitle,
          bpm: map?.statedBpm,
          musicalKey: musicalKey,
        ))}.wav';
        encoder.add(ArchiveFile(name, bytes.length, bytes));
        fileNames[take.id] = name;
      }
      if (fileNames.isEmpty) {
        await _abandon(output, outputPath);
        return null;
      }

      if (map != null) {
        final midi = writeTempoMapMidi(
          map: map,
          trackName: songTitle,
          markers: <MidiMarker>[
            for (final section in sections)
              MidiMarker(atMs: section.startMs, text: section.displayLabel),
          ],
        );
        encoder.add(ArchiveFile(tempoFileName, midi.length, midi));
      }

      _addText(
        encoder,
        'README.txt',
        importNotes(
          songTitle: songTitle,
          bpm: map?.statedBpm,
          musicalKey: musicalKey,
          hasTempoFile: map != null,
        ),
      );
      _addText(
        encoder,
        'mix-notes.txt',
        describeSession(
          takes: takes,
          fileNames: fileNames,
          songTitle: songTitle,
        ),
      );

      encoder.endEncode();
      await output.close();
      return File(outputPath);
    } catch (_) {
      // A half-written zip is worse than none: it opens, and what is missing
      // from it is whatever the export had not reached yet.
      await _abandon(output, outputPath);
      rethrow;
    }
  }

  /// One take as a wav, moved to where the take sits in the song.
  ///
  /// The same two numbers the mixer works from, applied the same way, because
  /// an export that lines up differently from the app's own mix is worse than
  /// no export: [Take.offsetMs] comes off the front because the phone
  /// recorded that much behind what it played, and [Take.startMs] goes on the
  /// front as silence because that is where the take begins in the song. Do
  /// both and every file in the pack shares one zero, so dropping them all at
  /// bar 1 puts them where they were played.
  ///
  /// The silence is never built as samples — the wav writer puts it straight
  /// into the file's own bytes — because a late overdub's worth of zeros as
  /// doubles is tens of megabytes of nothing.
  ///
  /// Gain is deliberately not applied. A DAW has faders; what it cannot
  /// recover is timing. The levels are written down in mix-notes.txt instead.
  static Uint8List alignedWav(Take take, Float64List samples) {
    final trim = math.max(0, (take.offsetMs * Multitrack.rate / 1000).round());
    final pad = math.max(0, (take.startMs * Multitrack.rate / 1000).round());
    return LatencyProbe.toWav(
      samples,
      rate: Multitrack.rate,
      leadingSilence: pad,
      from: trim,
    );
  }

  /// "Tonight - Bass (Taylor) - 92bpm - D.wav" — the name without its
  /// extension.
  ///
  /// Everything a person needs while looking at a DAW's import dialog, in the
  /// order they need it: which song, which part, and the two facts that
  /// decide whether a file will sit with the others. It is longer than
  /// "02_bass.wav" and that is the point; these files leave here and get
  /// mixed in with somebody else's.
  static String takeFileName({
    required Take take,
    String? songTitle,
    double? bpm,
    String? musicalKey,
  }) {
    final pieces = <String>[];
    final title = songTitle?.trim();
    if (title != null && title.isNotEmpty) pieces.add(title);

    final performer = take.performer?.trim();
    pieces.add(performer == null || performer.isEmpty
        ? _partName(take)
        : '${_partName(take)} ($performer)');

    if (bpm != null && bpm.isFinite && bpm > 0) pieces.add('${bpm.round()}bpm');
    final key = musicalKey?.trim();
    if (key != null && key.isNotEmpty) pieces.add(key);

    return safeFileName(pieces.join(' - '));
  }

  /// A name every file system will keep, spelled the same on all three.
  ///
  /// Windows is the strict one and so sets the rules: no `\ / : * ? " < > |`,
  /// no control characters, no trailing dot or space, and a short list of
  /// device names that cannot be used at all. macOS additionally treats `:`
  /// as a separator in the Finder, which the same rule already covers, and
  /// Linux only objects to `/`. Anything outside plain ASCII is dropped
  /// rather than kept, because a zip written on a phone and opened on a
  /// Windows share is exactly where an encoding disagreement turns a name
  /// into rubble.
  static String safeFileName(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune == 0x266f) {
        buffer.write('#');
      } else if (rune == 0x266d) {
        buffer.write('b');
      } else if (rune < 0x20 || rune > 0x7e) {
        buffer.write(' ');
      } else {
        final char = String.fromCharCode(rune);
        buffer.write(r'<>:"/\|?*'.contains(char) ? ' ' : char);
      }
    }
    var cleaned = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    // Long enough for a title, a part, a performer and both numbers; short
    // enough that the name stays well inside the 255 bytes a file system
    // allows for one of them.
    if (cleaned.length > 96) cleaned = cleaned.substring(0, 96);
    cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty) return 'take';
    // "CON.wav" is still the console on Windows. An underscore in front is
    // the smallest change that makes it a file again.
    if (_reservedOnWindows.hasMatch(cleaned)) cleaned = '_$cleaned';
    return cleaned;
  }

  /// The half page that turns a zip into a session.
  ///
  /// A few lines and the tempo, because it is read once, standing up, with a
  /// DAW already open. Everything else is in mix-notes.txt for whoever wants
  /// it.
  ///
  /// [bpm] is the tempo the MIDI file was written at, not the analysis's raw
  /// answer, so the number somebody types by hand and the number the file sets
  /// cannot be two different tempos.
  static String importNotes({
    String? songTitle,
    double? bpm,
    String? musicalKey,
    bool hasTempoFile = false,
  }) {
    final buffer = StringBuffer();
    final title = songTitle?.trim();
    buffer.writeln(title == null || title.isEmpty
        ? 'CoLabRoom takes'
        : '$title — the takes');
    buffer.writeln();
    buffer.writeln('Drop every wav at bar 1. They all start where the song');
    buffer.writeln('starts, so they land where they were played.');
    buffer.writeln();
    if (hasTempoFile) {
      buffer.writeln('$tempoFileName has the tempo and the section names.');
      if (bpm != null && bpm.isFinite && bpm > 0) {
        buffer.writeln('Import it to set the project tempo, or set the tempo');
        buffer.writeln('by hand: ${bpm.round()} bpm.');
      } else {
        buffer.writeln('Import it to set the project tempo.');
      }
      buffer.writeln();
    }
    final key = musicalKey?.trim();
    if (key != null && key.isNotEmpty) {
      buffer.writeln('The song is in $key.');
      buffer.writeln();
    }
    buffer.writeln('mix-notes.txt has the volume each take sat at.');
    return buffer.toString();
  }

  /// The plain-text note that rides along with the layers.
  ///
  /// Everything needed to rebuild the mix somewhere else: who played what, the
  /// volume each layer sat at, and how much was trimmed off its front for
  /// latency. Without the trims the layers do not line up when imported, which
  /// would make the export technically complete and practically useless.
  ///
  /// [fileNames] maps a take's id to the name it was written under, and is
  /// what each entry is headed with. It used to be a number counted down the
  /// list, which was a promise the pack could not keep: a take whose audio has
  /// been cleaned up under it is still described here but has no wav, so from
  /// that point on the numbers pointed at the wrong file. A take missing from
  /// [fileNames] is one that did not make it in, and says so.
  static String describeSession({
    required List<Take> takes,
    required Map<String, String> fileNames,
    String? songTitle,
  }) {
    final buffer = StringBuffer();
    final title = songTitle?.trim();
    buffer.writeln(title == null || title.isEmpty ? 'CoLabRoom layers' : title);
    buffer.writeln('Exported ${DateTime.now().toIso8601String().split('T').first}');
    buffer.writeln();
    buffer.writeln('Each layer is a separate mono wav at ${Multitrack.rate} Hz.');
    // Said as done rather than as homework. The trim and the start position
    // are both in the audio now, which they were not when this note first
    // claimed they were.
    buffer.writeln('Line them all up at zero — the trim below is already off');
    buffer.writeln('the front, and a take that comes in later already has the');
    buffer.writeln('silence in front of it.');
    buffer.writeln();

    for (final take in takes) {
      final file = fileNames[take.id];
      buffer.writeln(file ??
          '${TakeNaming.describe(take)} — no audio to put in this pack');
      final details = <String>[
        if (file != null) TakeNaming.describe(take),
        'volume ${(take.gain * 100).round()}%',
        if (take.offsetMs > 0) 'trimmed ${take.offsetMs} ms from the start',
        if (take.startMs > 0) 'comes in at ${_seconds(take.startMs)}',
        if (!take.enabled) 'muted in the last mix',
        if (take.performer != null) 'played by ${take.performer}',
      ];
      buffer.writeln('    ${details.join(' · ')}');
    }
    return buffer.toString();
  }

  /// What this layer is, as a file name says it: the part it was given, or
  /// whatever it was called when somebody typed a name.
  static String _partName(Take take) {
    final label = take.label.trim();
    if (take.namedByHand && label.isNotEmpty) return label;
    if (take.part != TakePart.other) {
      final word = take.part.label;
      return '${word[0].toUpperCase()}${word.substring(1)}';
    }
    return label.isNotEmpty ? label : 'Take';
  }

  /// Two takes of the same part by the same person compose the same name, and
  /// a zip cannot hold it twice.
  static String _unique(Set<String> used, String base) {
    var name = base;
    var copy = 2;
    while (!used.add(name.toLowerCase())) {
      name = '$base $copy';
      copy += 1;
    }
    return name;
  }

  static void _addText(ZipEncoder encoder, String name, String body) {
    // utf8 rather than code units: an em dash is a code unit above 255 and a
    // "·" is a byte that only means itself in latin-1, and a text file in a
    // zip is read as utf8 by everything that opens it.
    final bytes = utf8.encode(body);
    encoder.add(ArchiveFile(name, bytes.length, bytes));
  }

  /// Close the stream and leave nothing behind.
  static Future<void> _abandon(OutputFileStream output, String path) async {
    await output.close();
    final partial = File(path);
    if (await partial.exists()) await partial.delete();
  }

  static String _seconds(int ms) {
    final value = ms / 1000;
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} s';
  }

  /// Windows reads the stem in front of the first dot, so "nul.2" is still the
  /// null device once ".wav" is on the end of it — the extension never makes a
  /// device name into a file name.
  static final RegExp _reservedOnWindows = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
    caseSensitive: false,
  );
}
