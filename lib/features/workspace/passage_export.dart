import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/latency_probe.dart';
import '../../services/multitrack.dart';
import '../../services/project_export_service.dart';
import 'chord_sheet_export.dart';
import 'musician_sheet_logic.dart';

/// Post a bit of this.
///
/// Every Musician, Same Song, 17 September 2026, creators item 2: a creator's
/// audience and licences live on TikTok and Instagram, and this app is the
/// room behind the post. The DAW pack hands over whole takes and the chart
/// prints the whole song. Neither of them cuts the eight bars somebody
/// actually wants to put up, which is the one thing they do every week.
///
/// A cut is a passage of what is playing — the recording, or a take — taken
/// from one bar line to another, with a few milliseconds of fade inside each
/// end so the file cannot click. Beside it go the words of that passage as
/// SRT and LRC and its chords as ChordPro, every time in them counted from
/// the start of the cut rather than from the start of the song, because a
/// subtitle file is only ever read against the clip it ships with.
///
/// Nothing about a cut is stored or shared. The files are written into a
/// temporary directory, handed to the share sheet, and that is the end of
/// them: it is a thing the person takes away, not a thing the room keeps.
/// No video is rendered here, and nothing on screen mentions one.
///
/// Whose-song (0142) decides what travels. A song the room did not write
/// hands over its chords and neither its words nor its audio, and the file
/// says so in a plain line rather than leaving somebody to work out what is
/// missing — the same stance [ProjectExportService.wordsTravel] already takes
/// for the chart and the ChordPro, extended to the recording because a
/// passage of somebody else's record is the part of this that is least ours
/// to hand out.
abstract final class PassageExport {
  /// What the cut's own file says about the recording, on a song the room did
  /// not write. Read under [ProjectExportService.wordsStayHome], which the
  /// ChordPro writes first.
  static const String recordingStaysHome =
      'The recording stays here too — the chords are the part that travels.';

  /// How long the ramp at each end of the cut is.
  ///
  /// Long enough to kill the click that cutting a waveform mid-cycle makes,
  /// short enough that the downbeat still arrives as a downbeat. A quarter of
  /// a beat of fade on a passage that begins on the 1 would be audible as a
  /// swell, which is exactly what a cut of a band playing must not sound
  /// like.
  static const int fadeMs = 12;

  /// Where a passage really begins and ends: the bar lines either side of
  /// what was asked for.
  ///
  /// The bar picker already hands over downbeats, so for a run of bars this
  /// changes nothing. A section does not: the analysis places a chorus where
  /// the chorus was heard, which is a few tens of milliseconds either side of
  /// the bar line, and a cut that starts a hair late has no downbeat on it at
  /// all — which is the one thing a passage posted on its own has to have.
  ///
  /// Past the last downbeat there is no bar line to snap to, so the moment is
  /// kept as it is. That case is the end of a cut over the final bars, where
  /// [barEndMs] returns the end of the recording: pulling that back to the
  /// last downbeat would drop the very bar that was asked for.
  static PassageCut? cutFor({
    required int startMs,
    required int endMs,
    required String label,
    List<int> downbeatsMs = const <int>[],
  }) {
    if (endMs <= startMs) return null;
    final start = _onABarLine(downbeatsMs, startMs);
    final end = _onABarLine(downbeatsMs, endMs);
    // Both ends landing on the same bar line means the passage is shorter
    // than the bar it sits inside. It is still a passage somebody asked for,
    // so it is cut where they asked rather than refused — the alternative is
    // a button that does nothing and does not say why.
    if (end <= start) {
      return PassageCut(startMs: startMs, endMs: endMs, label: label);
    }
    return PassageCut(startMs: start, endMs: end, label: label);
  }

  /// The passage as samples, with the fades already in it.
  ///
  /// [sourceZeroMs] is where sample zero of [source] sits in song time. It is
  /// zero for the recording and for a part mix, both of which start where the
  /// song starts, and `take.startMs - take.offsetMs` for a take, which is the
  /// same two numbers the mixer and the DAW pack line a take up by.
  ///
  /// The result is exactly as long as the cut, whatever the source has in it.
  /// Anywhere the source does not reach is silence rather than a shorter
  /// file, because the subtitle times are counted from the start of the cut
  /// and would slide against a file that quietly began somewhere else.
  static Float64List samplesFor({
    required Float64List source,
    required PassageCut cut,
    int rate = Multitrack.rate,
    int sourceZeroMs = 0,
    int fade = fadeMs,
  }) {
    final frames = math.max(1, (cut.durationMs * rate / 1000).round());
    final out = Float64List(frames);
    final offset = ((cut.startMs - sourceZeroMs) * rate / 1000).round();
    final from = math.max(0, -offset);
    for (var i = from; i < frames; i += 1) {
      final at = offset + i;
      if (at >= source.length) break;
      out[i] = source[at];
    }
    // Inside the cut, never outside it. A fade that reached back before the
    // downbeat would need audio the passage does not claim, and the first
    // sample of the file would then be part of the bar before.
    final ramp = math.min(
      math.max(1, (fade * rate / 1000).round()),
      frames ~/ 2,
    );
    for (var i = 0; i < ramp; i += 1) {
      final gain = i / ramp;
      out[i] *= gain;
      out[frames - 1 - i] *= gain;
    }
    return out;
  }

  /// Where a take's own sample zero sits in song time.
  ///
  /// The same two numbers the mixer and the DAW pack line a take up by (see
  /// TakeExport.alignedWav): the latency correction comes off the front
  /// because the phone recorded that much behind what it played, and the
  /// start goes on the front because that is where the take begins in the
  /// song. Pass the result as `sourceZeroMs` and a cut of a take lands on the
  /// same bar lines as a cut of the recording.
  static int songZeroOf(Take take) => take.startMs - take.offsetMs;

  /// The passage as a wav, ready to be written or shared.
  static Uint8List wavFor({
    required Float64List source,
    required PassageCut cut,
    int rate = Multitrack.rate,
    int sourceZeroMs = 0,
    int fade = fadeMs,
  }) {
    return LatencyProbe.toWav(
      samplesFor(
        source: source,
        cut: cut,
        rate: rate,
        sourceZeroMs: sourceZeroMs,
        fade: fade,
      ),
      rate: rate,
    );
  }

  /// The words sung inside the cut, grouped the way the song sheet groups
  /// them and counted from the start of the cut.
  ///
  /// The grouping is [transcriptSheetLines]' own, deliberately: the sheet
  /// breaks lines on the breaths in the singing, and a subtitle file that
  /// broke them anywhere else would read as a different song from the one on
  /// screen. A word that straddles an edge of the cut is kept and its time
  /// clamped — half a word is still sung in the passage, and dropping it
  /// would take a word out of the middle of a phrase.
  static List<PassageLine> linesIn(
    List<TranscriptWord> words,
    PassageCut cut,
  ) {
    final inside = <TranscriptWord>[
      for (final word in words)
        if (word.endMs > cut.startMs && word.startMs < cut.endMs) word,
    ];
    if (inside.isEmpty) return const <PassageLine>[];
    final grouped = transcriptSheetLines(
      transcriptWords: inside,
      transcriptText: null,
      chordCues: const <ChordCue>[],
      durationMs: cut.durationMs,
    );
    final out = <PassageLine>[];
    for (final line in grouped) {
      if (line.section) continue;
      final body = line.body.trim();
      if (body.isEmpty) continue;
      final start = (line.startMs - cut.startMs).clamp(0, cut.durationMs);
      final end = (line.endMs - cut.startMs).clamp(start + 1, cut.durationMs);
      out.add(PassageLine(startMs: start, endMs: end, body: body));
    }
    return List<PassageLine>.unmodifiable(out);
  }

  /// The passage's words as SubRip, which is what a phone's video editor and
  /// every social uploader take.
  static String srt(List<PassageLine> lines) {
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i += 1) {
      final line = lines[i];
      out.writeln('${i + 1}');
      out.writeln('${_srtTime(line.startMs)} --> ${_srtTime(line.endMs)}');
      out.writeln(line.body);
      out.writeln();
    }
    return out.toString();
  }

  /// The passage's words as LRC, which is what karaoke players and most
  /// lyric-video tools read.
  ///
  /// A last stamp with nothing after it, at the end of the passage, so the
  /// final line clears the screen instead of sitting there for as long as the
  /// player is open.
  static String lrc(List<PassageLine> lines, {String? title}) {
    final out = StringBuffer();
    final named = title?.trim();
    if (named != null && named.isNotEmpty) out.writeln('[ti:$named]');
    for (final line in lines) {
      out.writeln('[${_lrcTime(line.startMs)}]${line.body}');
    }
    if (lines.isNotEmpty) out.writeln('[${_lrcTime(lines.last.endMs)}]');
    return out.toString();
  }

  /// The sheet's lines that the cut covers.
  ///
  /// A heading is kept when the part itself begins inside the cut. One with
  /// no time on it cannot be placed in a passage at all — the lines a room
  /// typed carry their sections at zero — and a heading over the wrong bars
  /// is worse than a passage with none, because the label is most of what a
  /// chart is read for.
  static List<MusicianSheetLine> linesOfPassage(
    List<MusicianSheetLine> lines,
    PassageCut cut,
  ) {
    return <MusicianSheetLine>[
      for (final line in lines)
        if (line.section
            ? line.endMs > line.startMs &&
                line.startMs >= cut.startMs &&
                line.startMs < cut.endMs
            : line.endMs > cut.startMs && line.startMs < cut.endMs)
          line,
    ];
  }

  /// The passage's chords as ChordPro, in the key the band plays the song in.
  ///
  /// The band's key and not the reader's, which is the one place this differs
  /// from printing a chart. How a person reads a song is theirs and stays on
  /// their phone (Every Musician, Same Song, 17 September 2026); a file going
  /// out to strangers beside a clip of the band has to be in the key the clip
  /// is in, or the chords under it are a semitone from what anybody hears.
  static String chordPro({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required PassageCut cut,
    String? musicalKey,
    double? bpm,
  }) {
    return ChordSheetExport.chordPro(
      project: project,
      lines: linesOfPassage(lines, cut),
      transpose: 0,
      musicalKey: musicalKey,
      bpm: bpm,
      // The reason first, so it reads as one paragraph under the sentence
      // ChordPro already writes about the words, and the passage's own name
      // under it where a chart puts a heading.
      notes: <String>[
        if (!ProjectExportService.wordsTravel(project)) recordingStaysHome,
        cut.label,
      ],
    );
  }

  /// Everything the cut hands over, written into [directory].
  ///
  /// Files rather than bytes, because this is how the takes export already
  /// leaves the app: written down and then given to the share sheet, which is
  /// the one path on a phone that reaches a video editor and the apps a post
  /// is made in. The caller keeps them out of a browser, where there is no
  /// directory to write into (see the Save button on the takes screen).
  ///
  /// Always at least the ChordPro: a passage of a song somebody else wrote is
  /// still a passage whose chords are the room's own work.
  static Future<List<File>> write({
    required Directory directory,
    required SongProject project,
    required PassageCut cut,
    required List<MusicianSheetLine> lines,
    List<TranscriptWord> transcriptWords = const <TranscriptWord>[],
    String? musicalKey,
    double? bpm,
    String? audioPath,
    int audioZeroMs = 0,
    int rate = Multitrack.rate,
  }) async {
    final travels = ProjectExportService.wordsTravel(project);
    final stem = fileStem(project, cut);
    final written = <File>[];

    if (travels && audioPath != null && audioPath.trim().isNotEmpty) {
      final source = await Multitrack.readRecording(audioPath);
      if (source != null) {
        final audio = File('${directory.path}/$stem.wav');
        await audio.writeAsBytes(
          wavFor(
            source: source,
            cut: cut,
            rate: rate,
            sourceZeroMs: audioZeroMs,
          ),
          flush: true,
        );
        written.add(audio);
      }
    }

    if (travels) {
      final passage = linesIn(transcriptWords, cut);
      if (passage.isNotEmpty) {
        written.add(await _text(directory, '$stem.srt', srt(passage)));
        written.add(
          await _text(directory, '$stem.lrc', lrc(passage, title: project.title)),
        );
      }
    }

    written.add(
      await _text(
        directory,
        '$stem.cho',
        chordPro(
          project: project,
          lines: lines,
          cut: cut,
          musicalKey: musicalKey,
          bpm: bpm,
        ),
      ),
    );
    return written;
  }

  /// What every file of one cut is called, without its extension: the song
  /// and the passage, so four files landing in a downloads folder beside last
  /// week's are still obviously one set.
  ///
  /// The dashes in "Bars 9–12" are turned into plain hyphens first, because
  /// [ProjectExportService.fileName] drops anything outside its allowed set
  /// and would otherwise leave "Bars-912".
  static String fileStem(SongProject project, PassageCut cut) {
    final title = ProjectExportService.fileName(project.title);
    final part = ProjectExportService.fileName(
      cut.label.replaceAll('–', '-').replaceAll('—', '-'),
      fallback: 'cut',
    );
    return '$title-$part';
  }

  static Future<File> _text(
    Directory directory,
    String name,
    String body,
  ) async {
    final file = File('${directory.path}/$name');
    // utf8 for the reason the takes export writes utf8: an em dash and a
    // curly apostrophe are both above 255, and every reader of these formats
    // expects utf8.
    await file.writeAsBytes(utf8.encode(body), flush: true);
    return file;
  }

  /// The downbeat a moment belongs to: the nearest one, or the moment itself
  /// where the grid does not reach.
  static int _onABarLine(List<int> downbeatsMs, int ms) {
    if (downbeatsMs.isEmpty) return ms;
    if (ms <= downbeatsMs.first || ms >= downbeatsMs.last) return ms;
    var best = downbeatsMs.first;
    for (final at in downbeatsMs) {
      if ((at - ms).abs() < (best - ms).abs()) best = at;
      // Ascending, so the first downbeat past the moment is the last one that
      // can be nearer than what has been seen already.
      if (at > ms) break;
    }
    return best;
  }

  /// "00:00:02,140" — hours, minutes, seconds and milliseconds, as SubRip
  /// spells them.
  static String _srtTime(int ms) {
    final safe = math.max(0, ms);
    final hours = safe ~/ 3600000;
    final minutes = (safe % 3600000) ~/ 60000;
    final seconds = (safe % 60000) ~/ 1000;
    final rest = safe % 1000;
    return '${_pad(hours, 2)}:${_pad(minutes, 2)}:${_pad(seconds, 2)},'
        '${_pad(rest, 3)}';
  }

  /// "00:02.14" — minutes, seconds and hundredths, as LRC spells them.
  static String _lrcTime(int ms) {
    final safe = math.max(0, ms);
    final minutes = safe ~/ 60000;
    final seconds = (safe % 60000) ~/ 1000;
    final hundredths = (safe % 1000) ~/ 10;
    return '${_pad(minutes, 2)}:${_pad(seconds, 2)}.${_pad(hundredths, 2)}';
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}

/// A passage of a song: where it runs, and what it was called on screen.
///
/// The label is the practice loop's own — "Bars 9–12", "Chorus 2", "Pickup" —
/// so the file names and the line at the top of the chart say the same thing
/// the chip said when it was chosen.
class PassageCut {
  const PassageCut({
    required this.startMs,
    required this.endMs,
    required this.label,
  });

  final int startMs;
  final int endMs;
  final String label;

  int get durationMs => endMs - startMs;
}

/// One line of the passage's words, counted from the start of the cut.
class PassageLine {
  const PassageLine({
    required this.startMs,
    required this.endMs,
    required this.body,
  });

  final int startMs;
  final int endMs;
  final String body;
}
