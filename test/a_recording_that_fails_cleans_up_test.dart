import 'dart:async';
import 'dart:io';

import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/spent_audio.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:colabroom/services/take_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A recording that fails cleans up after itself.
///
/// Three leaks, all on the way out of something that did not work, and all
/// of them silent — which is what this screen's history is about. The silent
/// upload failure cost three rounds of testing, and these are the same shape:
/// nothing on screen is wrong afterwards, and something is still running or
/// still on the phone.
///
/// - The catch in _record stopped the count's click and nothing else, so a
///   failure after the recorder started left the microphone open, recording
///   into a file nothing would ever play. The next press on Record then
///   opened a second recorder beside the first.
/// - The sweep of leftovers only knew the `_mix_` prefix, so a recording
///   backed out of part-way stayed on the phone for good.
///
/// The third of them, NowPlaying.play stopping the last track outside its own
/// try, is in a_player_that_will_not_stop_test.dart: it needs a file where no
/// widget has built an audio player first.
///
/// The microphone is faked here because the real one cannot be made to fail
/// on request, which is the same reason SpokenNoteRecorder is faked in
/// say_it_instead_of_typing_it_test.dart.

class _EmptyLayers extends SongLayerService {
  _EmptyLayers() : super(client: null);

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async =>
      const <SharedLayer>[];

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

/// A song with one part already in it, so that pressing Record builds a mix
/// — which is the only thing that sweeps the directory.
class _OneTake extends SongLayerService {
  _OneTake(this.localPath) : super(client: null);

  /// Where the take already is on this phone, so nothing has to be fetched.
  final String localPath;

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => <SharedLayer>[
        SharedLayer(
          // A layer id is a uuid, which is why the sweep can never mistake
          // one of the room's takes for a leftover.
          id: '7f1c0e3a-9d21-4a77-8c55-0b2f4e6d8a10',
          projectId: projectId,
          recordedBy: 'someone-else',
          storagePath: 'room-1/$projectId/layers/1.m4a',
          label: 'Guitar 1',
          part: TakePart.other,
          createdAt: DateTime(2026, 9, 19),
          sharedAt: DateTime(2026, 9, 19),
        ),
      ];

  @override
  Future<String> ensureLocal(SharedLayer layer) async => localPath;

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _NoAnalysis extends SongAnalysisService {
  _NoAnalysis() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
}

/// A microphone that opens, writes something, and can be told to fail.
class _Mic extends TakeRecorder {
  int starts = 0;
  int stops = 0;
  int cancels = 0;

  /// The file it was last told to write to.
  String? wrote;

  /// Whether starting ends in a throw. It stands for everything that can go
  /// wrong between the recorder running and the screen knowing it is
  /// recording — the song failing to come in, the count failing to hand over
  /// — because from here they are the same thing: a microphone that is open
  /// and a take that is not happening.
  bool failAfterStarting = false;

  /// Holds [stop] open, which is where the screen waits with a take on its
  /// way to the room. A real one is held open for as long as the upload
  /// takes, which on a long take over a slow connection is a while.
  Completer<void>? holdTheStop;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    starts += 1;
    wrote = path;
    await File(path).writeAsString('the first few bytes of a take');
    if (failAfterStarting) {
      throw StateError('the microphone would not start');
    }
  }

  @override
  Future<String?> stop() async {
    stops += 1;
    final hold = holdTheStop;
    if (hold != null) await hold.future;
    return wrote;
  }

  /// Counted, and deliberately does not delete the file. The real one does,
  /// but a recorder that has already been disposed with the screen does not,
  /// and the screen is the thing that has to be sure.
  @override
  Future<void> cancel() async {
    cancels += 1;
  }
}

Widget _screen(_Mic mic, {SongLayerService? layers}) => MaterialApp(
      home: SongLayersScreen(
        roomId: 'room-1',
        projectId: 'project-1',
        songTitle: 'Mountains',
        layerService: layers ?? _EmptyLayers(),
        analysisService: _NoAnalysis(),
        takeRecorder: mic,
      ),
    );

/// Nothing on screen, which is how a screen is left in a widget test.
const Widget _gone = MaterialApp(home: SizedBox.shrink());

/// Lets the real work happen.
///
/// Recording reads and writes real files, and a widget test runs on a fake
/// clock that real file work never comes back on. Each turn hands time back
/// to the machine and then pumps whatever came of it.
Future<void> _letItHappen(WidgetTester tester) async {
  for (var turn = 0; turn < 12; turn += 1) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
  }
  await tester.pump();
}

/// The player's own channels, answered with nothing so that the absence of
/// an audio plugin is quiet.
///
/// There is no audio in a widget test and nothing here needs any: the screen
/// builds a player, and its global set-up reports the missing plugin as an
/// error on whichever test happens to be running when real time turns. The
/// per-player channel is not among these because its name carries a player
/// id that only the screen knows; nothing reaches it, because the player is
/// never asked to play.
const List<MethodChannel> _audioChannels = <MethodChannel>[
  MethodChannel('xyz.luan/audioplayers.global'),
  MethodChannel('xyz.luan/audioplayers.global/events'),
];

void main() {
  late Directory documents;

  /// Parks the next ask for the app's documents directory.
  ///
  /// _record asks for it before it has written down the name of the file it
  /// is about to record into, which is the window this screen is leaky in:
  /// on a real phone the same window is _rebuildMix mixing every take in the
  /// song, or a bar being counted, both of them seconds long.
  Completer<void>? holdTheDirectory;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{
      // Already agreed to, so the disclosure does not stand in front of the
      // thing being tested. Agreeing to it is its own test elsewhere.
      'microphone_granted': true,
    });
    documents = await Directory.systemTemp.createTemp('colabroom_takes');
    holdTheDirectory = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        // Held once, for the test that leaves the screen during the run-up.
        final hold = holdTheDirectory;
        if (hold != null) {
          holdTheDirectory = null;
          await hold.future;
        }
        return documents.path;
      },
    );
    for (final channel in _audioChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    }
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    for (final channel in _audioChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    if (documents.existsSync()) {
      await documents.delete(recursive: true);
    }
  });

  group('a recording that fails', () {
    testWidgets('lets go of the microphone and says what happened',
        (tester) async {
      final mic = _Mic()..failAfterStarting = true;
      await tester.pumpWidget(_screen(mic));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);

      expect(mic.starts, 1);
      // The bug: only the count's click was stopped, so the recorder stayed
      // on the microphone.
      expect(mic.cancels, 1,
          reason: 'the recorder was left running after the failure');
      expect(File(mic.wrote!).existsSync(), isFalse,
          reason: 'the part-written recording was left on the phone');
      // Said in words, the way this screen says every other failure. A take
      // that does not happen and does not say so is the failure that cost
      // three rounds of testing.
      expect(find.textContaining('the microphone would not start'),
          findsOneWidget);

      // Closed the way a person closes it, so that nothing is left running
      // into the next test.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await _letItHappen(tester);
    });

    testWidgets('and the next press starts cleanly', (tester) async {
      final mic = _Mic()..failAfterStarting = true;
      await tester.pumpWidget(_screen(mic));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);

      // Pressing Record again used to open a second recorder while the first
      // was still running. It can only be pressed at all because the screen
      // stopped being busy, which is why the microphone has to be let go of
      // before that happens rather than after.
      mic.failAfterStarting = false;
      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);

      expect(mic.starts, 2);
      expect(find.textContaining('Stop'), findsOneWidget,
          reason: 'the second press did not start a recording');

      // Leaving mid-take gives up on it: the microphone is let go of, and
      // the file it was writing does not outlive the screen.
      final second = mic.wrote!;
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await _letItHappen(tester);

      expect(mic.cancels, 2);
      expect(File(second).existsSync(), isFalse,
          reason: 'backing out mid-take left the recording behind');
    });
  });

  group('a screen left during the run-up to a take', () {
    testWidgets('does not leave a microphone open behind it', (tester) async {
      final mic = _Mic();
      await tester.pumpWidget(_screen(mic));
      await tester.pumpAndSettle();

      // Pressed, and then held before the screen has written down what it is
      // recording into. Everything that makes this window long on a phone --
      // mixing the song's parts, counting a bar in -- happens here.
      final ready = Completer<void>();
      holdTheDirectory = ready;
      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);
      expect(mic.starts, 0, reason: 'the run-up was not held');

      // Back, while it is still getting ready. There is no file name yet, so
      // dispose() has nothing to give up on -- and the recorder it lets go of
      // is not the one that is about to open.
      await tester.pumpWidget(_gone);
      await _letItHappen(tester);

      ready.complete();
      await _letItHappen(tester);

      // The microphone opens, because the ask for it was already on its way,
      // and it is given up on at once. This is the leak the fix for the catch
      // block put back through the seam it needed: the recorder is made on
      // use, so a start() after dispose() built a second one that nothing
      // owned, nothing cancelled and nothing would ever dispose. It stayed
      // open, writing a file nobody would hear, until the app was killed.
      expect(mic.starts, 1);
      expect(mic.cancels, 1,
          reason: 'the microphone was left open after the screen went away');
      expect(File(mic.wrote!).existsSync(), isFalse,
          reason: 'the file it opened was left on the phone');
    });
  });

  group('a take on its way to the room', () {
    testWidgets('is not swept by the next visit to the same song',
        (tester) async {
      final mic = _Mic();
      await tester.pumpWidget(_screen(mic));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);
      final take = File(mic.wrote!);
      expect(take.existsSync(), isTrue);

      // Stop, and the upload holds the screen. _stop deliberately carries on
      // after the screen goes: a take somebody has played is the most
      // expensive thing this feature can lose.
      mic.holdTheStop = Completer<void>();
      // The same button, which says Stop while a take is running.
      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);
      expect(mic.stops, 1, reason: 'the take never reached the upload');

      // A recording from some earlier visit that nobody finished, which the
      // sweep is supposed to take.
      final abandoned = File('${take.parent.path}/new_1700000000000.m4a')
        ..writeAsStringSync('an abandoned recording');
      // And a take of the room's already on this phone, so that the second
      // visit has something to mix -- which is the only thing that sweeps.
      final roomsTake =
          File('${take.parent.path}/7f1c0e3a-9d21-4a77-8c55-0b2f4e6d8a10.m4a')
            ..writeAsStringSync('somebody else s part');

      // Out of Takes and straight back in, while the upload is still reading.
      await tester.pumpWidget(_gone);
      await _letItHappen(tester);
      await tester.pumpWidget(_screen(_Mic(), layers: _OneTake(roomsTake.path)));
      await _letItHappen(tester);
      await tester.tap(find.byKey(const Key('layers_record_button')));
      await _letItHappen(tester);

      expect(abandoned.existsSync(), isFalse,
          reason: 'the second visit never swept, so this proves nothing');
      // The one that matters. The guard on a take in flight used to live on
      // the screen that recorded it, and this is a different screen: its set
      // was empty, and the first mix it wrote deleted the take out from under
      // the upload that was still reading it.
      expect(take.existsSync(), isTrue,
          reason: 'a take still going up was swept by the next visit');
      expect(roomsTake.existsSync(), isTrue,
          reason: "a take of the room's was deleted");

      mic.holdTheStop!.complete();
      await _letItHappen(tester);
      await tester.pumpWidget(_gone);
      await _letItHappen(tester);
    });
  });

  group('a recorder let go of with its screen', () {
    test('does not quietly open another microphone', () async {
      // Never opened, so there is no plugin anywhere in this.
      final recorder = TakeRecorder();
      await recorder.dispose();

      // A concrete AudioRecorder gave this for free -- the plugin throws on
      // one that has been disposed -- and _record's catch has always relied
      // on it. Made on use, it built a fresh recorder instead.
      await expectLater(
        recorder.start(const RecordConfig(), path: 'nowhere.m4a'),
        throwsA(isA<StateError>()),
      );
      await expectLater(recorder.hasPermission(), throwsA(isA<StateError>()));
      // Except cancelling, which stays quiet: there is no recording left to
      // discard, and asking would be the very thing this stops.
      await recorder.cancel();
    });
  });

  group('what the sweep may take', () {
    test('an abandoned recording goes and one still going up stays', () async {
      final dir = await Directory.systemTemp.createTemp('colabroom_sweep');
      addTearDown(() async => dir.delete(recursive: true));

      File file(String name) =>
          File('${dir.path}/$name')..writeAsStringSync('some bytes');

      final abandoned = file('new_1700000000000.m4a');
      final itsDecodedCopy = file('new_1700000000000.m4a.pcm.wav');
      final goingUp = file('new_1700000009999.m4a');
      final oldMix = file('_mix_1_1.wav');
      final loadedMix = file('_mix_2_2.wav');
      final passage = file('_mix_then_and_now_3_3.wav');
      // A take of the room's, kept under its layer id, and the decode cached
      // beside it. Neither is this sweep's business.
      final take = file('7f1c0e3a-9d21-4a77-8c55-0b2f4e6d8a10.m4a');
      final takesCache = file('7f1c0e3a-9d21-4a77-8c55-0b2f4e6d8a10.m4a.pcm.wav');

      await sweepSpentAudio(
        dir,
        inUse: () => <String>{goingUp.path, loadedMix.path},
      );

      expect(abandoned.existsSync(), isFalse,
          reason: 'a recording nobody finished stayed on the phone for good');
      expect(itsDecodedCopy.existsSync(), isFalse);
      expect(oldMix.existsSync(), isFalse);
      expect(passage.existsSync(), isFalse);
      // The one that matters. A take on its way to the room is the only copy
      // of something somebody played.
      expect(goingUp.existsSync(), isTrue,
          reason: 'a take still going up was swept out from under the upload');
      expect(loadedMix.existsSync(), isTrue);
      expect(take.existsSync(), isTrue,
          reason: "a take of the room's was deleted");
      expect(takesCache.existsSync(), isTrue);
    });

    test('nothing else in the directory is spent', () {
      expect(isSpentAudio('new_1700000000000.m4a'), isTrue);
      expect(isSpentAudio('_mix_1_1.wav'), isTrue);
      // A layer id is a uuid and can begin with neither prefix, so the room's
      // own takes are never candidates.
      expect(isSpentAudio('7f1c0e3a-9d21-4a77-8c55-0b2f4e6d8a10.m4a'), isFalse);
      expect(isSpentAudio('reference.m4a'), isFalse);
      expect(isSpentAudio('newsong.m4a'), isFalse);
    });
  });
}
