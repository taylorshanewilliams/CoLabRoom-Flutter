import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/drone_controls.dart';
import 'package:colabroom/features/workspace/drone_store.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/tuner_sheet.dart';
import 'package:colabroom/services/drone.dart';
import 'package:colabroom/services/drone_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A note to tune against, and a note to come in on.
///
/// For anybody who plays against a tonic rather than against a chord: Indian
/// classical against a tanpura, a barbershop quartet given a pitch, a choir
/// waiting for a note before the count (Every Musician, Same Song, 17
/// September 2026). The arithmetic is the whole risk — a drone a few cents
/// wrong is worse than no drone, and a loop a fraction of a cycle short ticks
/// twice a second forever.

/// A drone that makes no sound and writes down what it was asked for.
class _SilentDrone implements DronePlayer {
  final List<String> log = <String>[];
  double? held;

  @override
  Future<void> hold({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  }) async {
    held = hz;
    log.add('hold ${hz.toStringAsFixed(2)}${fifth ? ' + fifth' : ''}');
  }

  @override
  Future<void> setLevel(double level) async =>
      log.add('level ${level.toStringAsFixed(2)}');

  @override
  Future<void> sound({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  }) async =>
      log.add('sound ${hz.toStringAsFixed(2)}');

  @override
  Future<void> stop() async {
    held = null;
    log.add('stop');
  }

  @override
  Future<void> dispose() async => log.add('dispose');
}

/// How much of [samples] is at [cycles] turns across the whole buffer.
///
/// Exact rather than approximate: every partial is a whole number of cycles
/// across the loop, so these are orthogonal and a dot product answers with no
/// window and no leakage.
double _energyAt(Float64List samples, double cycles) {
  var sine = 0.0;
  var cosine = 0.0;
  for (var i = 0; i < samples.length; i += 1) {
    final angle = 2 * math.pi * cycles * i / samples.length;
    sine += samples[i] * math.sin(angle);
    cosine += samples[i] * math.cos(angle);
  }
  return math.sqrt(sine * sine + cosine * cosine) * 2 / samples.length;
}

void main() {
  group('the note a drone holds', () {
    test('the 1 of three keys, at A=440', () {
      // C3, D3 and A3 — a drone sits under a voice, not in it.
      expect(droneHz(0), closeTo(130.8127, 0.0005));
      expect(droneHz(2), closeTo(146.8323, 0.0005));
      expect(droneHz(9), 220);
    });

    test('the same three at A=442, because 440 is a convention', () {
      // An orchestra at 442 is not sharp, and a drone at 440 under it is the
      // thing that is wrong.
      expect(droneHz(0, a4: 442), closeTo(131.4073, 0.0005));
      expect(droneHz(2, a4: 442), closeTo(147.4998, 0.0005));
      expect(droneHz(9, a4: 442), 221);
    });

    test('the 1 comes from the song\'s key, however it is written', () {
      expect(DroneVoice(player: _SilentDrone(), songKey: 'C').hz,
          closeTo(130.8127, 0.0005));
      expect(DroneVoice(player: _SilentDrone(), songKey: 'D major').hz,
          closeTo(146.8323, 0.0005));
      // A minor counts from A, not from its relative major.
      expect(DroneVoice(player: _SilentDrone(), songKey: 'Am').hz, 220);
    });

    test('a note picked by hand stands in front of the song\'s 1', () async {
      final voice = DroneVoice(player: _SilentDrone(), songKey: 'C');
      await voice.choose(9);
      expect(voice.hz, 220);
      await voice.choose(null);
      expect(voice.hz, closeTo(130.8127, 0.0005));
    });
  });

  group('the tone itself', () {
    test('the fifth is there when it is asked for, and not when it is not',
        () {
      final hz = droneHz(0);
      final cycles = droneCycles(hz: hz).toDouble();
      final plain = droneTone(hz: hz);
      final withFifth = droneTone(hz: hz, fifth: true);

      // The note is in both, and the fifth only in the one that asked. A just
      // fifth is three halves of the fundamental, so it lands at one and a
      // half times as many cycles across the same loop.
      expect(_energyAt(plain, cycles), greaterThan(0.2));
      expect(_energyAt(plain, cycles * 1.5), lessThan(0.001));
      expect(_energyAt(withFifth, cycles), greaterThan(0.2));
      expect(_energyAt(withFifth, cycles * 1.5), greaterThan(0.1));
    });

    test('a few harmonics, so it is a note and not a test tone', () {
      final hz = droneHz(9);
      final cycles = droneCycles(hz: hz).toDouble();
      final tone = droneTone(hz: hz);
      expect(_energyAt(tone, cycles * 2), greaterThan(0.05));
      expect(_energyAt(tone, cycles * 3), greaterThan(0.02));
    });

    test('the loop holds a whole number of cycles, so the seam is silent', () {
      for (final pitchClass in <int>[0, 2, 9]) {
        for (final a4 in <double>[440, 442]) {
          final hz = droneHz(pitchClass, a4: a4);
          final cycles = droneCycles(hz: hz);
          // Even, because the just fifth over it turns one and a half times
          // for every turn below: an odd count leaves it half a cycle short at
          // the seam, which is a click.
          expect(cycles.isEven, isTrue);
          expect(droneCycles(hz: hz, seconds: 2) * 1.5 % 1, 0);

          // The loop sounds the note it was asked for, to within a fiftieth of
          // a cent, having been rounded to whole samples.
          final sounding = droneSoundingHz(hz: hz);
          final cents = 1200 * math.log(sounding / hz) / math.ln2;
          expect(cents.abs(), lessThan(0.05));

          // And the sample after the last one is the first one again: the step
          // across the seam is no bigger than any step inside the loop.
          final tone = droneTone(hz: hz, fifth: true);
          var biggest = 0.0;
          for (var i = 1; i < tone.length; i += 1) {
            biggest = math.max(biggest, (tone[i] - tone[i - 1]).abs());
          }
          final seam = (tone[0] - tone[tone.length - 1]).abs();
          expect(seam, lessThanOrEqualTo(biggest));
        }
      }
    });

    test('a starting pitch comes in and goes away rather than being cut', () {
      final tone = startingPitchTone(hz: droneHz(0));
      // Two seconds, near enough, and nothing at either end to click.
      expect(tone.length / 44100, closeTo(2, 0.02));
      expect(tone.first.abs(), lessThan(0.001));
      expect(tone.last.abs(), lessThan(0.001));
      // With a note in the middle. The loudest sample of the middle third,
      // not the sample in the exact middle: the loop holds a whole number of
      // cycles, so its midpoint is a zero crossing every time.
      var loudest = 0.0;
      for (var i = tone.length ~/ 3; i < tone.length * 2 ~/ 3; i += 1) {
        loudest = math.max(loudest, tone[i].abs());
      }
      expect(loudest, greaterThan(0.5));
    });
  });

  group('the drone in a screen', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('it stops when it is let go of', () async {
      final player = _SilentDrone();
      final voice = DroneVoice(player: player, songKey: 'C');
      await voice.setOn(true);
      expect(player.held, closeTo(130.8127, 0.0005));

      voice.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(player.log.sublist(player.log.length - 2),
          <String>['stop', 'dispose']);
      expect(player.held, isNull);
    });

    test('the fifth and the level are this device\'s, and are kept', () async {
      final player = _SilentDrone();
      final voice = DroneVoice(player: player, songKey: 'C');
      await voice.setOn(true);
      await voice.setFifth(true);
      expect(player.log.last, contains('+ fifth'));

      await voice.setLevel(20);
      // The level moves without the drone starting again: a drone that
      // re-attacked on every step of the slider would be a row of notes.
      expect(player.log.last, 'level 0.20');
      voice.keepLevel();
      await Future<void>.delayed(Duration.zero);
      expect((await DroneStore.load()), const DroneSettings(level: 20, fifth: true));
      voice.dispose();
    });

    testWidgets('a song with no key offers only a note somebody picks',
        (tester) async {
      final player = _SilentDrone();
      final voice = DroneVoice(player: player);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DroneControls(voice: voice)),
      ));
      await tester.pump();

      // Nothing is inferred: no key means no 1, so the drone cannot be turned
      // on until somebody says which note to hold.
      expect(find.text('Pick a note'), findsOneWidget);
      expect(
        tester.widget<Switch>(find.byKey(const Key('drone_on'))).onChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('drone_starting_pitch')))
            .onPressed,
        isNull,
      );

      await voice.choose(9);
      await tester.pump();
      expect(
        tester.widget<Switch>(find.byKey(const Key('drone_on'))).onChanged,
        isNotNull,
      );

      await tester.tap(find.byKey(const Key('drone_on')));
      await tester.pump();
      expect(player.held, 220);

      await tester.tap(find.byKey(const Key('drone_starting_pitch')));
      await tester.pump();
      expect(player.log.last, 'sound 220.00');
      voice.dispose();
    });

    testWidgets('a song that knows its key opens on the 1', (tester) async {
      final player = _SilentDrone();
      final voice = DroneVoice(player: player, songKey: 'Eb');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DroneControls(voice: voice)),
      ));
      await tester.pump();

      // Spelled the way the key spells it: E♭ and never D♯.
      expect(find.text('The 1 (E♭)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drone_on')));
      await tester.pump();
      expect(player.held, closeTo(155.5634, 0.0005));
      voice.dispose();
    });

    testWidgets('leaving the tuner stops the drone', (tester) async {
      final player = _SilentDrone();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TunerSheet(
            openStream: () async => const Stream<Uint8List>.empty(),
            songKey: 'A',
            drone: player,
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('drone_on')));
      await tester.pump();
      expect(player.held, 220);

      // The reference moves, and the drone moves with it rather than being
      // the one thing in the room still at 440.
      await tester.tap(find.byTooltip('Raise reference'));
      await tester.pump();
      expect(player.held, closeTo(220.5, 0.001));

      // Closed, so it can never still be sounding when the sheet behind it
      // starts recording.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(player.log.sublist(player.log.length - 2),
          <String>['stop', 'dispose']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('it fits a small phone whose text is set large',
        (tester) async {
      // The phone's own text size is honoured and never clamped, so the
      // controls wrap and the sheet scrolls rather than cutting the Done
      // button off (Every Musician, Same Song, 17 September 2026).
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final player = _SilentDrone();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: TunerSheet(
              openStream: () async => const Stream<Uint8List>.empty(),
              songKey: 'Bb',
              drone: player,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('The 1 (B♭)'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('Perform holds the band\'s 1, not the reader\'s key',
        (tester) async {
      // The song is in G and this reader has it up three to sing it. The
      // chords on their screen move; the note in the room does not.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'song_transpose_song-key': 3,
      });
      tester.view.physicalSize = const Size(520, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final player = _SilentDrone();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: LivePerformanceScreen(
          project: _project('song-key'),
          analysis: _analysis('song-key'),
          drone: player,
        ),
      ));
      await tester.pump();
      await tester.pump();

      // Beside the count-in: the two things that happen before the first note
      // are asked for at the same moment, so they are on one sheet.
      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.text('Count-in before play'), findsOneWidget);
      expect(find.text('The 1 (G)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('drone_on')));
      await tester.pump();
      // G3, at this device's reference. Not B♭, which is what the chart in
      // front of this one reader says.
      expect(player.held, closeTo(195.9977, 0.0005));

      // Leaving Perform stops it. The drone is nowhere near a take -- nothing
      // records here -- but a tone left sounding after the screen has gone is
      // a tone nobody has a button for.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(player.log.sublist(player.log.length - 2),
          <String>['stop', 'dispose']);
      expect(tester.takeException(), isNull);
    });
  });
}

SongProject _project(String id) {
  final now = DateTime(2026, 9, 17);
  return SongProject(
    id: id,
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: id,
        authorId: 'user-1',
        authorName: 'Taylor',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: now,
        position: 1,
      ),
    ],
  );
}

SongAnalysisBundle _analysis(String id) => SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 20000,
        musicalKey: 'G',
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[],
    );
