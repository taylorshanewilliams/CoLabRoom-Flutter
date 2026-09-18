import 'dart:async';
import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/moment_note.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/timeline_ruler.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/spoken_note_recorder.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A moment note said instead of typed (0152).
///
/// Every Musician, Same Song, 17 September 2026, slice 23. A teacher with a
/// guitar in their hands would rather say "there -- lean back on the two and
/// four" than type it. The rules worth holding, and what breaks if they slip:
///
/// - The moment is where the playhead was when the finger went down, and
///   the note lands on the take the person chose, or it is a note about
///   nowhere.
/// - A failed upload says so. A note that fails to save and says nothing is
///   a note the teacher believes they left, which is the silent-upload
///   failure that cost three rounds of testing on takes.
/// - A tap is not a hold, a hold that heard nothing is not a note, and the
///   one-minute cap ends a note rather than throwing it away.

class _Takes extends SongLayerService {
  _Takes(this.layers) : super(client: null);

  final List<SharedLayer> layers;

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => layers;

  @override
  Future<String> ensureLocal(SharedLayer layer) async => '/tmp/${layer.id}.m4a';

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

/// A microphone that hands back whatever it was told to.
class _Mic extends SpokenNoteRecorder {
  _Mic({Uint8List? heard}) : heard = heard ?? Uint8List(4096);

  /// What stop() gives back. Four kilobytes is a real breath of wav; the
  /// screen refuses anything under a kilobyte as a tap.
  Uint8List? heard;

  /// When set, the permission answer waits on it, the way a real prompt
  /// does.
  Completer<bool>? permission;

  int starts = 0;
  int stops = 0;
  int cancels = 0;

  @override
  Future<bool> hasPermission() => permission?.future ?? Future<bool>.value(true);

  @override
  Future<void> start() async {
    starts += 1;
  }

  @override
  Future<Uint8List?> stop() async {
    stops += 1;
    return heard;
  }

  @override
  Future<void> cancel() async {
    cancels += 1;
  }

  @override
  Future<void> dispose() async {}
}

/// Storage that refuses the bytes.
class _StorageDown extends InMemoryMusicRepository {
  _StorageDown() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<MomentNote> addSpokenMomentNote({
    required String roomId,
    required String projectId,
    required int atMs,
    required Uint8List bytes,
    String? layerId,
  }) async {
    throw Exception('storage: 503');
  }
}

SharedLayer _layer({
  required String id,
  required String label,
  required String recordedBy,
  bool shared = true,
}) {
  return SharedLayer(
    id: id,
    projectId: 'song-1',
    recordedBy: recordedBy,
    storagePath: 'room-1/song-1/layers/$id.m4a',
    label: label,
    part: TakePart.other,
    durationMs: 200000,
    createdAt: DateTime(2026, 9, 17),
    sharedAt: shared ? DateTime(2026, 9, 17) : null,
  );
}

Future<void> _openTakes(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  required List<SharedLayer> layers,
  required _Mic mic,
  // Sideways is the faders, where a teacher listens to a student. The
  // buttons are in the bottom bar either way.
  bool sideways = false,
}) async {
  // The disclosure has already been agreed to, as it would be for anybody
  // who has recorded a take on this screen.
  SharedPreferences.setMockInitialValues(<String, Object>{
    'microphone_granted': true,
  });
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize =
      sideways ? const Size(1000, 460) : const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongLayersScreen(
        roomId: 'room-1',
        projectId: 'song-1',
        songTitle: 'Caro mio ben',
        layerService: _Takes(layers),
        analysisService: _NoAnalysis(),
        spokenNoteRecorder: mic,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Presses the say button and keeps the finger there.
Future<TestGesture> _hold(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(const Key('say_moment_note'))),
  );
  await tester.pump(const Duration(seconds: 1));
  return gesture;
}

/// The moment the pin button says the next note would land at.
String _playheadClock(WidgetTester tester) {
  final label = tester.widget<Text>(find.descendant(
    of: find.byKey(const Key('pin_moment_note')),
    matching: find.byType(Text),
  ));
  return label.data!.replaceFirst('Note at ', '');
}

void main() {
  group('holding the button', () {
    testWidgets('pins what you said at the moment you were at, on the take',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final mic = _Mic();
      await _openTakes(
        tester,
        repository,
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      // Somewhere into the song, which is what a person does before they
      // have something to say about it.
      await tester.tap(find.byType(TimelineRuler));
      await tester.pumpAndSettle();
      final clock = _playheadClock(tester);
      expect(clock, isNot('0:00'), reason: 'the playhead moved');

      final gesture = await _hold(tester);
      expect(mic.starts, 1);
      expect(find.textContaining('Saying it'), findsOneWidget,
          reason: 'the button says the microphone is open, and for how long');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(mic.stops, 1);

      // Which take, and whether to keep it -- and no box to type in, because
      // the note has already been said.
      expect(find.text('Said at $clock'), findsOneWidget);
      expect(find.byKey(const Key('moment_note_body')), findsNothing);
      expect(find.text('Throw it away'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      final notes = await repository.loadMomentNotes('song-1');
      expect(notes, hasLength(1));
      final note = notes.single;
      expect(note.isSpoken, isTrue);
      expect(note.body, isEmpty);
      expect(note.layerId, 'layer-sent',
          reason: 'a note has to be about one recording');
      expect(MomentNote.clockOf(note.atMs), clock,
          reason: 'the moment is where the playhead was when the finger went down');
      expect(await repository.loadSpokenNote(note), mic.heard);
      expect(find.byKey(Key('listen_moment_note_${note.id}')), findsOneWidget,
          reason: 'a spoken note joins the list with a way to hear it');
      expect(find.text('Listen'), findsOneWidget);
    });

    testWidgets('throwing it away throws it away', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final mic = _Mic();
      await _openTakes(
        tester,
        repository,
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      final gesture = await _hold(tester);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Throw it away'));
      await tester.pumpAndSettle();

      expect(await repository.loadMomentNotes('song-1'), isEmpty);
      expect(find.byKey(const Key('say_moment_note')), findsOneWidget,
          reason: 'and the button is ready for the next one');
    });

    testWidgets('the sheet offers the recordings you can be heard on',
        (tester) async {
      final mic = _Mic();
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
          _layer(id: 'layer-heard', label: 'Heard', recordedBy: 'preview-user'),
          _layer(
            id: 'layer-draft',
            label: 'Draft',
            recordedBy: 'preview-jess',
            shared: false,
          ),
        ],
      );

      final gesture = await _hold(tester);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ChoiceChip, 'Sent'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Heard'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Draft'), findsNothing,
          reason: 'nobody else can hear it, so there is nobody to tell');
    });
  });

  group('what is not a note', () {
    testWidgets('a tap, which lets go before the microphone opens',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final mic = _Mic()..permission = Completer<bool>();
      await _openTakes(
        tester,
        repository,
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('say_moment_note'))),
      );
      await gesture.up();
      await tester.pump();
      // The permission prompt answers after the finger has gone.
      mic.permission!.complete(true);
      await tester.pumpAndSettle();

      expect(mic.starts, 0,
          reason: 'a microphone opened under no finger has nothing to close it');
      expect(find.text('Nothing was heard. Hold the button while you speak.'),
          findsOneWidget);
      expect(await repository.loadMomentNotes('song-1'), isEmpty);
    });

    testWidgets('a hold that heard nothing', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      // A wav header and a breath.
      final mic = _Mic(heard: Uint8List(40));
      await _openTakes(
        tester,
        repository,
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      final gesture = await _hold(tester);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Nothing was heard. Hold the button while you speak.'),
          findsOneWidget);
      expect(find.textContaining('Said at'), findsNothing,
          reason: 'there is nothing to pin, so nothing is asked');
      expect(await repository.loadMomentNotes('song-1'), isEmpty);
    });
  });

  group('when the upload does not land', () {
    testWidgets('the screen says so, in plain words, and keeps no note',
        (tester) async {
      final repository = _StorageDown();
      final mic = _Mic();
      await _openTakes(
        tester,
        repository,
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      final gesture = await _hold(tester);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      // A refusal, not a crash report: what happened and what to do, with
      // no status code in it.
      expect(find.text('That one did not save. Hold and say it again.'),
          findsOneWidget);
      expect(find.textContaining('503'), findsNothing);
      expect(await repository.loadMomentNotes('song-1'), isEmpty);
      expect(find.text('Listen'), findsNothing,
          reason: 'no phantom row for a note that is not there');
      expect(find.byKey(const Key('say_moment_note')), findsOneWidget,
          reason: 'and the button is ready for the next try');
    });

    testWidgets('and says so sideways too, at the faders', (tester) async {
      // The say button is in the bottom bar, which does not rotate away,
      // so the note can be held sideways -- and the refusal was, until
      // now, drawn only by the portrait list. A teacher at the faders who
      // held the button and saw nothing would believe the note was left,
      // which is the silent failure the whole slice was warned about.
      final repository = _StorageDown();
      final mic = _Mic();
      await _openTakes(
        tester,
        repository,
        mic: mic,
        sideways: true,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      final gesture = await _hold(tester);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      expect(find.text('That one did not save. Hold and say it again.'),
          findsOneWidget);
      expect(find.byKey(const Key('takes_problem')), findsOneWidget);
      expect(await repository.loadMomentNotes('song-1'), isEmpty);
    });
  });

  group('the one-minute cap', () {
    testWidgets('ends the note the way letting go does', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final mic = _Mic();
      await _openTakes(
        tester,
        repository,
        mic: mic,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      final gesture = await _hold(tester);
      await tester.pump(MomentNote.spokenLimit);
      await tester.pump();

      expect(mic.stops, 1, reason: 'the microphone closed on its own');
      expect(find.textContaining('Said at'), findsOneWidget,
          reason: 'what was said up to the cap was said on purpose');

      // Letting go afterwards is not a second stop.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(mic.stops, 1);

      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();
      expect(await repository.loadMomentNotes('song-1'), hasLength(1));
    });
  });

  group('in the repository', () {
    test('a spoken note keeps its voice and gives it back', () async {
      final repository = InMemoryMusicRepository.seeded();
      final said = Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));
      final note = await repository.addSpokenMomentNote(
        roomId: 'room-1',
        projectId: 'song-1',
        layerId: 'layer-sent',
        atMs: 108000,
        bytes: said,
      );

      expect(note.isSpoken, isTrue);
      expect(note.body, isEmpty);
      expect(note.voicePath, startsWith('room-1/song-1/moments/'),
          reason: 'under the room and the song, where the storage policies look');
      expect(await repository.loadSpokenNote(note), said);
      expect((await repository.loadMomentNotes('song-1')).single.id, note.id);
      expect(await repository.loadMomentNotes('song-2'), isEmpty);
    });

    test('taking it back takes the voice with it', () async {
      final repository = InMemoryMusicRepository.seeded();
      final note = await repository.addSpokenMomentNote(
        roomId: 'room-1',
        projectId: 'song-1',
        atMs: 1000,
        bytes: Uint8List(2048),
      );
      await repository.deleteMomentNote(note);
      expect(await repository.loadMomentNotes('song-1'), isEmpty);
      expect(() => repository.loadSpokenNote(note), throwsStateError);
    });

    test('a typed note has no voice to load', () async {
      final repository = InMemoryMusicRepository.seeded();
      final note = await repository.addMomentNote(
        projectId: 'song-1',
        atMs: 1000,
        body: 'typed',
      );
      expect(note.isSpoken, isFalse);
      expect(() => repository.loadSpokenNote(note), throwsStateError);
    });
  });
}
