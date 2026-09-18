import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/then_and_now.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Then and now.
///
/// Every Musician, Same Song, 17 September 2026, slice 30, for beginners at
/// every age: hear today's take beside the first one on the same bars, one
/// after the other, at the same speed. The pair is your own first and
/// latest take of a part, and nobody else's; the passage is the same bars
/// from each; the words are "then" and "now", and never how long ago or how
/// much better.

SharedLayer _layer(
  String id, {
  String who = 'jess',
  String? whoName = 'Jess',
  TakePart part = TakePart.lead,
  DateTime? at,
  int startMs = 0,
  int durationMs = 60000,
  String? performer,
  String label = '',
}) {
  return SharedLayer(
    id: id,
    projectId: 'project-1',
    recordedBy: who,
    recordedByName: whoName,
    storagePath: 'room-1/project-1/layers/$id.m4a',
    label: label,
    part: part,
    performer: performer,
    startMs: startMs,
    durationMs: durationMs,
    createdAt: at ?? DateTime(2026, 3, 1),
  );
}

Take _take(String id, {bool enabled = true, double gain = 1}) => Take(
      id: id,
      path: '/tmp/$id.m4a',
      label: id,
      recordedAt: DateTime(2026, 9, 17),
      enabled: enabled,
      gain: gain,
    );

final DateTime _march = DateTime(2026, 3, 1);
final DateTime _april = DateTime(2026, 4, 1);
final DateTime _may = DateTime(2026, 5, 1);

/// A grid of two-second bars, the first downbeat a second in.
const List<int> _downbeats = <int>[
  1000, 3000, 5000, 7000, 9000, 11000, 13000, 15000, 17000, 19000,
];

Float64List _tone(int samples, double level) =>
    Float64List.fromList(List<double>.filled(samples, level));

/// Jess's own pairs, which is what the screen asks for.
List<ThenAndNowPair> _jessPairs(List<SharedLayer> layers) =>
    ThenAndNow.pairs(layers, by: 'jess');

/// The takes of a song, already on the phone.
class _Recorded extends SongLayerService {
  _Recorded(this.layers) : super(client: null);

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

void main() {
  group('the pair', () {
    test('is the first and the latest take of a part by one person', () {
      final pairs = _jessPairs(<SharedLayer>[
        _layer('lead-2', at: _april),
        _layer('lead-3', at: _may),
        _layer('lead-1', at: _march),
      ]);
      expect(pairs, hasLength(1));
      expect(pairs.single.then.id, 'lead-1');
      expect(pairs.single.now.id, 'lead-3');
      // Every take of the part is in the group, so the halves can silence
      // the ones between.
      expect(pairs.single.group.map((layer) => layer.id), <String>['lead-1', 'lead-2', 'lead-3']);
      expect(pairs.single.ids, <String>{'lead-1', 'lead-2', 'lead-3'});
    });

    test('a part recorded once is not a pair, and neither is an empty song', () {
      expect(_jessPairs(<SharedLayer>[_layer('lead-1')]), isEmpty);
      expect(_jessPairs(const <SharedLayer>[]), isEmpty);
    });

    test("is your own, and never a bandmate's", () {
      // Marcus has a first bass and a latest on the song. On Jess's screen
      // that is not a pair: everybody's takes stay audible one at a time,
      // and what nobody else gets is somebody's two lined up.
      final layers = <SharedLayer>[
        _layer('bass-1', who: 'marcus', whoName: 'Marcus', part: TakePart.bass, at: _march),
        _layer('bass-2', who: 'marcus', whoName: 'Marcus', part: TakePart.bass, at: _may),
        _layer('lead-1', at: _march),
        _layer('lead-2', at: _april),
      ];
      expect(_jessPairs(layers).map((pair) => pair.now.id), <String>['lead-2']);
      expect(
        ThenAndNow.pairs(layers, by: 'marcus').map((pair) => pair.now.id),
        <String>['bass-2'],
      );
    });

    test('nobody signed in has none', () {
      expect(
        ThenAndNow.pairs(<SharedLayer>[_layer('a', at: _march), _layer('b', at: _may)], by: null),
        isEmpty,
      );
    });

    test("a teacher's demonstration is not the student's then", () {
      // Same part, two people: the teacher played the lead once to show it,
      // and the student played it once. Keyed on the account, so the
      // student has no first and latest, and neither does the teacher.
      final layers = <SharedLayer>[
        _layer('demo', who: 'teacher', whoName: 'Ms. Rivera', at: _march),
        _layer('mine', who: 'jess', at: _april),
      ];
      expect(_jessPairs(layers), isEmpty);
      expect(ThenAndNow.pairs(layers, by: 'teacher'), isEmpty);
    });

    test('different parts by one person are different pairs, the latest first', () {
      final pairs = _jessPairs(<SharedLayer>[
        _layer('lead-1', at: _march),
        _layer('lead-2', at: _april),
        _layer('vocal-1', part: TakePart.vocal, at: _march),
        _layer('vocal-2', part: TakePart.vocal, at: _may),
      ]);
      expect(pairs.map((pair) => pair.now.id), <String>['vocal-2', 'lead-2']);
    });

    test('two takes that never share a bar are not a pair', () {
      // A first verse and a last chorus: there are no same bars to hear.
      final pairs = _jessPairs(<SharedLayer>[
        _layer('verse', at: _march, startMs: 0, durationMs: 10000),
        _layer('chorus', at: _april, startMs: 20000, durationMs: 10000),
      ]);
      expect(pairs, isEmpty);
    });

    test('a part nobody marked still pairs', () {
      final pairs = _jessPairs(<SharedLayer>[
        _layer('a', part: TakePart.other, at: _march),
        _layer('b', part: TakePart.other, at: _april),
      ]);
      expect(pairs, hasLength(1));
      expect(pairs.single.name, 'part');
    });

    test('is named by the part alone, never by either take or by you', () {
      // Every pair is your own, so a name on it would be yours; and the
      // takes' own labels were given at different times and disagree.
      final pair = _jessPairs(<SharedLayer>[
        _layer('lead-1', at: _march, label: 'Lead'),
        _layer('lead-3', at: _may, label: 'Lead 3', performer: 'Jess'),
      ]).single;
      expect(pair.name, 'lead');
      final vocal = _jessPairs(<SharedLayer>[
        _layer('a', part: TakePart.vocal, at: _march),
        _layer('b', part: TakePart.vocal, at: _may, performer: 'Dylan'),
      ]).single;
      expect(vocal.name, 'vocal');
    });

    test('two takes recorded in the same instant have one first, on every phone', () {
      final one = _jessPairs(<SharedLayer>[_layer('z', at: _march), _layer('y', at: _march)]);
      final other = _jessPairs(<SharedLayer>[_layer('y', at: _march), _layer('z', at: _march)]);
      expect(one.single.then.id, 'y');
      expect(other.single.then.id, 'y');
    });

    test('is the same pair by the same two takes', () {
      final a = _jessPairs(<SharedLayer>[_layer('1', at: _march), _layer('2', at: _may)]).single;
      final b = _jessPairs(<SharedLayer>[_layer('1', at: _march), _layer('2', at: _may)]).single;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('the passage', () {
    final pair = _jessPairs(<SharedLayer>[
      _layer('then', at: _march),
      _layer('now', at: _may),
    ]).single;

    test('is four bars from the bar under the playhead', () {
      final passage = ThenAndNow.passage(pair, atMs: 7500, downbeatsMs: _downbeats)!;
      expect(passage.startMs, 7000);
      expect(passage.endMs, 15000);
      expect(passage.label, 'Bars 4–7');
      expect(passage.firstBar, 4);
      expect(passage.lastBar, 7);
    });

    test('is cut to where both takes exist', () {
      final short = _jessPairs(<SharedLayer>[
        _layer('then', at: _march),
        _layer('now', at: _may, startMs: 6000, durationMs: 5000),
      ]).single;
      expect(short.sharedStartMs, 6000);
      expect(short.sharedEndMs, 11000);
      final passage = ThenAndNow.passage(short, atMs: 7500, downbeatsMs: _downbeats)!;
      expect(passage.startMs, 7000);
      expect(passage.endMs, 11000);
      expect(passage.label, 'Bars 4–5');
    });

    test('starts where both takes begin when the playhead is elsewhere', () {
      final late = _jessPairs(<SharedLayer>[
        _layer('then', at: _march),
        _layer('now', at: _may, startMs: 6000, durationMs: 5000),
      ]).single;
      final before = ThenAndNow.passage(late, atMs: 0, downbeatsMs: _downbeats)!;
      expect(before.startMs, 6000);
      expect(before.endMs, 11000);
      expect(before.label, 'Bars 3–5');
      final after = ThenAndNow.passage(late, atMs: 50000, downbeatsMs: _downbeats)!;
      expect(after.startMs, 9000);
      expect(after.endMs, 11000);
      expect(after.label, 'Bar 5');
    });

    test('is eight seconds by the clock on a song with no bars', () {
      final passage = ThenAndNow.passage(pair, atMs: 42000)!;
      expect(passage.startMs, 42000);
      expect(passage.endMs, 50000);
      expect(passage.label, '0:42–0:50');
      expect(passage.isBars, isFalse);
      // Cut to where the takes end, like the bars are.
      final end = ThenAndNow.passage(pair, atMs: 55000)!;
      expect(end.endMs, 60000);
      expect(end.label, '0:55–1:00');
    });

    test('a pickup ahead of bar 1 starts where the bars do', () {
      final passage = ThenAndNow.passage(pair, atMs: 200, downbeatsMs: _downbeats)!;
      expect(passage.startMs, 1000);
      expect(passage.endMs, 9000);
      expect(passage.label, 'Bars 1–4');
    });

    test('is the same bars from each take', () {
      // One passage, read back twice: the file is then, a breath, now.
      final passage = ThenAndNow.passage(pair, atMs: 7500, downbeatsMs: _downbeats)!;
      final track = ThenAndNowTrack(path: '/tmp/x.wav', pair: pair, passage: passage);
      expect(track.halfMs, 8000);
      expect(track.nowFromMs, 8000 + ThenAndNow.breathMs);
      expect(track.halfAt(0), ThenOrNow.then);
      expect(track.songMsAt(0), 7000);
      expect(track.songMsAt(7999), 14999);
      // The breath is the silence after then, held at the end of the bars.
      expect(track.halfAt(8000), ThenOrNow.then);
      expect(track.songMsAt(8000), 15000);
      expect(track.halfAt(8699), ThenOrNow.then);
      // Now crosses the same bars again.
      expect(track.halfAt(8700), ThenOrNow.now);
      expect(track.songMsAt(8700), 7000);
      expect(track.songMsAt(8700 + 7999), 14999);
      expect(track.songMsAt(8700 + 8000), 15000);
      expect(track.songMsAt(99999), 15000);
    });
  });

  group('the halves', () {
    final pair = _jessPairs(<SharedLayer>[
      _layer('then', at: _march),
      _layer('middle', at: _april),
      _layer('now', at: _may),
    ]).single;
    final takes = <Take>[
      _take('reference', gain: 0.8),
      _take('then'),
      _take('middle'),
      _take('now', enabled: false),
      _take('bass', enabled: false),
    ];

    test('hear only the one take of the pair, and the rest as they were', () {
      final then = ThenAndNow.half(takes, pair, heard: 'then');
      expect(then.map((take) => take.enabled), <bool>[true, true, false, false, false]);
      final now = ThenAndNow.half(takes, pair, heard: 'now');
      // Heard even though its lane was muted: the chip asked for it.
      expect(now.map((take) => take.enabled), <bool>[true, false, false, true, false]);
      // Nothing outside the pair moved, and no level did.
      expect(then[0].gain, 0.8);
      expect(now[0].gain, 0.8);
      expect(then[4].enabled, isFalse);
      expect(takes.map((take) => take.enabled), <bool>[true, true, true, false, false]);
    });
  });

  group('one file, the passage twice', () {
    test('then, a breath, now', () {
      // A tenth of a second of each, with a hundredth of a second between.
      final spliced = ThenAndNow.splice(
        _tone(Multitrack.rate, 0.5),
        _tone(Multitrack.rate, 0.25),
        startMs: 0,
        endMs: 100,
        breathMs: 10,
      );
      const half = 4410;
      const breath = 441;
      expect(spliced.length, half * 2 + breath);
      expect(spliced[0], 0.5);
      expect(spliced[half - 1], 0.5);
      expect(spliced[half], 0);
      expect(spliced[half + breath - 1], 0);
      expect(spliced[half + breath], 0.25);
      expect(spliced[spliced.length - 1], 0.25);
    });

    test('takes the same stretch of each', () {
      final then = Float64List(Multitrack.rate);
      final now = Float64List(Multitrack.rate);
      // A mark half a second in on each.
      then[Multitrack.rate ~/ 2] = 0.7;
      now[Multitrack.rate ~/ 2] = 0.3;
      final spliced = ThenAndNow.splice(then, now, startMs: 400, endMs: 600, breathMs: 0);
      final half = (200 * Multitrack.rate / 1000).round();
      final mark = (100 * Multitrack.rate / 1000).round();
      expect(spliced[mark], 0.7);
      expect(spliced[half + mark], 0.3);
    });

    test('is turned down once, together, so neither half is quieter for it', () {
      final spliced = ThenAndNow.splice(
        _tone(Multitrack.rate, 2.0),
        _tone(Multitrack.rate, 0.5),
        startMs: 0,
        endMs: 100,
        breathMs: 0,
      );
      expect(spliced[0], closeTo(0.99, 1e-9));
      expect(spliced[spliced.length - 1], closeTo(0.2475, 1e-9));
      // The mixer, asked not to fit, leaves the peak where it was.
      final raw = Multitrack.mix(<Take>[_take('a')], <Float64List>[_tone(10, 2.0)], fit: false);
      expect(raw.samples[0], 2.0);
      expect(raw.scaled, isFalse);
      final fitted = Multitrack.mix(<Take>[_take('a')], <Float64List>[_tone(10, 2.0)]);
      expect(fitted.samples[0], closeTo(0.99, 1e-9));
      expect(fitted.scaled, isTrue);
    });

    test('a mix shorter than the passage is heard stopping, not thrown', () {
      final spliced = ThenAndNow.splice(
        _tone(100, 0.5),
        Float64List(0),
        startMs: 0,
        endMs: 100,
        breathMs: 0,
      );
      expect(spliced.length, 4410 * 2);
      expect(spliced[99], 0.5);
      expect(spliced[100], 0);
      expect(spliced[4410], 0);
    });
  });

  group('the words', () {
    test('are then and now, and never how long ago or how much better', () {
      final pair = _jessPairs(<SharedLayer>[
        _layer('then', at: DateTime(2024, 1, 1)),
        _layer('now', at: DateTime(2026, 9, 17)),
      ]).single;
      final copy = <String>[
        ThenAndNow.chipLabel,
        ThenOrNow.then.label,
        ThenOrNow.now.label,
        pair.name,
        ThenAndNow.passage(pair, atMs: 7500, downbeatsMs: _downbeats)!.label,
        ThenAndNow.passage(pair, atMs: 42000)!.label,
      ];
      expect(ThenOrNow.then.label, 'Then');
      expect(ThenOrNow.now.label, 'Now');
      expect(ThenAndNow.chipLabel, 'Then and now');
      final forbidden = RegExp(
        r'\b(ago|day|days|week|weeks|month|months|year|years|since|old|new|'
        r'better|worse|improv\w*|progress|score|first|latest|last|'
        r'before|after)\b|%',
        caseSensitive: false,
      );
      for (final words in copy) {
        expect(forbidden.hasMatch(words), isFalse, reason: '"$words"');
      }
    });
  });

  group('on the takes screen', () {
    // The in-memory repository signs the screen in as 'preview-user', which
    // is whose takes pair. Everybody else on the song is a bandmate.
    const me = 'preview-user';

    Future<void> open(WidgetTester tester, List<SharedLayer> layers) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          home: SongLayersScreen(
            roomId: 'room-1',
            projectId: 'project-1',
            songTitle: 'Blue for Deltona',
            layerService: _Recorded(layers),
            analysisService: _NoAnalysis(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    testWidgets('two takes of a part of your own offer then and now', (tester) async {
      await open(tester, <SharedLayer>[
        _layer('lead-1', who: me, whoName: 'Taylor', at: _march),
        _layer('lead-2', who: me, whoName: 'Taylor', at: _may),
      ]);
      expect(find.text('2 takes'), findsOneWidget, reason: 'the takes loaded');
      expect(find.byKey(const Key('then_and_now_lead-2')), findsOneWidget);
      expect(find.text('Then and now'), findsOneWidget);
      // Nothing is sounding, and nothing says so.
      expect(find.byKey(const Key('then_and_now_half')), findsNothing);
    });

    testWidgets('one take, or two people, offer nothing', (tester) async {
      await open(tester, <SharedLayer>[_layer('lead-1', who: me, at: _march)]);
      expect(find.text('1 take'), findsOneWidget, reason: 'the takes loaded');
      expect(find.textContaining('Then and now'), findsNothing);

      // A fresh screen, not the same one updated: the takes are read once.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      await open(tester, <SharedLayer>[
        _layer('demo', who: 'teacher', whoName: 'Ms. Rivera', at: _march),
        _layer('mine', who: me, at: _may),
      ]);
      expect(find.text('2 takes'), findsOneWidget);
      expect(find.textContaining('Then and now'), findsNothing);
    });

    testWidgets("a bandmate's two takes are theirs to hear, not a chip on your screen", (tester) async {
      await open(tester, <SharedLayer>[
        _layer('bass-1', who: 'marcus', whoName: 'Marcus', part: TakePart.bass, at: _march),
        _layer('bass-2', who: 'marcus', whoName: 'Marcus', part: TakePart.bass, at: _may),
        _layer('lead-1', who: me, at: _march),
        _layer('lead-2', who: me, at: _april),
      ]);
      expect(find.text('4 takes'), findsOneWidget, reason: 'the takes loaded');
      // One pair, yours, and so unnamed.
      expect(find.text('Then and now'), findsOneWidget);
      expect(find.byKey(const Key('then_and_now_lead-2')), findsOneWidget);
      expect(find.byKey(const Key('then_and_now_bass-2')), findsNothing);
      // No chip carries anybody's name, his or yours.
      expect(find.textContaining('Then and now ·'), findsNothing);
    });

    testWidgets('several pairs of your own say which part', (tester) async {
      await open(tester, <SharedLayer>[
        _layer('lead-1', who: me, at: _march),
        _layer('lead-2', who: me, at: _april),
        _layer('vocal-1', who: me, part: TakePart.vocal, at: _march),
        _layer('vocal-2', who: me, part: TakePart.vocal, at: _may),
      ]);
      expect(find.text('Then and now · vocal'), findsOneWidget);
      expect(find.text('Then and now · lead'), findsOneWidget);
    });
  });
}
