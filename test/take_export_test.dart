import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/latency_probe.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/take_export.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _tmp;

Take _take({
  required String id,
  TakePart part = TakePart.other,
  String? performer,
  int offsetMs = 0,
  int startMs = 0,
  double gain = 1.0,
  bool enabled = true,
  String? label,
  bool namedByHand = false,
}) {
  return Take(
    id: id,
    path: '${_tmp.path}/$id.wav',
    label: label ?? id,
    recordedAt: DateTime(2026, 8, 25),
    part: part,
    performer: performer,
    offsetMs: offsetMs,
    startMs: startMs,
    gain: gain,
    enabled: enabled,
    namedByHand: namedByHand,
  );
}

Future<void> _writeAudio(Take take, double level) async {
  final samples = Float64List.fromList(List<double>.filled(4410, level));
  await File(take.path).writeAsBytes(LatencyProbe.toWav(samples), flush: true);
}

void main() {
  setUp(() async {
    _tmp = await Directory.systemTemp.createTemp('take_export');
  });

  tearDown(() async {
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
  });

  test('the mix is one file of the enabled layers', () async {
    final riff = _take(id: 'riff');
    final muted = _take(id: 'muted', enabled: false);
    await _writeAudio(riff, 0.3);
    await _writeAudio(muted, 0.3);

    final out = await TakeExport.mixdown(
      takes: <Take>[riff, muted],
      outputPath: '${_tmp.path}/mix.wav',
    );

    expect(out, isNotNull);
    final samples = LatencyProbe.fromWav(await out!.readAsBytes());
    expect(samples.length, 4410);
    // Only the enabled layer is in it.
    expect(samples[0], closeTo(0.3, 1e-4));
  });

  test('the archive keeps muted layers too', () async {
    // Somebody exporting to keep their work wants all of it. A layer switched
    // off today is still a take somebody played, and losing it would defeat
    // the point of the export existing.
    final riff = _take(id: 'riff', part: TakePart.rhythm);
    final idea = _take(id: 'idea', part: TakePart.lead, enabled: false);
    await _writeAudio(riff, 0.3);
    await _writeAudio(idea, 0.2);

    final out = await TakeExport.layerArchive(
      takes: <Take>[riff, idea],
      outputPath: '${_tmp.path}/layers.zip',
      songTitle: 'Mountains',
    );

    expect(out, isNotNull);
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    final names = archive.files.map((file) => file.name).toList();
    expect(names.where((name) => name.endsWith('.wav')).length, 2);
    expect(names, contains('mix-notes.txt'));
  });

  test('the pack names each file by song, part, tempo and key', () async {
    // The name is what somebody reads in a DAW's import dialog, next to
    // files from somewhere else. "02_bass.wav" does not survive that.
    final takes = <Take>[
      _take(id: 'a', part: TakePart.rhythm),
      _take(id: 'b', part: TakePart.bass, performer: 'Taylor'),
    ];
    for (final take in takes) {
      await _writeAudio(take, 0.2);
    }

    final out = await TakeExport.layerArchive(
      takes: takes,
      outputPath: '${_tmp.path}/layers.zip',
      songTitle: 'Tonight',
      bpm: 92,
      musicalKey: 'D',
    );
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    final names = archive.files.map((file) => file.name).toList();

    expect(names, contains('Tonight - Bass (Taylor) - 92bpm - D.wav'));
    expect(names, contains('Tonight - Rhythm - 92bpm - D.wav'));
  });

  test('two takes of the same part do not overwrite each other', () async {
    final takes = <Take>[
      _take(id: 'a', part: TakePart.vocal, performer: 'Kate'),
      _take(id: 'b', part: TakePart.vocal, performer: 'Kate'),
    ];
    for (final take in takes) {
      await _writeAudio(take, 0.2);
    }

    final out = await TakeExport.layerArchive(
      takes: takes,
      outputPath: '${_tmp.path}/layers.zip',
      songTitle: 'Tonight',
    );
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    final wavs = archive.files
        .map((file) => file.name)
        .where((name) => name.endsWith('.wav'))
        .toList();

    expect(wavs.toSet().length, 2);
    expect(wavs, contains('Tonight - Vocal (Kate).wav'));
    expect(wavs, contains('Tonight - Vocal (Kate) 2.wav'));
  });

  test('the tempo, the sections and how to import ride along', () async {
    final take = _take(id: 'a', part: TakePart.drums);
    await _writeAudio(take, 0.2);

    final out = await TakeExport.layerArchive(
      takes: <Take>[take],
      outputPath: '${_tmp.path}/layers.zip',
      songTitle: 'Tonight',
      bpm: 92,
      musicalKey: 'D',
      downbeatsMs: const <int>[0, 2609, 5217],
      sections: const <StructureSection>[
        StructureSection(startMs: 0, endMs: 5217, label: 'Verse'),
      ],
    );
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    final names = archive.files.map((file) => file.name).toList();

    expect(names, contains(TakeExport.tempoFileName));
    expect(names, contains('README.txt'));
    final readme = utf8.decode(
      archive.files.firstWhere((file) => file.name == 'README.txt').content,
    );
    expect(readme, contains('bar 1'));
    expect(readme, contains('92 bpm'));
    expect(readme, contains('in D'));
  });

  test('a song nobody has analyzed gets no invented tempo', () async {
    final take = _take(id: 'a');
    await _writeAudio(take, 0.2);

    final out = await TakeExport.layerArchive(
      takes: <Take>[take],
      outputPath: '${_tmp.path}/layers.zip',
      songTitle: 'Sketch',
    );
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    final names = archive.files.map((file) => file.name).toList();

    expect(names, isNot(contains(TakeExport.tempoFileName)));
    expect(names, contains('README.txt'));
  });

  group('lined up with the start of the song', () {
    test('a take that comes in at 1.5 s carries the silence in front of it',
        () {
      // The one thing a DAW cannot put back. Dropped at bar 1, the file has
      // to already know it was played a bar and a half in.
      final take = _take(id: 'late', startMs: 1500);
      final samples = Float64List.fromList(List<double>.filled(4410, 0.4));
      final aligned = TakeExport.alignedToSongStart(take, samples);

      expect(aligned.length, 66150 + 4410);
      expect(aligned[0], 0);
      expect(aligned[66149], 0);
      expect(aligned[66150], closeTo(0.4, 1e-9));
    });

    test('the latency trim comes off the front at the same time', () {
      // A second of silence in front, a tenth of a second off the back of
      // that silence: both numbers, applied the way the mixer applies them.
      final take = _take(id: 'late', startMs: 1000, offsetMs: 100);
      final samples = Float64List.fromList(List<double>.filled(8820, 0.4));
      final aligned = TakeExport.alignedToSongStart(take, samples);

      expect(aligned.length, 44100 + 8820 - 4410);
    });

    test('a trim longer than the take leaves nothing rather than crashing', () {
      final take = _take(id: 'short', offsetMs: 500);
      final samples = Float64List.fromList(List<double>.filled(441, 0.4));
      expect(TakeExport.alignedToSongStart(take, samples).length, 0);
    });
  });

  group('names every file system will keep', () {
    test('drops the characters Windows refuses', () {
      expect(
        TakeExport.safeFileName(r'Who? / What: "Now" <it> | goes*'),
        'Who What Now it goes',
      );
    });

    test('keeps no trailing dot or space, which Windows drops silently', () {
      expect(TakeExport.safeFileName('Take one. '), 'Take one');
    });

    test('a device name is still a device name with .wav after it', () {
      expect(TakeExport.safeFileName('con'), '_con');
      expect(TakeExport.safeFileName('LPT1'), '_LPT1');
    });

    test('a name made entirely of forbidden characters still gets one', () {
      expect(TakeExport.safeFileName('///'), 'take');
    });

    test('a sharp is spelled out rather than dropped', () {
      expect(TakeExport.safeFileName('Tonight - F♯ minor'), 'Tonight - F# minor');
    });

    test('a name somebody typed beats the part it was filed under', () {
      final take = _take(
        id: 'a',
        part: TakePart.lead,
        label: 'The big one',
        namedByHand: true,
        performer: 'Dylan',
      );
      expect(
        TakeExport.takeFileName(take: take, songTitle: 'Tonight'),
        'Tonight - The big one (Dylan)',
      );
    });

    test('an untitled sketch does not get "Untitled" in front of it', () {
      final take = _take(id: 'a', part: TakePart.keys);
      expect(TakeExport.takeFileName(take: take, songTitle: '  '), 'Keys');
    });
  });

  test('a missing file is skipped rather than fatal', () async {
    // A take whose audio has been cleaned up under it must not take the whole
    // export down with it — the other layers are still worth keeping.
    final present = _take(id: 'present');
    final gone = _take(id: 'gone');
    await _writeAudio(present, 0.3);

    final out = await TakeExport.layerArchive(
      takes: <Take>[present, gone],
      outputPath: '${_tmp.path}/layers.zip',
    );

    expect(out, isNotNull);
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    expect(archive.files.where((f) => f.name.endsWith('.wav')).length, 1);
  });

  test('nothing to export returns null instead of an empty zip', () async {
    final out = await TakeExport.layerArchive(
      takes: <Take>[_take(id: 'gone')],
      outputPath: '${_tmp.path}/layers.zip',
    );
    expect(out, isNull);
  });

  group('the note that rides along', () {
    test('records what is needed to rebuild the mix elsewhere', () {
      // Without the trims the layers do not line up on import, which would
      // make the export technically complete and practically useless.
      final notes = TakeExport.describeSession(
        takes: <Take>[
          _take(id: 'a', part: TakePart.rhythm, gain: 0.8),
          _take(
            id: 'b',
            part: TakePart.lead,
            performer: 'Dylan',
            offsetMs: 120,
            enabled: false,
          ),
        ],
        songTitle: 'Mountains',
      );

      expect(notes, contains('Mountains'));
      expect(notes, contains("Dylan's lead"));
      expect(notes, contains('volume 80%'));
      expect(notes, contains('trimmed 120 ms'));
      expect(notes, contains('muted in the last mix'));
    });

    test('an untitled sketch does not invent a title', () {
      final notes = TakeExport.describeSession(
        takes: <Take>[_take(id: 'a')],
        songTitle: '  ',
      );
      expect(notes, startsWith('CoLabRoom layers'));
    });
  });
}
