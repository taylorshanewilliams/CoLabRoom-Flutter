import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
  double gain = 1.0,
  bool enabled = true,
}) {
  return Take(
    id: id,
    path: '${_tmp.path}/$id.wav',
    label: id,
    recordedAt: DateTime(2026, 8, 25),
    part: part,
    performer: performer,
    offsetMs: offsetMs,
    gain: gain,
    enabled: enabled,
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

  test('layers are numbered so they sort in the order they were played', () async {
    final takes = <Take>[
      _take(id: 'a', part: TakePart.rhythm),
      _take(id: 'b', part: TakePart.lead, performer: 'Dylan'),
    ];
    for (final take in takes) {
      await _writeAudio(take, 0.2);
    }

    final out = await TakeExport.layerArchive(
      takes: takes,
      outputPath: '${_tmp.path}/layers.zip',
    );
    final archive = ZipDecoder().decodeBytes(await out!.readAsBytes());
    final wavs = archive.files
        .map((file) => file.name)
        .where((name) => name.endsWith('.wav'))
        .toList()
      ..sort();

    expect(wavs.first, startsWith('01_'));
    expect(wavs.last, startsWith('02_'));
    expect(wavs.last, contains('Dylans-lead'));
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
