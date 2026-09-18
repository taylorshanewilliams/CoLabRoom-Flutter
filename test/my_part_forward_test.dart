import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/my_part.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Your part forward, or everyone but you.
///
/// Every Musician, Same Song, 17 September 2026, slice 17. A choir learns
/// its alto line and a band learns a harmony from the takes the room
/// already has: that take up and the rest down, or that take left out. The
/// choice is this phone's alone -- the room's faders never move -- and a
/// song with one take, or none, offers nothing.

const String _reference = 'reference';

Take _take(
  String id, {
  double gain = 1,
  bool enabled = true,
  String label = '',
  String? performer,
  TakePart part = TakePart.vocal,
  bool namedByHand = false,
}) {
  return Take(
    id: id,
    path: '/tmp/$id.m4a',
    label: label,
    recordedAt: DateTime(2026, 9, 17),
    gain: gain,
    enabled: enabled,
    part: part,
    performer: performer,
    namedByHand: namedByHand,
  );
}

SharedLayer _layer(String id, String label, String performer, {double gain = 1}) {
  return SharedLayer(
    id: id,
    projectId: 'project-1',
    recordedBy: 'account-$id',
    storagePath: 'room-1/project-1/layers/$id.m4a',
    label: label,
    part: TakePart.vocal,
    performer: performer,
    gain: gain,
    createdAt: DateTime(2026, 9, 17),
  );
}

/// The choir's takes, and a record of every level anybody tried to write.
class _ChoirLayers extends SongLayerService {
  _ChoirLayers(this.layers) : super(client: null);

  final List<SharedLayer> layers;
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => layers;

  @override
  Future<String> ensureLocal(SharedLayer layer) async => '/tmp/${layer.id}.m4a';

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}

  @override
  Future<void> updateLayer(SharedLayer layer, Map<String, dynamic> patch) async {
    writes.add(patch);
  }
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

/// A song with its own recording, already on the phone.
class _RecordedSong extends SongAnalysisService {
  _RecordedSong() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async => SongAnalysisBundle(
        reference: ReferenceTrack(
          projectId: projectId,
          fileId: 'file-1',
          storagePath: 'room-1/project-1/analysis/reference.m4a',
          displayName: 'The recording',
          state: SongAnalysisState.ready,
        ),
        lyricCues: const <LyricSyncCue>[],
        chordCues: const <ChordCue>[],
      );

  @override
  Future<String> ensureLocalReference(ReferenceTrack reference) async =>
      '/tmp/reference.m4a';
}

void main() {
  group('the mix', () {
    final takes = <Take>[
      _take(_reference, gain: 0.8),
      _take('alto', gain: 1.0),
      _take('tenor', gain: 1.2),
    ];

    test('forward lifts the part and drops the rest, the recording included', () {
      final heard = MyPartMix.apply(
        takes,
        const MyPart(takeId: 'alto', way: MyPartWay.forward),
      );
      expect(heard.map((take) => take.id), <String>[_reference, 'alto', 'tenor']);
      expect(heard[0].gain, closeTo(0.8 * MyPartMix.behind, 1e-9));
      expect(heard[1].gain, closeTo(1.0 * MyPartMix.forward, 1e-9));
      expect(heard[2].gain, closeTo(1.2 * MyPartMix.behind, 1e-9));
      expect(heard.every((take) => take.enabled), isTrue);
      // Clearly on top, with the rest still there to hear it against.
      expect(MyPartMix.forward / MyPartMix.behind, greaterThan(3));
    });

    test('everyone but you leaves that take out and the rest as they were', () {
      final heard = MyPartMix.apply(
        takes,
        const MyPart(takeId: 'alto', way: MyPartWay.without),
      );
      expect(heard[1].enabled, isFalse);
      expect(heard[0].enabled, isTrue);
      expect(heard[0].gain, 0.8);
      expect(heard[2].enabled, isTrue);
      expect(heard[2].gain, 1.2);
    });

    test('a part brought forward is heard even if its lane was muted', () {
      final heard = MyPartMix.apply(
        <Take>[_take('alto', enabled: false), _take('tenor')],
        const MyPart(takeId: 'alto', way: MyPartWay.forward),
      );
      expect(heard[0].enabled, isTrue);
      expect(heard[0].gain, MyPartMix.forward);
    });

    test("nobody else's levels are touched", () {
      final before = takes.map((take) => take.gain).toList();
      MyPartMix.apply(takes, const MyPart(takeId: 'alto', way: MyPartWay.forward));
      MyPartMix.apply(takes, const MyPart(takeId: 'alto', way: MyPartWay.without));
      expect(takes.map((take) => take.gain).toList(), before);
      expect(takes.every((take) => take.enabled), isTrue);
      // No choice is the room's mix, untouched.
      expect(identical(MyPartMix.apply(takes, null), takes), isTrue);
    });

    test('a choice naming a take that has gone changes nothing', () {
      // Kept on the phone, then the take was deleted from the room.
      final heard = MyPartMix.apply(
        takes,
        const MyPart(takeId: 'bass', way: MyPartWay.forward),
      );
      expect(identical(heard, takes), isTrue);
    });
  });

  group('what is offered', () {
    test('a song with one take, or none, offers nothing', () {
      expect(MyPartMix.offered(const <Take>[], referenceId: _reference), isEmpty);
      expect(MyPartMix.offered(<Take>[_take('alto')], referenceId: _reference), isEmpty);
      expect(
        MyPartMix.offered(<Take>[_take(_reference)], referenceId: _reference),
        isEmpty,
      );
      // The recording is what a part is heard against, not a part: one take
      // over the record still has nothing to be forward of but the record.
      expect(
        MyPartMix.offered(<Take>[_take(_reference), _take('alto')], referenceId: _reference),
        isEmpty,
      );
    });

    test('two takes offer both, and never the recording', () {
      final offered = MyPartMix.offered(
        <Take>[_take(_reference), _take('alto'), _take('tenor')],
        referenceId: _reference,
      );
      expect(offered.map((take) => take.id), <String>['alto', 'tenor']);
    });
  });

  group('the part and the person', () {
    test('a typed part name gets the person after a dash', () {
      expect(
        TakeNaming.partAndPerson(
          _take('a', label: 'Alto 2', performer: 'Jess', namedByHand: true),
        ),
        'Alto 2 — Jess',
      );
    });

    test('a name that already says who is left alone', () {
      expect(
        TakeNaming.partAndPerson(
          _take('a', label: "Jess's harmony", performer: 'Jess', namedByHand: true),
        ),
        "Jess's harmony",
      );
      expect(
        TakeNaming.partAndPerson(_take('a', part: TakePart.lead, performer: 'Dylan')),
        "Dylan's lead",
      );
    });

    test('nobody credited is the part alone', () {
      expect(
        TakeNaming.partAndPerson(_take('a', label: 'Alto 2', namedByHand: true)),
        'Alto 2',
      );
    });

    test('the chips say which way', () {
      const forward = MyPart(takeId: 'a', way: MyPartWay.forward);
      const without = MyPart(takeId: 'a', way: MyPartWay.without);
      expect(forward.label('Alto 2 — Jess'), 'Alto 2 — Jess forward');
      expect(without.label('Alto 2 — Jess'), 'Everyone but Alto 2 — Jess');
    });
  });

  group('kept on this phone', () {
    test('per song, and forgotten when let go of', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const choice = MyPart(takeId: 'alto', way: MyPartWay.without);
      await MyPartStore.save('song-a', choice);
      expect(await MyPartStore.load('song-a'), choice);
      expect(await MyPartStore.load('song-b'), isNull);

      await MyPartStore.save('song-a', null);
      expect(await MyPartStore.load('song-a'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('song-a')), isEmpty);
    });

    test('a value that is not a choice reads as none', () {
      expect(MyPart.decode(null), isNull);
      expect(MyPart.decode(''), isNull);
      expect(MyPart.decode('forward:'), isNull);
      expect(MyPart.decode('sideways:alto'), isNull);
      expect(
        MyPart.decode('forward:alto'),
        const MyPart(takeId: 'alto', way: MyPartWay.forward),
      );
    });

    test('Follow me does not carry it', () {
      const state = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 5000,
        rate: 1,
        sentAt: 1,
      );
      expect(
        state.toJson().keys.where((name) => name.contains('part')),
        isEmpty,
      );
    });
  });

  group('on the takes screen', () {
    Widget screen({required SongLayerService layers, SongAnalysisService? analysis}) {
      return MaterialApp(
        home: SongLayersScreen(
          roomId: 'room-1',
          projectId: 'project-1',
          songTitle: 'Blue for Deltona',
          layerService: layers,
          analysisService: analysis ?? _NoAnalysis(),
        ),
      );
    }

    testWidgets('two takes offer each part and person, both ways', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final layers = _ChoirLayers(<SharedLayer>[
        _layer('alto', 'Alto 2', 'Jess'),
        _layer('tenor', 'Tenor', 'Marcus', gain: 0.8),
      ]);
      await tester.pumpWidget(screen(layers: layers));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Alto 2 — Jess forward'), findsOneWidget);
      expect(find.text('Everyone but Alto 2 — Jess'), findsOneWidget);
      expect(find.text('Tenor — Marcus forward'), findsOneWidget);
      expect(find.text('Everyone but Tenor — Marcus'), findsOneWidget);
      // Nothing is on until somebody chooses, and nothing says so.
      expect(find.byKey(const Key('my_part_note')), findsNothing);
    });

    testWidgets('choosing a part is yours alone: no fader is written',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final layers = _ChoirLayers(<SharedLayer>[
        _layer('alto', 'Alto 2', 'Jess'),
        _layer('tenor', 'Tenor', 'Marcus', gain: 0.8),
      ]);
      await tester.pumpWidget(screen(layers: layers));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('my_part_forward_alto')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('my_part_forward_alto'))).selected,
        isTrue,
      );
      expect(find.byKey(const Key('my_part_note')), findsOneWidget);
      // The room's levels are exactly where the choir left them.
      expect(layers.writes, isEmpty);
      expect(layers.layers[0].gain, 1);
      expect(layers.layers[1].gain, 0.8);
      // And the choice is on this phone, for this song.
      expect(
        await MyPartStore.load('project-1'),
        const MyPart(takeId: 'alto', way: MyPartWay.forward),
      );

      // Tapped again, it is let go of.
      await tester.tap(find.byKey(const Key('my_part_forward_alto')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('my_part_forward_alto'))).selected,
        isFalse,
      );
      expect(await MyPartStore.load('project-1'), isNull);
      expect(layers.writes, isEmpty);
    });

    testWidgets('a song with one take offers nothing, recording or not',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        screen(layers: _ChoirLayers(<SharedLayer>[_layer('alto', 'Alto 2', 'Jess')])),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 take'), findsOneWidget, reason: 'the takes loaded');
      expect(find.textContaining('forward'), findsNothing);
      expect(find.textContaining('Everyone but'), findsNothing);

      // A fresh screen, not the same one updated: the takes are read once,
      // on opening.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        screen(
          layers: _ChoirLayers(<SharedLayer>[_layer('alto', 'Alto 2', 'Jess')]),
          analysis: _RecordedSong(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The recording'), findsOneWidget);
      expect(find.textContaining('forward'), findsNothing);
      expect(find.textContaining('Everyone but'), findsNothing);
    });
  });

  group('in Perform', () {
    final now = DateTime(2026, 9, 17);
    final project = SongProject(
      id: 'project-1',
      roomId: 'room-1',
      accountId: 'account',
      title: 'Blue for Deltona',
      createdAt: now,
      updatedAt: now,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'project-1',
          authorId: 'user-1',
          authorName: 'Taylor',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: now,
          position: 1,
        ),
      ],
    );
    const bundle = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'project-1',
        fileId: 'file',
        storagePath: 'room-1/project-1/reference.m4a',
        displayName: 'The recording',
        state: SongAnalysisState.ready,
        durationMs: 6000,
        transcriptText: 'turning in the wind',
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
          TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
          TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
          TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
        ],
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    /// Scrolls the practice row until [key] is on screen: the row is a lazy
    /// list, and a chip past the phone's edge does not exist until it is.
    Future<void> reveal(WidgetTester tester, Key key) async {
      final row = find.descendant(
        of: find.byKey(const Key('live_practice_row')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(find.byKey(key), 120, scrollable: row.first);
      await tester.pump(const Duration(milliseconds: 60));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> boot(
      WidgetTester tester, {
      required List<SharedLayer> layers,
      Future<String> Function(List<Take>, void Function(String))? mixer,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: bundle,
          layerService: _ChoirLayers(layers),
          analysisService: _RecordedSong(),
          partMixer: mixer,
        ),
      ));
      await settle(tester);
    }

    testWidgets('the chips name the part and the person, beside the parts left out',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await boot(tester, layers: <SharedLayer>[
        _layer('alto', 'Alto 2', 'Jess'),
        _layer('tenor', 'Tenor', 'Marcus'),
      ]);
      await reveal(tester, const Key('live_part_forward_alto'));
      expect(find.text('Alto 2 — Jess forward'), findsOneWidget);
      await reveal(tester, const Key('live_part_without_alto'));
      expect(find.text('Everyone but Alto 2 — Jess'), findsOneWidget);
      await reveal(tester, const Key('live_part_without_tenor'));
      expect(find.text('Everyone but Tenor — Marcus'), findsOneWidget);
    });

    testWidgets('forward hands the mixer that take up and the rest down, at your song level',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'song_level_project-1': 0.5,
      });
      final mixes = <List<Take>>[];
      await boot(
        tester,
        layers: <SharedLayer>[
          _layer('alto', 'Alto 2', 'Jess'),
          _layer('tenor', 'Tenor', 'Marcus', gain: 0.8),
        ],
        mixer: (takes, onProgress) async {
          mixes.add(takes);
          onProgress('Mixing…');
          return '/tmp/mix-${mixes.length}.wav';
        },
      );
      await reveal(tester, const Key('live_part_forward_alto'));
      await tester.tap(find.byKey(const Key('live_part_forward_alto')));
      await settle(tester);

      expect(mixes, hasLength(1));
      final heard = <String, Take>{for (final take in mixes.single) take.id: take};
      expect(heard.keys, containsAll(<String>['reference', 'alto', 'tenor']));
      // The recording at the level this person keeps it at, dropped behind.
      expect(heard['reference']!.gain, closeTo(0.5 * MyPartMix.behind, 1e-9));
      expect(heard['reference']!.path, '/tmp/reference.m4a');
      expect(heard['alto']!.gain, closeTo(1.0 * MyPartMix.forward, 1e-9));
      expect(heard['alto']!.path, '/tmp/alto.m4a');
      expect(heard['tenor']!.gain, closeTo(0.8 * MyPartMix.behind, 1e-9));
      expect(heard.values.every((take) => take.enabled), isTrue);
      // Something was said while it worked. (There is no audio player in a
      // test, so the swap under the words never finishes here; the mixer
      // being asked is the whole of what can be seen.)
      expect(find.byKey(const Key('live_mix_note')), findsOneWidget);
    });

    testWidgets('everyone but you hands the mixer the rest, as the room set them',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'song_level_project-1': 0.5,
      });
      final mixes = <List<Take>>[];
      await boot(
        tester,
        layers: <SharedLayer>[
          _layer('alto', 'Alto 2', 'Jess'),
          _layer('tenor', 'Tenor', 'Marcus', gain: 0.8),
        ],
        mixer: (takes, onProgress) async {
          mixes.add(takes);
          return '/tmp/mix-${mixes.length}.wav';
        },
      );
      await reveal(tester, const Key('live_part_without_alto'));
      await tester.tap(find.byKey(const Key('live_part_without_alto')));
      await settle(tester);

      expect(mixes, hasLength(1));
      final without = <String, Take>{for (final take in mixes.single) take.id: take};
      expect(without['alto']!.enabled, isFalse);
      expect(without['reference']!.gain, 0.5);
      expect(without['reference']!.enabled, isTrue);
      expect(without['tenor']!.gain, 0.8);
      expect(without['tenor']!.enabled, isTrue);
    });

    testWidgets('a part kept from last time is put back on opening', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'my_part_project-1': 'without:tenor',
      });
      final mixes = <List<Take>>[];
      await boot(
        tester,
        layers: <SharedLayer>[
          _layer('alto', 'Alto 2', 'Jess'),
          _layer('tenor', 'Tenor', 'Marcus'),
        ],
        mixer: (takes, onProgress) async {
          mixes.add(takes);
          return '/tmp/mix.wav';
        },
      );
      expect(mixes, hasLength(1));
      expect(mixes.single.where((take) => take.enabled).map((take) => take.id),
          <String>['reference', 'alto']);
    });

    testWidgets('a song with one take has no part chips', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await boot(tester, layers: <SharedLayer>[_layer('alto', 'Alto 2', 'Jess')]);
      // To the far end of the row, so every chip that exists has been built.
      await tester.drag(find.byKey(const Key('live_practice_row')), const Offset(-3000, 0));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const Key('live_practice_row')), findsOneWidget);
      expect(find.byKey(const Key('live_part_forward_alto')), findsNothing);
      expect(find.byKey(const Key('live_part_without_alto')), findsNothing);
      expect(find.byIcon(Icons.record_voice_over_outlined), findsNothing);
    });
  });
}
