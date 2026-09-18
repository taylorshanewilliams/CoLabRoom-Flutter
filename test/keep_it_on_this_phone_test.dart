import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/features/songs/kept_here.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/services/kept_songs.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keep this song on your phone.
///
/// Every Musician, Same Song, 17 September 2026, slice 18. Basements, stages
/// and vans have no signal, and nothing about a song used to live on the
/// phone for longer than a temp file. A kept song is its words, its sheet
/// and its audio in the app's own storage, the way takes already are, and
/// Perform reads them there without knowing it is offline. Nothing about it
/// is shared, and a song that is not kept says so rather than opening as if
/// it had no recording.
///
/// Two stores appear below. The plain tests use the real one on a real
/// directory, with the bucket stubbed. The widget tests use an in-memory
/// one, because a widget test runs on a fake clock that a real file read
/// never comes back on; what they prove is that the screens ask the store
/// the right things, and the plain tests prove the store.

late Directory _tmp;

String _referenceFor(String id, [String name = 'reference_1']) =>
    'room-1/$id/analysis/$name.m4a';
String _vocalsFor(String id) => 'room-1/$id/stems/vocals.mp3';

const List<int> _recordingBytes = <int>[1, 2, 3, 4, 5, 6];
const List<int> _vocalsBytes = <int>[9, 9, 9];

/// The bucket, as far as a test is concerned: bytes by path, a note of every
/// path asked for, and paths it will refuse the way a phone with no signal
/// refuses everything.
class _Bucket {
  _Bucket(this.objects);

  final Map<String, List<int>> objects;
  final List<String> asked = <String>[];
  Set<String> refuse = <String>{};

  Future<Uint8List> download(String storagePath) async {
    asked.add(storagePath);
    if (refuse.contains(storagePath)) {
      throw const SocketException('Failed host lookup: supabase.co');
    }
    final bytes = objects[storagePath];
    if (bytes == null) throw StateError('No such object: $storagePath');
    return Uint8List.fromList(bytes);
  }
}

_Bucket _bucketFor(Iterable<String> ids) => _Bucket(<String, List<int>>{
      for (final id in ids) ...<String, List<int>>{
        _referenceFor(id): _recordingBytes,
        _vocalsFor(id): _vocalsBytes,
      },
    });

KeptSongs _keptIn(_Bucket bucket, {String? account = 'user-1'}) => KeptSongs(
      root: () async => _tmp,
      download: bucket.download,
      owner: () => account,
    );

/// The kept store with no disk under it, for the widget tests.
class _MemoryKept extends KeptSongs {
  _MemoryKept()
      : super(
          root: () async => throw StateError('No disk in a widget test.'),
          download: (_) async => throw StateError('No network in a widget test.'),
        );

  final Map<String, KeptSong> songs = <String, KeptSong>{};
  final Map<String, String> audio = <String, String>{};
  final List<String> kept = <String>[];

  static String _key(String projectId, String storagePath) => '$projectId|$storagePath';

  @override
  Future<String?> audioPath(String projectId, String storagePath) async =>
      audio[_key(projectId, storagePath)];

  @override
  Future<KeptSong?> load(String projectId) async => songs[projectId];

  @override
  Future<bool> isKept(String projectId) async => songs.containsKey(projectId);

  @override
  Future<List<SongProject>> list() async =>
      <SongProject>[for (final song in songs.values) song.project];

  @override
  Future<Set<String>> keptIds() async => songs.keys.toSet();

  @override
  Future<void> keep(
    SongProject project,
    SongAnalysisBundle sheet, {
    void Function(String stage)? onProgress,
  }) async {
    kept.add(project.id);
    songs[project.id] = KeptSong(project: project, sheet: sheet);
    final reference = sheet.reference;
    if (reference != null) {
      onProgress?.call('Fetching the recording…');
      audio[_key(project.id, reference.storagePath)] = '/kept/${project.id}/recording.m4a';
    }
    for (final stem in sheet.stems) {
      audio[_key(project.id, stem.storagePath)] = '/kept/${project.id}/${stem.kind.name}.mp3';
    }
  }

  @override
  Future<void> refresh(SongProject project, SongAnalysisBundle sheet) async {
    if (songs.containsKey(project.id)) await keep(project, sheet);
  }

  @override
  Future<void> remove(String projectId) async {
    songs.remove(projectId);
    audio.removeWhere((key, _) => key.startsWith('$projectId|'));
  }
}

final DateTime _when = DateTime(2026, 9, 18);

SongProject _project(String id, {String? keyOverride}) => SongProject(
      id: id,
      roomId: 'room-1',
      accountId: 'preview-user',
      title: 'Midnight Signal',
      createdAt: _when,
      updatedAt: _when,
      songOrigin: SongOrigin.ours,
      keyOverride: keyOverride,
      hasAudioReference: true,
      analysisState: SongAnalysisState.ready,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: id,
          authorId: 'preview-user',
          authorName: 'Taylor',
          body: 'Streetlights blur like a warning in the rain',
          colorValue: 0xFFFF8A4C,
          createdAt: _when,
          position: 1024,
        ),
        Contribution(
          id: 'line-2',
          projectId: id,
          authorId: 'preview-jess',
          authorName: 'Jess',
          body: 'Your frequency keeps calling out my name',
          colorValue: 0xFF3AD3FF,
          createdAt: _when,
          position: 2048,
          kind: ContributionKind.lyric,
          revision: 3,
        ),
      ],
    );

/// A recording the analysis heard a key, four bars, two chords, two parts
/// and a line of words in, with its vocals separated.
SongAnalysisBundle _analysis(String id, {String reference = 'reference_1'}) =>
    SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file-$id-$reference',
        storagePath: _referenceFor(id, reference),
        displayName: 'reference.m4a',
        state: SongAnalysisState.ready,
        durationMs: 8000,
        musicalKey: 'G',
        bpm: 120,
        beatsPerBar: 4,
        beatsMs: const <int>[0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500, 7000, 7500],
        downbeatsMs: const <int>[0, 2000, 4000, 6000],
        transcriptText: 'Streetlights blur like a warning in the rain',
        transcriptWords: const <TranscriptWord>[
          TranscriptWord(word: 'Streetlights', startMs: 0, endMs: 600),
          TranscriptWord(word: 'blur', startMs: 600, endMs: 1200),
          TranscriptWord(word: 'like', startMs: 1200, endMs: 1800),
          TranscriptWord(word: 'a', startMs: 1800, endMs: 2100),
          TranscriptWord(word: 'warning', startMs: 2100, endMs: 2700),
          TranscriptWord(word: 'in', startMs: 2700, endMs: 3000),
          TranscriptWord(word: 'the', startMs: 3000, endMs: 3300),
          TranscriptWord(word: 'rain', startMs: 3300, endMs: 3900),
        ],
        structureSections: const <StructureSection>[
          StructureSection(startMs: 0, endMs: 4000, label: 'Verse'),
          StructureSection(startMs: 4000, endMs: 8000, label: 'Chorus'),
        ],
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[
        ChordCue(id: 1, startMs: 0, endMs: 2000, chord: 'G:maj', confidence: 0.9),
        ChordCue(id: 2, startMs: 2000, endMs: 4000, chord: 'D/F#', confidence: 0.9, source: 'manual'),
      ],
      stems: <SongStem>[
        SongStem(projectId: id, kind: StemKind.vocals, storagePath: _vocalsFor(id), byteSize: 3),
      ],
    );

const SongAnalysisBundle _noRecording =
    SongAnalysisBundle(reference: null, lyricCues: <LyricSyncCue>[], chordCues: <ChordCue>[]);

/// The analysis service with the signal gone: the server answers nothing,
/// and the only recording to be had is one kept on this phone. Every
/// recording Perform resolved is noted, so a test can see where it came
/// from.
class _NoSignal extends SongAnalysisService {
  _NoSignal(KeptSongs kept) : super(client: null, kept: kept);

  final List<String> resolved = <String>[];

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      throw const SocketException('Failed host lookup: supabase.co');

  @override
  Future<String> ensureLocalReference(ReferenceTrack reference) async {
    final path = await super.ensureLocalReference(reference);
    resolved.add(path);
    return path;
  }
}

/// The same, on a phone whose temp cache is empty as well: what the real
/// loader comes to once the kept copy, the cache and the network have all
/// said no. Spelled out because a widget test cannot wait for path_provider
/// to fail -- that happens on the platform's clock, not the test's.
class _NothingAnywhere extends _NoSignal {
  _NothingAnywhere(super.kept);

  @override
  Future<String> ensureLocalReference(ReferenceTrack reference) async {
    final here = await kept.audioPath(reference.projectId, reference.storagePath);
    if (here != null) return here;
    throw const SocketException('Failed host lookup: supabase.co');
  }
}

/// One bar in a basement: the request goes out and nothing ever comes back.
class _Silent extends SongAnalysisService {
  _Silent(KeptSongs kept) : super(client: null, kept: kept);

  @override
  Future<SongAnalysisBundle> load(String projectId) => Completer<SongAnalysisBundle>().future;
}

/// The server answering, but with a no.
class _Refused extends SongAnalysisService {
  _Refused(KeptSongs kept) : super(client: null, kept: kept);

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      throw StateError('The server said no.');
}

/// The server answering, with each song's sheet.
class _Online extends SongAnalysisService {
  _Online(KeptSongs kept, this.sheets) : super(client: null, kept: kept);

  final Map<String, SongAnalysisBundle> sheets;

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      sheets[projectId] ?? _noRecording;
}

class _NoTakes extends SongLayerService {
  _NoTakes() : super(client: null);

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => const <SharedLayer>[];

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

/// The library that will not load: the app opened in the van.
class _NoLibrary extends InMemoryMusicRepository {
  _NoLibrary() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<MusicRoom>> loadRooms() async => throw StateError('No signal.');
}

/// Waits, in real time, for something the app does after it has answered.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 100; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Waited two seconds for something that did not happen.');
}

void _phone(WidgetTester tester, {Size size = const Size(390, 1100)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpPerform(
  WidgetTester tester, {
  required SongAnalysisBundle? analysis,
  required SongAnalysisService service,
  String? missing,
}) async {
  _phone(tester, size: const Size(520, 900));
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: LivePerformanceScreen(
      project: _project('song-1'),
      analysis: analysis,
      missing: missing,
      analysisService: service,
      layerService: _NoTakes(),
    ),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _closePerform(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUp(() async {
    _tmp = await Directory.systemTemp.createTemp('kept_songs');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
  });

  group('the kept copy', () {
    test('keeps the words, the sheet and the audio, and reads them back', () async {
      final bucket = _bucketFor(<String>['song-1']);
      final kept = _keptIn(bucket);
      final stages = <String>[];

      await kept.keep(_project('song-1', keyOverride: 'D major'), _analysis('song-1'),
          onProgress: stages.add);

      expect(stages, <String>['Fetching the recording…', 'Fetching the vocals…']);
      expect(bucket.asked, <String>[_referenceFor('song-1'), _vocalsFor('song-1')],
          reason: 'only what the sheet names, through this person\'s own session');
      expect(await kept.isKept('song-1'), isTrue);
      expect(await kept.isKept('song-2'), isFalse);
      expect(await kept.keptIds(), <String>{'song-1'});
      expect((await kept.list()).map((song) => song.title), <String>['Midnight Signal']);

      final back = (await kept.load('song-1'))!;
      expect(back.project.title, 'Midnight Signal');
      expect(back.project.roomId, 'room-1');
      expect(back.project.keyOverride, 'D major');
      expect(back.project.songOrigin, SongOrigin.ours);
      expect(back.project.analysisState, SongAnalysisState.ready);
      expect(back.project.contributions.map((line) => line.body), <String>[
        'Streetlights blur like a warning in the rain',
        'Your frequency keeps calling out my name',
      ]);
      expect(back.project.contributions[1].authorName, 'Jess');
      expect(back.project.contributions[1].position, 2048);
      expect(back.project.contributions[1].revision, 3);
      expect(back.project.contributions[1].colorValue, 0xFF3AD3FF);

      final sheet = back.sheet;
      expect(sheet.ready, isTrue);
      final reference = sheet.reference!;
      expect(reference.projectId, 'song-1');
      expect(reference.storagePath, _referenceFor('song-1'));
      expect(reference.musicalKey, 'G');
      expect(reference.bpm, 120);
      expect(reference.beatsPerBar, 4);
      expect(reference.durationMs, 8000);
      expect(reference.downbeatsMs, <int>[0, 2000, 4000, 6000]);
      expect(reference.beatsMs, hasLength(16));
      expect(reference.transcriptWords.map((word) => word.word).join(' '),
          'Streetlights blur like a warning in the rain');
      expect(reference.transcriptWords.last.startMs, 3300);
      expect(reference.structureSections.map((section) => section.label), <String>['Verse', 'Chorus']);
      expect(sheet.chordCues.map((cue) => cue.chord), <String>['G:maj', 'D/F#']);
      expect(sheet.chordCues[1].id, 2);
      expect(sheet.chordCues[1].isManual, isTrue, reason: 'a typed chord stays typed');
      expect(sheet.stems.single.kind, StemKind.vocals);
      expect(sheet.stems.single.storagePath, _vocalsFor('song-1'));

      final recording = await kept.audioPath('song-1', _referenceFor('song-1'));
      expect(recording, isNotNull);
      expect(await File(recording!).readAsBytes(), _recordingBytes);
      expect(recording, startsWith(_tmp.path), reason: 'in the app\'s own storage');
      expect(await File((await kept.audioPath('song-1', _vocalsFor('song-1')))!).readAsBytes(),
          _vocalsBytes);
      expect(await kept.audioPath('song-1', _referenceFor('song-1', 'reference_2')), isNull);
      expect(await kept.audioPath('song-2', _referenceFor('song-1')), isNull);
    });

    test('a keep cut off half-way is not kept, and keeping again fetches only what is missing',
        () async {
      final bucket = _bucketFor(<String>['song-1'])..refuse = <String>{_vocalsFor('song-1')};
      final kept = _keptIn(bucket);

      await expectLater(
        kept.keep(_project('song-1'), _analysis('song-1')),
        throwsA(isA<SocketException>()),
      );
      expect(await kept.isKept('song-1'), isFalse);
      expect(await kept.load('song-1'), isNull, reason: 'the sheet is written last');
      expect(await kept.keptIds(), isEmpty);
      expect(await kept.audioPath('song-1', _referenceFor('song-1')), isNotNull,
          reason: 'what was fetched stays');

      bucket
        ..refuse = <String>{}
        ..asked.clear();
      await kept.keep(_project('song-1'), _analysis('song-1'));
      expect(bucket.asked, <String>[_vocalsFor('song-1')]);
      expect(await kept.isKept('song-1'), isTrue);
    });

    test('a sheet whose recording is gone is not kept either', () async {
      final kept = _keptIn(_bucketFor(<String>['song-1']));
      await kept.keep(_project('song-1'), _analysis('song-1'));
      await File((await kept.audioPath('song-1', _referenceFor('song-1')))!).delete();

      expect(await kept.isKept('song-1'), isFalse);
      expect(await kept.load('song-1'), isNotNull,
          reason: 'the words and the sheet are still there to read');
    });

    test('a song with no recording keeps its words and its sheet alone', () async {
      final bucket = _Bucket(<String, List<int>>{});
      final kept = _keptIn(bucket);
      await kept.keep(_project('song-1'), _noRecording);

      expect(bucket.asked, isEmpty);
      expect(await kept.isKept('song-1'), isTrue);
      expect((await kept.load('song-1'))!.sheet.reference, isNull);
    });

    test('taking it off leaves nothing', () async {
      final kept = _keptIn(_bucketFor(<String>['song-1']));
      await kept.keep(_project('song-1'), _analysis('song-1'));
      await kept.remove('song-1');

      expect(await kept.isKept('song-1'), isFalse);
      expect(await kept.list(), isEmpty);
      expect(await kept.audioPath('song-1', _referenceFor('song-1')), isNull);
      expect(await Directory('${_tmp.path}/kept/user-1/song-1').exists(), isFalse);
      // And nothing to take off is not a failure.
      await kept.remove('never-kept');
    });

    test('a kept song is the account\'s that kept it, and nobody else\'s on this phone',
        () async {
      // Unlike a take on disk, a kept song is reached with no server to ask,
      // so the phone itself has to know whose it is.
      final bucket = _bucketFor(<String>['song-1']);
      await _keptIn(bucket).keep(_project('song-1'), _analysis('song-1'));

      final somebodyElse = _keptIn(bucket, account: 'user-2');
      expect(await somebodyElse.isKept('song-1'), isFalse);
      expect(await somebodyElse.list(), isEmpty);
      expect(await somebodyElse.load('song-1'), isNull);
      expect(await somebodyElse.audioPath('song-1', _referenceFor('song-1')), isNull);
      // Taking it off as somebody else takes nothing off.
      await somebodyElse.remove('song-1');

      final signedOut = _keptIn(bucket, account: null);
      expect(await signedOut.list(), isEmpty);
      expect(await signedOut.load('song-1'), isNull);
      expect(await signedOut.audioPath('song-1', _referenceFor('song-1')), isNull);
      await expectLater(
        signedOut.keep(_project('song-1'), _analysis('song-1')),
        throwsA(isA<StateError>()),
      );

      // Signed back in, it is where it was left.
      expect(await _keptIn(bucket).isKept('song-1'), isTrue);
    });

    test('deleting an account takes its kept songs off this phone, and only its own',
        () async {
      final bucket = _bucketFor(<String>['song-1', 'song-2']);
      final mine = _keptIn(bucket);
      final theirs = _keptIn(bucket, account: 'user-2');
      await mine.keep(_project('song-1'), _analysis('song-1'));
      await mine.keep(_project('song-2'), _analysis('song-2'));
      await theirs.keep(_project('song-1'), _analysis('song-1'));

      await mine.removeAll();

      expect(await mine.list(), isEmpty);
      expect(await mine.audioPath('song-1', _referenceFor('song-1')), isNull);
      expect(await theirs.isKept('song-1'), isTrue);
      // Nobody signed in has nothing to take off, and says nothing about it.
      await _keptIn(bucket, account: null).removeAll();
      expect(await theirs.isKept('song-1'), isTrue);
    });

    test('a replaced recording replaces the kept one, and a song not kept is left alone',
        () async {
      final bucket = _Bucket(<String, List<int>>{
        _referenceFor('song-1'): _recordingBytes,
        _referenceFor('song-1', 'reference_2'): <int>[7, 7],
        _vocalsFor('song-1'): _vocalsBytes,
      });
      final kept = _keptIn(bucket);

      // Not kept: the server's answer is not written anywhere.
      await kept.refresh(_project('song-1'), _analysis('song-1'));
      expect(bucket.asked, isEmpty);
      expect(await kept.isKept('song-1'), isFalse);

      await kept.keep(_project('song-1'), _analysis('song-1'));
      // What the mixer leaves beside a recording it has decoded, which is
      // worth keeping for as long as the recording is: the van is no place
      // to decode a whole song again.
      final recording = (await kept.audioPath('song-1', _referenceFor('song-1')))!;
      final vocals = (await kept.audioPath('song-1', _vocalsFor('song-1')))!;
      await File('$recording.pcm.wav').writeAsBytes(<int>[0, 0]);
      await File('$vocals.pcm.wav').writeAsBytes(<int>[0, 0]);
      await kept.refresh(_project('song-1'), _analysis('song-1'));
      expect(await File('$recording.pcm.wav').exists(), isTrue);

      bucket.asked.clear();
      await kept.refresh(_project('song-1').copyWith(title: 'Midnight Signal (live)'),
          _analysis('song-1', reference: 'reference_2'));

      expect(await File('$recording.pcm.wav').exists(), isFalse,
          reason: 'a decoded copy goes with the recording it was decoded from');
      expect(await File('$vocals.pcm.wav').exists(), isTrue);
      expect(bucket.asked, <String>[_referenceFor('song-1', 'reference_2')],
          reason: 'the stem was already here');
      expect(await kept.audioPath('song-1', _referenceFor('song-1', 'reference_2')), isNotNull);
      expect(await kept.audioPath('song-1', _referenceFor('song-1')), isNull,
          reason: 'a kept song is never bigger than the song');
      final back = (await kept.load('song-1'))!;
      expect(back.project.title, 'Midnight Signal (live)');
      expect(back.sheet.reference!.storagePath, _referenceFor('song-1', 'reference_2'));
    });
  });

  group('Perform without signal', () {
    test('the door hands Perform the kept sheet, or says what is missing', () async {
      final kept = _keptIn(_bucketFor(<String>['song-1']));

      final nothing = await _NoSignal(kept).sheetForPerform(_project('song-1'));
      expect(nothing.bundle, isNull);
      expect(nothing.fromThisPhone, isFalse);
      expect(nothing.missing, KeptSongs.notKeptOffline);

      final refused = await _Refused(kept).sheetForPerform(_project('song-1'));
      expect(refused.bundle, isNull);
      expect(refused.missing, KeptSongs.sheetNotLoaded);

      await kept.keep(_project('song-1'), _analysis('song-1'));
      final service = _NoSignal(kept);
      final here = await service.sheetForPerform(_project('song-1'));
      expect(here.fromThisPhone, isTrue);
      expect(here.missing, isNull);
      expect(here.bundle!.reference!.downbeatsMs, <int>[0, 2000, 4000, 6000]);
      // The refusal falls back the same way: a kept song plays.
      expect((await _Refused(kept).sheetForPerform(_project('song-1'))).fromThisPhone, isTrue);

      // And the recording comes from this phone, not the temp cache and not
      // the network, neither of which exists here.
      final path = await service.ensureLocalReference(here.bundle!.reference!);
      expect(path, startsWith(_tmp.path));
      expect(await File(path).readAsBytes(), _recordingBytes);
      expect(await service.ensureLocalStem(here.bundle!.stems.single), startsWith(_tmp.path));
    });

    test('the server answering brings the kept copy up to date', () async {
      final bucket = _Bucket(<String, List<int>>{
        _referenceFor('song-1'): _recordingBytes,
        _referenceFor('song-1', 'reference_2'): <int>[7, 7],
        _vocalsFor('song-1'): _vocalsBytes,
      });
      final kept = _keptIn(bucket);
      await kept.keep(_project('song-1'), _analysis('song-1'));

      final service = _Online(kept, <String, SongAnalysisBundle>{
        'song-1': _analysis('song-1', reference: 'reference_2'),
      });
      final sheet = await service.sheetForPerform(_project('song-1'));
      expect(sheet.fromThisPhone, isFalse);
      expect(sheet.bundle!.reference!.storagePath, _referenceFor('song-1', 'reference_2'));
      await _until(() async =>
          await kept.audioPath('song-1', _referenceFor('song-1', 'reference_2')) != null);
      expect((await kept.load('song-1'))!.sheet.reference!.storagePath,
          _referenceFor('song-1', 'reference_2'));
    });

    testWidgets('a kept song does not wait long on a server that is not answering',
        (tester) async {
      final kept = _MemoryKept();
      await kept.keep(_project('song-1'), _analysis('song-1'));

      PerformSheet? sheet;
      unawaited(_Silent(kept).sheetForPerform(_project('song-1')).then((value) => sheet = value));
      await tester.pump(SongAnalysisService.keptAnswersAfter - const Duration(seconds: 1));
      expect(sheet, isNull, reason: 'the server is asked first, and given a moment');
      await tester.pump(const Duration(seconds: 2));
      expect(sheet, isNotNull);
      expect(sheet!.fromThisPhone, isTrue);
      expect(sheet!.bundle!.reference!.downbeatsMs, <int>[0, 2000, 4000, 6000]);

      // A song that is not kept has nothing else to open with, and waits
      // for the server exactly as long as it always did.
      PerformSheet? other;
      unawaited(
          _Silent(_MemoryKept()).sheetForPerform(_project('song-2')).then((value) => other = value));
      await tester.pump(const Duration(seconds: 30));
      expect(other, isNull);
    });

    testWidgets('a kept song plays with its sheet and its beats', (tester) async {
      final kept = _MemoryKept();
      await kept.keep(_project('song-1'), _analysis('song-1'));
      final service = _NoSignal(kept);
      final sheet = await service.sheetForPerform(_project('song-1'));
      expect(sheet.fromThisPhone, isTrue);

      await _pumpPerform(tester, analysis: sheet.bundle, service: service, missing: sheet.missing);
      expect(tester.takeException(), isNull);

      // The sheet: its words, in synced mode because they carry timing.
      expect(find.text('Streetlights'), findsOneWidget);
      expect(find.text('rain'), findsOneWidget);
      expect(find.byKey(const Key('live_mode_synced')), findsOneWidget);
      // The beats: bars can be looped, which needs the downbeats.
      await tester.scrollUntilVisible(
        find.byKey(const Key('live_loop_bars')),
        80,
        scrollable: find
            .descendant(
                of: find.byKey(const Key('live_practice_row')),
                matching: find.byType(Scrollable))
            .first,
      );
      expect(find.byKey(const Key('live_loop_bars')), findsOneWidget);
      // The recording: from this phone, and nothing said about anything
      // missing.
      expect(service.resolved, <String>['/kept/song-1/recording.m4a']);
      expect(find.text(KeptSongs.notKeptOffline), findsNothing);
      expect(find.text(recordingNotLoaded), findsNothing);

      await _closePerform(tester);
    });

    testWidgets('a song that is not kept says so, and keeps the words', (tester) async {
      final service = _NoSignal(_MemoryKept());
      final sheet = await service.sheetForPerform(_project('song-1'));
      expect(sheet.missing, KeptSongs.notKeptOffline);

      await _pumpPerform(tester, analysis: sheet.bundle, service: service, missing: sheet.missing);
      expect(tester.takeException(), isNull);

      expect(find.text(KeptSongs.notKeptOffline), findsOneWidget);
      expect(find.textContaining('Streetlights'), findsWidgets, reason: 'the words are here');
      expect(find.byKey(const Key('live_loop_bars')), findsNothing);
      expect(service.resolved, isEmpty);

      await _closePerform(tester);
    });

    testWidgets('a recording that will not fetch is said, not swallowed', (tester) async {
      // The sheet arrived a moment before the signal went; the recording
      // did not, and there is no copy here.
      final service = _NothingAnywhere(_MemoryKept());

      await _pumpPerform(tester, analysis: _analysis('song-1'), service: service);
      expect(tester.takeException(), isNull);

      expect(find.text(recordingNotLoaded), findsOneWidget);
      expect(service.resolved, isEmpty);

      await _closePerform(tester);
    });
  });

  group('keeping it', () {
    Future<MusicBetaController> boot(
      WidgetTester tester,
      KeptSongs kept,
      Widget home, {
      InMemoryMusicRepository? repository,
    }) async {
      final controller =
          MusicBetaController(repository ?? InMemoryMusicRepository.seeded(), kept: kept);
      await controller.load();
      addTearDown(controller.dispose);
      _phone(tester);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
      ));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('the song offers to keep itself, says it is here, and takes it off again',
        (tester) async {
      final kept = _MemoryKept();
      final service = _Online(kept, <String, SongAnalysisBundle>{'song-1': _analysis('song-1')});
      await boot(tester, kept, SongWorkspaceScreen(projectId: 'song-1', analysisService: service));

      await tester.tap(find.byKey(const Key('song_options_menu')));
      await tester.pumpAndSettle();
      expect(find.text('Keep on this phone'), findsOneWidget);
      expect(find.text('On this phone'), findsNothing);

      await tester.tap(find.text('Keep on this phone'));
      await tester.pumpAndSettle();
      expect(await kept.isKept('song-1'), isTrue);
      expect(kept.songs['song-1']!.sheet.reference!.storagePath, _referenceFor('song-1'),
          reason: 'the sheet is fetched fresh, not taken from the toolbar');
      expect(kept.songs['song-1']!.project.title, 'Midnight Signal');
      expect(find.text('Midnight Signal is on this phone.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('song_options_menu')));
      await tester.pumpAndSettle();
      expect(find.text('On this phone'), findsOneWidget);
      expect(find.text('Keep on this phone'), findsNothing);

      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();
      expect(await kept.isKept('song-1'), isFalse);
      expect(find.text('Midnight Signal is no longer kept on this phone.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no connection keeps nothing, and says so', (tester) async {
      final kept = _MemoryKept();
      await boot(tester, kept,
          SongWorkspaceScreen(projectId: 'song-1', analysisService: _NoSignal(kept)));

      await tester.tap(find.byKey(const Key('song_options_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep on this phone'));
      await tester.pumpAndSettle();

      expect(await kept.isKept('song-1'), isFalse);
      expect(kept.kept, isEmpty);
      expect(find.text('No connection, so nothing was kept. Try again where there is signal.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a set keeps every song in it, and takes them all off', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final setup = MusicBetaController(repository);
      await setup.load();
      final second = await setup.createSong(setup.rooms.first, 'Second Song');
      final set = await setup.createSetlist('Saturday');
      await setup.addProjectsToSetlist(set, <String>['song-1', second.id]);
      setup.dispose();

      final kept = _MemoryKept();
      final service = _Online(kept, <String, SongAnalysisBundle>{
        'song-1': _analysis('song-1'),
        second.id: _analysis(second.id),
      });
      await boot(
        tester,
        kept,
        SetlistDetailScreen(setlistId: set.id, analysisService: service),
        repository: repository,
      );

      await tester.tap(find.byTooltip('Setlist options'));
      await tester.pumpAndSettle();
      expect(find.text('Keep this set on this phone'), findsOneWidget);
      await tester.tap(find.text('Keep this set on this phone'));
      await tester.pumpAndSettle();

      expect(kept.kept, <String>['song-1', second.id], reason: 'in the set\'s order');
      expect(await kept.isKept('song-1'), isTrue);
      expect(await kept.isKept(second.id), isTrue);
      expect(find.text('Saturday is on this phone.'), findsOneWidget);

      await tester.tap(find.byTooltip('Setlist options'));
      await tester.pumpAndSettle();
      expect(find.text('On this phone'), findsOneWidget);
      await tester.tap(find.text('On this phone'));
      await tester.pumpAndSettle();

      expect(await kept.isKept('song-1'), isFalse);
      expect(await kept.isKept(second.id), isFalse);
      expect(find.text('Saturday is no longer kept on this phone.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('where a phone with no signal lands', () {
    // The app waits for the library before it builds anything else, so a
    // phone opened in the van never reaches the Songs tab: it lands on the
    // screen that says the workspace could not be opened. KeptHere is the
    // part of that screen this slice adds.
    Widget landing(SongAnalysisService service) => MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(child: KeptHere(analysisService: service)),
          ),
        );

    testWidgets('the kept songs are there, and one opens in Perform from this phone',
        (tester) async {
      final kept = _MemoryKept();
      await kept.keep(_project('song-1'), _analysis('song-1'));
      final service = _NoSignal(kept);
      _phone(tester);

      await tester.pumpWidget(landing(service));
      await tester.pumpAndSettle();
      expect(find.text('On this phone'), findsOneWidget);
      expect(find.text('Midnight Signal'), findsOneWidget);

      await tester.tap(find.byKey(const Key('kept_song_song-1')));
      await tester.pumpAndSettle();
      expect(find.byType(LivePerformanceScreen), findsOneWidget);
      expect(find.text('Streetlights'), findsOneWidget);
      expect(find.text(KeptSongs.notKeptOffline), findsNothing);
      expect(find.text(recordingNotLoaded), findsNothing);
      expect(service.resolved, <String>['/kept/song-1/recording.m4a']);
      expect(tester.takeException(), isNull);

      await _closePerform(tester);
    });

    testWidgets('nothing kept draws nothing, so the screen is the one it always was',
        (tester) async {
      await tester.pumpWidget(landing(_NoSignal(_MemoryKept())));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kept_here')), findsNothing);
      expect(find.text('On this phone'), findsNothing);
    });

    testWidgets('a song taken off since the list was drawn says so instead of opening',
        (tester) async {
      final kept = _MemoryKept();
      await kept.keep(_project('song-1'), _analysis('song-1'));
      _phone(tester);
      await tester.pumpWidget(landing(_NoSignal(kept)));
      await tester.pumpAndSettle();

      await kept.remove('song-1');
      await tester.tap(find.byKey(const Key('kept_song_song-1')));
      await tester.pumpAndSettle();

      expect(find.byType(LivePerformanceScreen), findsNothing);
      expect(find.text('That song is no longer on this phone.'), findsOneWidget);
      expect(find.byKey(const Key('kept_here')), findsNothing, reason: 'and the list catches up');
    });
  });

  group('the library and the kept songs', () {
    test('a library that does not load drops nothing', () async {
      final kept = _keptIn(_bucketFor(<String>['song-gone']));
      await kept.keep(_project('song-gone'), _noRecording);

      final controller = MusicBetaController(_NoLibrary(), kept: kept);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.error, isNotNull);

      // Long enough for a drop to have happened if one were coming.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await kept.isKept('song-gone'), isTrue,
          reason: 'a song missing from a library that did not load is not missing');
    });

    test('a kept song this person can no longer open is dropped once the library loads',
        () async {
      final kept = _keptIn(_bucketFor(<String>['song-1']));
      await kept.keep(_project('song-1'), _analysis('song-1'));
      await kept.keep(_project('song-gone'), _noRecording);
      expect(await kept.keptIds(), <String>{'song-1', 'song-gone'});

      final controller = MusicBetaController(InMemoryMusicRepository.seeded(), kept: kept);
      addTearDown(controller.dispose);
      await controller.load();

      await _until(() async => !(await kept.keptIds()).contains('song-gone'));
      expect(await kept.keptIds(), <String>{'song-1'});
      expect(await kept.isKept('song-1'), isTrue);
    });
  });
}
