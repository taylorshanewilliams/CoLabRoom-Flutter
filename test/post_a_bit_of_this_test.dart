import 'dart:io';
import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/passage_export.dart';
import 'package:colabroom/services/latency_probe.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/project_export_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Post a bit of this.
///
/// Every Musician, Same Song, 17 September 2026, creators item 2: a creator's
/// audience is on TikTok and Instagram and the app is the room behind the
/// post. The DAW pack exports whole takes and the chart prints the whole
/// song; until now nothing cut the eight bars somebody wanted to put up.
///
/// Four things have to hold. The cut begins and ends on bar lines, with its
/// fades inside them rather than reaching for audio it did not ask for. The
/// words come out as SRT and LRC counted from the cut, not from the song,
/// because that is the only way they line up against the clip they ship
/// with. A song the room did not write hands over its chords and nothing
/// else. And a song with no words at all still hands over the audio and the
/// chords rather than refusing.

final DateTime _when = DateTime(2026, 9, 18);

/// Six bars of two seconds each, the way a beat tracker emits them.
const List<int> _downbeats = <int>[0, 2000, 4000, 6000, 8000, 10000];

SongProject _song({SongOrigin? origin, String title = 'Midnight Signal'}) =>
    SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'account-1',
      title: title,
      createdAt: _when,
      updatedAt: _when,
      songOrigin: origin,
    );

ChordCue _cue(String chord, int startMs) => ChordCue(
      startMs: startMs,
      endMs: startMs + 1800,
      chord: chord,
      confidence: 0.9,
    );

MusicianSheetLine _sung(
  String body, {
  required int startMs,
  required List<ChordCue> chords,
  int msPerWord = 500,
}) {
  final words =
      body.split(' ').where((word) => word.isNotEmpty).toList(growable: false);
  return MusicianSheetLine(
    contributionId: null,
    body: words.join(' '),
    section: false,
    startMs: startMs,
    endMs: startMs + words.length * msPerWord,
    chords: chords,
    approximateTiming: false,
    wordStartsMs: <int>[
      for (var index = 0; index < words.length; index += 1)
        startMs + index * msPerWord,
    ],
  );
}

TranscriptWord _word(String word, int startMs, int endMs) =>
    TranscriptWord(word: word, startMs: startMs, endMs: endMs);

/// A steady tone the whole way through, with one sample marked so the test
/// can say exactly which moment of the song landed where in the cut.
Float64List _source({
  required int durationMs,
  int? markAtMs,
  double mark = -0.75,
  int rate = Multitrack.rate,
}) {
  final samples = Float64List((durationMs * rate / 1000).round());
  for (var i = 0; i < samples.length; i += 1) {
    samples[i] = 0.5;
  }
  if (markAtMs != null) {
    samples[(markAtMs * rate / 1000).round()] = mark;
  }
  return samples;
}

/// A real wav on disk, which is what [PassageExport.write] decodes.
File _wavFile(Directory directory, Float64List samples) {
  final file = File('${directory.path}/recording.wav');
  file.writeAsBytesSync(
    LatencyProbe.toWav(samples, rate: Multitrack.rate),
    flush: true,
  );
  return file;
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('colabroom_cut_test');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('the cut lands on the bar lines', () {
    test('a section is pulled onto the downbeats either side of it', () {
      // Where the analysis heard the chorus: a little late at the front and a
      // little early at the back, which is what a chorus heard rather than
      // counted always looks like.
      final cut = PassageExport.cutFor(
        startMs: 2040,
        endMs: 7960,
        label: 'Chorus 2',
        downbeatsMs: _downbeats,
      );
      expect(cut, isNotNull);
      expect(_downbeats, contains(cut!.startMs));
      expect(_downbeats, contains(cut.endMs));
      expect(cut.startMs, 2000);
      expect(cut.endMs, 8000);
      expect(cut.durationMs, 6000);
    });

    test('a run of bars is already on them and does not move', () {
      final cut = PassageExport.cutFor(
        startMs: 4000,
        endMs: 8000,
        label: 'Bars 3–4',
        downbeatsMs: _downbeats,
      );
      expect(cut!.startMs, 4000);
      expect(cut.endMs, 8000);
    });

    test('the end of the last bar is the end of the recording', () {
      // barEndMs gives the final bar the end of the song, because there is no
      // next downbeat. Snapping that back to the last bar line would drop the
      // very bar somebody asked for.
      final cut = PassageExport.cutFor(
        startMs: 8000,
        endMs: 11500,
        label: 'Bars 5–6',
        downbeatsMs: _downbeats,
      );
      expect(cut!.startMs, 8000);
      expect(cut.endMs, 11500);
    });

    test('the fades sit inside the cut, and the middle is untouched', () {
      final cut = PassageExport.cutFor(
        startMs: 2040,
        endMs: 7960,
        label: 'Chorus 2',
        downbeatsMs: _downbeats,
      )!;
      final samples = PassageExport.samplesFor(
        // Marked at four seconds of the song, which is two seconds into a cut
        // that begins on the bar line at two.
        source: _source(durationMs: 12000, markAtMs: 4000),
        cut: cut,
      );

      // Exactly as long as the passage, so the subtitle times counted from
      // the cut line up against it.
      expect(
        samples.length,
        (cut.durationMs * Multitrack.rate / 1000).round(),
      );

      final ramp = (PassageExport.fadeMs * Multitrack.rate / 1000).round();
      expect(samples.first, 0);
      expect(samples.last, 0);
      // Rising, and done well before the passage is: the fade is a de-click,
      // not a swell over the downbeat.
      expect(samples[ramp ~/ 2], greaterThan(0));
      expect(samples[ramp ~/ 2], lessThan(0.5));
      expect(samples[ramp], 0.5);
      expect(samples[samples.length - 1 - ramp], 0.5);
      expect(ramp * 2, lessThan(samples.length));

      // The moment four seconds into the song is two seconds into the cut.
      expect(samples[(2000 * Multitrack.rate / 1000).round()], -0.75);
    });

    test('a take is cut at the same moment of the song as the recording', () {
      // A take punched in at four seconds, recorded 120 ms behind what it
      // played. Sample zero of its file is therefore 3.88 s into the song.
      final take = Take(
        id: 'take-1',
        path: 'take.m4a',
        label: 'Harmony',
        recordedAt: _when,
        startMs: 4000,
        offsetMs: 120,
      );
      expect(PassageExport.songZeroOf(take), 3880);

      final cut = PassageCut(startMs: 6000, endMs: 8000, label: 'Bars 4–5');
      final samples = PassageExport.samplesFor(
        // Marked where the take's own recording is at the moment the song is
        // at six seconds: 6000 - 3880 = 2120 ms into the file.
        source: _source(durationMs: 8000, markAtMs: 3000),
        cut: cut,
        sourceZeroMs: PassageExport.songZeroOf(take),
      );
      // Song time 3000 + 3880 = 6880, which is 880 ms into the cut.
      expect(samples[(880 * Multitrack.rate / 1000).round()], -0.75);
    });

    test('a passage shorter than its bar is still cut where it was asked',
        () {
      final cut = PassageExport.cutFor(
        startMs: 2100,
        endMs: 2400,
        label: 'Bar 2',
        downbeatsMs: _downbeats,
      );
      expect(cut!.startMs, 2100);
      expect(cut.endMs, 2400);
    });
  });

  group('the words of the passage', () {
    final words = <TranscriptWord>[
      _word('Before', 500, 900),
      _word('the', 1000, 1300),
      _word('night', 2400, 2800),
      _word('comes', 2900, 3300),
      _word('down', 3350, 3700),
      // A breath, so the sheet breaks the line here and so does the subtitle
      // file.
      _word('again', 4800, 5300),
      _word('After', 8600, 9000),
    ];
    final cut = PassageCut(startMs: 2000, endMs: 8000, label: 'Chorus 2');

    test('only what is sung inside it, counted from the cut', () {
      final lines = PassageExport.linesIn(words, cut);
      expect(lines.length, 2);
      expect(lines.first.body, 'night comes down');
      expect(lines.first.startMs, 400);
      expect(lines.first.endMs, 1700);
      expect(lines.last.body, 'again');
      expect(lines.last.startMs, 2800);
      expect(lines.last.endMs, 3300);
    });

    test('as SRT, timed from the start of the clip', () {
      final srt = PassageExport.srt(PassageExport.linesIn(words, cut));
      expect(srt, contains('00:00:00,400 --> 00:00:01,700'));
      expect(srt, contains('night comes down'));
      expect(srt, contains('00:00:02,800 --> 00:00:03,300'));
      expect(srt, startsWith('1\n'));
      expect(srt, contains('\n2\n'));
      // Nothing from outside the passage.
      expect(srt, isNot(contains('Before')));
      expect(srt, isNot(contains('After')));
    });

    test('as LRC, timed the same way', () {
      final lrc = PassageExport.lrc(
        PassageExport.linesIn(words, cut),
        title: 'Midnight Signal',
      );
      expect(lrc, contains('[ti:Midnight Signal]'));
      expect(lrc, contains('[00:00.40]night comes down'));
      expect(lrc, contains('[00:02.80]again'));
      // A last stamp with nothing after it, so the final line clears.
      expect(lrc.trimRight(), endsWith('[00:03.30]'));
      expect(lrc, isNot(contains('Before')));
    });

    test('a word straddling the edge is kept and clamped, not dropped', () {
      final lines = PassageExport.linesIn(
        <TranscriptWord>[_word('over', 1900, 2300)],
        cut,
      );
      expect(lines.single.body, 'over');
      expect(lines.single.startMs, 0);
    });
  });

  group('whose song it is decides what travels', () {
    final words = <TranscriptWord>[
      _word('Kestrel', 2400, 2900),
      _word('weather', 3000, 3600),
    ];
    final lines = <MusicianSheetLine>[
      _sung('Kestrel weather', startMs: 2400, chords: <ChordCue>[
        _cue('C:maj', 2000),
        _cue('G:maj', 3000),
      ]),
    ];

    test("somebody else's song exports the chords and nothing else",
        () async {
      final audio = _wavFile(directory, _source(durationMs: 12000));
      final files = await PassageExport.write(
        directory: directory,
        project: _song(origin: SongOrigin.cover),
        cut: PassageCut(startMs: 2000, endMs: 4000, label: 'Bars 2–3'),
        lines: lines,
        transcriptWords: words,
        musicalKey: 'C major',
        audioPath: audio.path,
      );

      expect(files.length, 1);
      final only = files.single;
      expect(only.path, endsWith('.cho'));
      final text = only.readAsStringSync();
      // The chords are the room's own work and go.
      expect(text, contains('[C]'));
      expect(text, contains('[G]'));
      // The words and the recording are not.
      expect(text, isNot(contains('Kestrel')));
      expect(text, contains(ProjectExportService.wordsStayHome));
      expect(text, contains(PassageExport.recordingStaysHome));
      // The two reasons read as one paragraph, and the passage is named under
      // them the way a chart names the part it is.
      expect(
        text.indexOf(ProjectExportService.wordsStayHome),
        lessThan(text.indexOf(PassageExport.recordingStaysHome)),
      );
      expect(text, contains('{comment: Bars 2–3}'));
      expect(
        directory
            .listSync()
            .whereType<File>()
            .map((file) => file.path)
            .where((path) => path.endsWith('.srt') || path.endsWith('.lrc')),
        isEmpty,
      );
      // Only the source recording this test wrote itself, never a cut of it.
      expect(
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.wav'))
            .map((file) => file.uri.pathSegments.last),
        <String>['recording.wav'],
      );
    });

    test('our own song exports the audio, the words and the chords',
        () async {
      final audio = _wavFile(directory, _source(durationMs: 12000));
      final files = await PassageExport.write(
        directory: directory,
        project: _song(origin: SongOrigin.ours),
        cut: PassageCut(startMs: 2000, endMs: 4000, label: 'Bars 2–3'),
        lines: lines,
        transcriptWords: words,
        musicalKey: 'C major',
        audioPath: audio.path,
      );

      final names = files.map((file) => file.uri.pathSegments.last).toList();
      expect(names, contains('Midnight-Signal-Bars-2-3.wav'));
      expect(names, contains('Midnight-Signal-Bars-2-3.srt'));
      expect(names, contains('Midnight-Signal-Bars-2-3.lrc'));
      expect(names, contains('Midnight-Signal-Bars-2-3.cho'));

      final cut = files.firstWhere((file) => file.path.endsWith('.wav'));
      final samples = LatencyProbe.fromWav(cut.readAsBytesSync());
      expect(samples.length, (2000 * Multitrack.rate / 1000).round());
      expect(samples.first, 0);

      final chart = files.firstWhere((file) => file.path.endsWith('.cho'));
      final text = chart.readAsStringSync();
      expect(text, contains('Kestrel'));
      expect(text, contains('{comment: Bars 2–3}'));
      expect(text, isNot(contains(PassageExport.recordingStaysHome)));
    });

    test('a song nobody has been asked about hands over the chart only',
        () async {
      // Whose song this is gets asked the first time a song's audience moves
      // past "Only you", so every song somebody is still working on alone
      // has no answer on it. A cut is made to be posted, and it is the one
      // way out of the app that does not pass the dial that asks — so an
      // unanswered question is not an answer here either, the same rule
      // sending a song to a lesson already keeps.
      final audio = _wavFile(directory, _source(durationMs: 12000));
      final files = await PassageExport.write(
        directory: directory,
        project: _song(),
        cut: const PassageCut(startMs: 2000, endMs: 4000, label: 'Bars 2–3'),
        lines: lines,
        transcriptWords: words,
        musicalKey: 'C major',
        audioPath: audio.path,
      );

      expect(files.length, 1);
      expect(files.single.path, endsWith('.cho'));
      final text = files.single.readAsStringSync();
      expect(text, contains(PassageExport.whoseSongUnanswered));
      expect(text, contains('[C]'));
      // The printed chart's own rule is untouched: it carries the words of a
      // song nobody has been asked about, as it always has. What waits for
      // an answer is the clip and the subtitles that would go on it.
      expect(text, contains('Kestrel'));
      expect(
        directory
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .where((name) =>
                name.endsWith('.wav') ||
                name.endsWith('.srt') ||
                name.endsWith('.lrc')),
        <String>['recording.wav'],
      );
    });

    test('a song with no words exports the audio and the chords only',
        () async {
      final audio = _wavFile(directory, _source(durationMs: 12000));
      final files = await PassageExport.write(
        directory: directory,
        project: _song(origin: SongOrigin.ours, title: 'Long Way Round'),
        cut: PassageCut(startMs: 2000, endMs: 6000, label: 'Bars 2–3'),
        lines: <MusicianSheetLine>[
          _sung(
            '$instrumentalMark $instrumentalMark',
            startMs: 2000,
            chords: <ChordCue>[_cue('A:min', 2000), _cue('F:maj', 4000)],
            msPerWord: 2000,
          ),
        ],
        musicalKey: 'A minor',
        audioPath: audio.path,
      );

      final names = files.map((file) => file.uri.pathSegments.last).toList();
      expect(names, contains('Long-Way-Round-Bars-2-3.wav'));
      expect(names, contains('Long-Way-Round-Bars-2-3.cho'));
      expect(names.where((name) => name.endsWith('.srt')), isEmpty);
      expect(names.where((name) => name.endsWith('.lrc')), isEmpty);

      final text = files
          .firstWhere((file) => file.path.endsWith('.cho'))
          .readAsStringSync();
      expect(text, contains('[Am]'));
      expect(text, contains('[F]'));
      // A placeholder is not a word, on paper or in a file.
      expect(text, isNot(contains(instrumentalMark)));
    });
  });

  group('the clip is the point, so the cut says when it has none', () {
    final lines = <MusicianSheetLine>[
      _sung('Kestrel weather', startMs: 2400, chords: <ChordCue>[
        _cue('C:maj', 2000),
      ]),
    ];

    test('a recording that will not read leaves a cut that knows it', () async {
      // A 24-bit wav is the everyday version of this: fromWav reads 16-bit
      // and nothing else, so the decode comes back with nothing. So does a
      // recording that has not finished fetching, and one that failed.
      final broken = File('${directory.path}/broken.wav');
      broken.writeAsBytesSync(
        Uint8List.fromList(<int>[82, 73, 70, 70, 0, 0, 0, 0]),
        flush: true,
      );
      final project = _song(origin: SongOrigin.ours);
      final files = await PassageExport.write(
        directory: directory,
        project: project,
        cut: const PassageCut(startMs: 2000, endMs: 4000, label: 'Bars 2–3'),
        lines: lines,
        musicalKey: 'C major',
        audioPath: broken.path,
      );

      // The chart still goes: it is the room's own work either way.
      expect(files.map((file) => file.path.endsWith('.cho')), <bool>[true]);
      // And the screen has something to say rather than handing over a text
      // file and calling it a clip.
      expect(PassageExport.audioMissing(project, files), isTrue);
    });

    test('a cut that has its clip says nothing about it', () async {
      final project = _song(origin: SongOrigin.ours);
      final files = await PassageExport.write(
        directory: directory,
        project: project,
        cut: const PassageCut(startMs: 2000, endMs: 4000, label: 'Bars 2–3'),
        lines: lines,
        musicalKey: 'C major',
        audioPath: _wavFile(directory, _source(durationMs: 12000)).path,
      );
      expect(PassageExport.audioMissing(project, files), isFalse);
    });

    test("a cover was never going to have one, so it is not missing", () async {
      final project = _song(origin: SongOrigin.cover);
      final files = await PassageExport.write(
        directory: directory,
        project: project,
        cut: const PassageCut(startMs: 2000, endMs: 4000, label: 'Bars 2–3'),
        lines: lines,
        musicalKey: 'C major',
        audioPath: _wavFile(directory, _source(durationMs: 12000)).path,
      );
      expect(PassageExport.audioMissing(project, files), isFalse);
    });
  });

  group('the cut is at the rate the recording is at', () {
    test('a 48 kHz bounce is cut where the bars are', () async {
      // A band's own DAW bounce is commonly 48 kHz, and a wav never goes
      // near the decoder that would otherwise hand everything back at 44.1.
      // Believing 44.1 of it would start this cut at 18.4 s instead of 20 s
      // -- on no bar line at all -- and play it a tone and a half flat under
      // a chart that says the band's key.
      const rate = 48000;
      final bounce = File('${directory.path}/bounce.wav');
      bounce.writeAsBytesSync(
        LatencyProbe.toWav(
          _source(durationMs: 30000, markAtMs: 22000, rate: rate),
          rate: rate,
        ),
        flush: true,
      );
      expect(await PassageExport.rateOf(bounce.path), rate);

      final files = await PassageExport.write(
        directory: directory,
        project: _song(origin: SongOrigin.ours, title: 'Long Way Round'),
        cut: const PassageCut(startMs: 20000, endMs: 28000, label: 'Bars 9–12'),
        lines: const <MusicianSheetLine>[],
        musicalKey: 'C major',
        audioPath: bounce.path,
      );

      final bytes = files
          .firstWhere((file) => file.path.endsWith('.wav'))
          .readAsBytesSync();
      // Written at the rate it was read at, so it plays at the pitch it was
      // played at.
      expect(LatencyProbe.rateOfWav(bytes), rate);
      final samples = LatencyProbe.fromWav(bytes);
      expect(samples.length, (8000 * rate / 1000).round());
      // Twenty-two seconds of the song is two seconds into a cut that starts
      // at twenty, whatever rate the file holds its samples at.
      expect(samples[(2000 * rate / 1000).round()], closeTo(-0.75, 0.001));
    });

    test('anything compressed is at the rate the decoder was asked for', () {
      // m4a, mp3, opus: Multitrack.samplesFor asks the decoder for
      // Multitrack.rate, so there is nothing to read off a header.
      expect(PassageExport.rateOf('song.m4a'), completion(Multitrack.rate));
      expect(PassageExport.rateOf('song.mp3'), completion(Multitrack.rate));
    });
  });

  group("the chart is the passage, in the band's key", () {
    test('only the lines the cut covers, and its heading', () {
      final lines = <MusicianSheetLine>[
        _sung('before the cut', startMs: 0, chords: <ChordCue>[_cue('C:maj', 0)]),
        MusicianSheetLine(
          contributionId: null,
          body: 'Chorus',
          section: true,
          startMs: 2000,
          endMs: 8000,
          chords: const <ChordCue>[],
          approximateTiming: false,
        ),
        _sung('inside the cut', startMs: 2400, chords: <ChordCue>[_cue('G:maj', 2400)]),
        _sung('after the cut', startMs: 9000, chords: <ChordCue>[_cue('F:maj', 9000)]),
      ];
      final kept = PassageExport.linesOfPassage(
        lines,
        const PassageCut(startMs: 2000, endMs: 8000, label: 'Chorus 2'),
      );
      expect(kept.map((line) => line.body), <String>['Chorus', 'inside the cut']);
    });

    test('an untimed heading is left out rather than put over wrong bars', () {
      final lines = <MusicianSheetLine>[
        const MusicianSheetLine(
          contributionId: 'a',
          body: 'Verse',
          section: true,
          startMs: 0,
          endMs: 0,
          chords: <ChordCue>[],
          approximateTiming: false,
        ),
        _sung('inside the cut', startMs: 100, chords: <ChordCue>[_cue('G:maj', 100)]),
      ];
      final kept = PassageExport.linesOfPassage(
        lines,
        const PassageCut(startMs: 0, endMs: 4000, label: 'Bars 1–2'),
      );
      expect(kept.map((line) => line.body), <String>['inside the cut']);
    });

    test("the chords are in the band's key, never this phone's reading", () {
      // The song is in C. Nothing here is transposed by whoever is reading:
      // a file going out beside a clip has to be in the key the clip is in.
      final text = PassageExport.chordPro(
        project: _song(origin: SongOrigin.ours),
        lines: <MusicianSheetLine>[
          _sung('one two', startMs: 0, chords: <ChordCue>[_cue('C:maj', 0)]),
        ],
        cut: const PassageCut(startMs: 0, endMs: 2000, label: 'Bar 1'),
        musicalKey: 'C major',
      );
      expect(text, contains('{key: C}'));
      expect(text, contains('[C]one'));
    });
  });

  group('Perform offers the cut once a passage is on repeat', () {
    const bundle = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-1',
        fileId: 'file',
        storagePath: 'room/song-1/reference.m4a',
        displayName: 'Midnight Signal.m4a',
        state: SongAnalysisState.ready,
        durationMs: 12000,
        downbeatsMs: _downbeats,
        transcriptText: 'night comes down',
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'night', startMs: 2400, endMs: 2800),
          TranscriptWord(word: 'comes', startMs: 2900, endMs: 3300),
          TranscriptWord(word: 'down', startMs: 3350, endMs: 3700),
        ],
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    testWidgets('no chip until something is on repeat, then one', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // Wide enough that the whole practice row is laid out: it is a
      // horizontal list, and a chip scrolled off the end is never built.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: _song(origin: SongOrigin.ours),
          analysis: bundle,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // A cut is always of a passage, so there is nothing to offer until one
      // is chosen.
      expect(find.byKey(const Key('live_save_cut')), findsNothing);

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_bar_loop_apply')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('live_save_cut')), findsOneWidget);
      expect(find.text('Save this bit'), findsOneWidget);
    });

    testWidgets('a song nobody has been asked about is asked first',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        // No answer on it, which is every song still at "Only you".
        home: LivePerformanceScreen(project: _song(), analysis: bundle),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_bar_loop_apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_save_cut')));
      await tester.pumpAndSettle();

      // The question is asked here, at the moment it matters, exactly as the
      // audience dial asks it -- because a cut is the one export that
      // reaches strangers without passing the dial.
      expect(find.text('Who wrote this song?'), findsOneWidget);
      expect(find.byKey(const Key('whose_song_ours')), findsOneWidget);
    });
  });
}
