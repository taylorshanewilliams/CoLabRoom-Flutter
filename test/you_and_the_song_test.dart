import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/pitch.dart';
import 'package:colabroom/services/pitch_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Singing along: the singer's note beside the song's.
///
/// The tuner hears one note; this is the same ear pointed at a voice, with
/// the song's own melody as the thing to compare against. The rules that
/// keep it honest: an octave away is on the note (a voice sits where it
/// sits), a breath in the song is "nothing sung here" rather than a wrong
/// answer, the microphone is opened from one tap and never on entering, and
/// a recording with no tune offers no chip at all.
Float64List tone(double hz, {int samples = 4096, int rate = 44100}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = 0.4 * math.sin(2 * math.pi * hz * i / rate);
  }
  return out;
}

Uint8List pcm16(Float64List floats) {
  final bytes = ByteData(floats.length * 2);
  for (var i = 0; i < floats.length; i++) {
    bytes.setInt16(i * 2, (floats[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  group('how the singer stands against the song', () {
    test('the same note, and the same note an octave away, are on it', () {
      expect(singingVerdict(69, 69), Singing.onIt);
      expect(singingVerdict(57, 69), Singing.onIt);
      expect(singingVerdict(81, 69), Singing.onIt);
    });

    test('below is higher, above is lower -- the direction to move', () {
      expect(singingVerdict(67, 69), Singing.low);
      expect(singingHint(Singing.low), 'Higher.');
      expect(singingVerdict(71, 69), Singing.high);
      expect(singingHint(Singing.high), 'Lower.');
    });

    test('silence and a breath in the song are each their own answer', () {
      expect(singingVerdict(null, 69), Singing.nothing);
      expect(singingVerdict(69, null), Singing.noTarget);
      expect(singingHint(Singing.nothing), contains('Headphones'));
      expect(singingHint(Singing.noTarget), 'Nothing sung here.');
    });

    test('a reading knows its MIDI number on the melody\'s scale', () {
      expect(readPitch(440)!.midi, 69);
      expect(readPitch(261.63)!.midi, 60);
      expect(readPitch(82.41)!.midi, 40);
    });
  });

  group('the ear', () {
    test('fed an A, it says A4 and clears when the sound stops', () async {
      final controller = StreamController<Uint8List>();
      final ear = PitchListener(openStream: () async => controller.stream);
      await ear.start();
      expect(ear.listening.value, isTrue);
      for (var i = 0; i < 3; i++) {
        controller.add(pcm16(tone(440)));
      }
      await Future<void>.delayed(Duration.zero);
      expect(ear.reading.value?.label, 'A4');
      await ear.stop();
      expect(ear.listening.value, isFalse);
      expect(ear.reading.value, isNull);
      await controller.close();
      ear.dispose();
    });
  });

  final now = DateTime(2026, 9, 14);
  final project = SongProject(
    id: 'song-sing',
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: 'song-sing',
        authorId: 'user-1',
        authorName: 'Taylor',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: now,
        position: 1,
      ),
    ],
  );
  // The words as the recording had them, so the sheet is synced from the
  // top, and the tune under them: an A held through the first word.
  const words = <TranscriptWord>[
    TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
    TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
    TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
    TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
  ];
  const withTune = SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-sing',
      fileId: 'file',
      storagePath: 'room/song-sing/reference.m4a',
      displayName: 'Weathervane.m4a',
      state: SongAnalysisState.ready,
      durationMs: 6000,
      transcriptText: 'turning in the wind',
      transcriptWords: words,
      melody: Melody(notes: <MelodyNote>[
        MelodyNote(startMs: 0, endMs: 2200, midi: 69),
        MelodyNote(startMs: 2400, endMs: 5000, midi: 71),
      ]),
    ),
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[],
  );
  const noTune = SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-sing',
      fileId: 'file',
      storagePath: 'room/song-sing/reference.m4a',
      displayName: 'Weathervane.m4a',
      state: SongAnalysisState.ready,
      durationMs: 6000,
      transcriptText: 'turning in the wind',
      transcriptWords: words,
    ),
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[],
  );

  Future<void> boot(WidgetTester tester, SongAnalysisBundle bundle, {StreamController<Uint8List>? mic}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LivePerformanceScreen(
        project: project,
        analysis: bundle,
        openMicrophone: mic == null ? null : () async => mic.stream,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('with a tune there is a Sing chip; without one there is not', (tester) async {
    await boot(tester, noTune);
    expect(find.byKey(const Key('live_practice_row')), findsOneWidget);
    expect(find.byKey(const Key('live_sing')), findsNothing);

    await boot(tester, withTune);
    expect(find.byKey(const Key('live_sing')), findsOneWidget);
    // Nothing is listening until it is asked to.
    expect(find.byKey(const Key('live_you_and_the_song')), findsNothing);
  });

  testWidgets('singing along shows your note beside the song\'s, and the verdict', (tester) async {
    final mic = StreamController<Uint8List>();
    await boot(tester, withTune, mic: mic);
    await tester.tap(find.byKey(const Key('live_sing')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('live_you_and_the_song')), findsOneWidget);
    expect(find.text('—'), findsWidgets);

    // The song is at the top: the first note is A4. Sing an A.
    for (var i = 0; i < 3; i++) {
      mic.add(pcm16(tone(440)));
      await tester.pump();
    }
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('live_you_note'))).data, 'A4');

    // Sing a G: a tone below the song's A, so the word is "Higher."
    for (var i = 0; i < 3; i++) {
      mic.add(pcm16(tone(392)));
      await tester.pump();
    }
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('live_you_note'))).data, 'G4');

    // Stop: the ear closes and the bar goes back to what it was.
    await tester.tap(find.byKey(const Key('live_sing')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final hint = find.byKey(const Key('live_sing_hint'));
    expect(
      find.byKey(const Key('live_you_and_the_song')),
      findsNothing,
      reason: hint.evaluate().isEmpty ? 'no hint' : 'hint still says: ${tester.widget<Text>(hint).data}',
    );

    // Not awaited: the subscription was cancelled when singing stopped, and
    // a closed controller's done future then lives in the root zone, which
    // the test's fake clock never runs.
    unawaited(mic.close());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
