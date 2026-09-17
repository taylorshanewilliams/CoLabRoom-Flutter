import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/features/workspace/song_transpose_store.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The notes under the words follow your key.
///
/// A follow-up to "Perform keeps your key" (#341). The chords moved into the
/// key somebody had chosen, and the note names under the words and the note
/// Sing along asked for stayed in the recording's: a singer who dropped a
/// song two semitones to fit their voice read A over the word and was told
/// to sing the B. Every Musician, Same Song, 17 September 2026: how you read
/// a song is yours, and all of a reading moves together.
Float64List _tone(double hz, {int samples = 4096, int rate = 44100}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = 0.4 * math.sin(2 * math.pi * hz * i / rate);
  }
  return out;
}

Uint8List _pcm16(Float64List floats) {
  final bytes = ByteData(floats.length * 2);
  for (var i = 0; i < floats.length; i++) {
    bytes.setInt16(i * 2, (floats[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  group('a note read in your key', () {
    test('moves with the song, octave and all', () {
      expect(noteAsPlayed(67, transpose: 0, key: 'G'), 'G4');
      expect(noteAsPlayed(67, transpose: 2, key: 'G'), 'A4');
      // B4 up two crosses into the next octave.
      expect(noteAsPlayed(71, transpose: 2, key: 'G'), 'C♯5');
      expect(noteAsPlayed(69, transpose: -2, key: 'G'), 'G4');
    });

    test('is spelled the way the key it lands in spells it', () {
      // G up one is A-flat, which writes its notes with flats -- as the
      // chords beside them already do.
      expect(keyAsPlayed('G', 1), 'Ab');
      expect(noteAsPlayed(69, transpose: 1, key: 'G'), 'B♭4');
      expect(chordAsPlayed('A:min', transpose: 1, key: 'G'), 'Bbm');
      // Up two is A, a sharp key, where the same pitch is an A♯.
      expect(keyAsPlayed('G', 2), 'A');
      expect(noteAsPlayed(68, transpose: 2, key: 'G'), 'A♯4');
      // A minor key keeps its raised seventh sharp, for the same reason a
      // chord does: the C♯ of an A7 in D minor is a C♯.
      expect(noteAsPlayed(61, transpose: 0, key: 'D minor'), 'C♯4');
    });

    test('without a key it is named the way the tuner names it', () {
      expect(noteInKey(70, null), 'A♯4');
      expect(noteAsPlayed(70, transpose: 0), 'A♯4');
      expect(noteAsPlayed(70, transpose: 3), 'C♯5');
    });
  });

  // "turning in the wind", sung G4 A4 A4 B4.
  final melody = Melody(notes: <MelodyNote>[
    const MelodyNote(startMs: 1060, endMs: 1480, midi: 67),
    const MelodyNote(startMs: 1540, endMs: 1780, midi: 69),
    const MelodyNote(startMs: 1840, endMs: 2150, midi: 69),
    const MelodyNote(startMs: 2260, endMs: 2900, midi: 71),
  ]);
  const line = MusicianSheetLine(
    contributionId: null,
    body: 'turning in the wind',
    section: false,
    startMs: 1000,
    endMs: 3000,
    chords: <ChordCue>[],
    approximateTiming: false,
    wordStartsMs: <int>[1000, 1500, 1800, 2200],
  );

  test('the whole line of notes moves together', () {
    expect(
      notesForWords(melody, line.wordStartsMs, line.endMs, 4, transpose: 2, key: 'G'),
      <String?>['A4', 'B4', 'B4', 'C♯5'],
    );
    // Down three from G is E, and the names come with it.
    expect(
      notesForWords(melody, line.wordStartsMs, line.endMs, 4, transpose: -3, key: 'G'),
      <String?>['E4', 'F♯4', 'F♯4', 'G♯4'],
    );
  });

  testWidgets('the note under a word is the note in the key on screen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: MusicianChordLyricLine(
          line: line,
          transpose: 2,
          musicalKey: 'G',
          fontScale: 1.5,
          showChords: true,
          liveMode: true,
          active: true,
          elapsedMs: 1900,
          melody: melody,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // In G up two the first word is sung on an A, not on the recording's G.
    expect(find.text('A4'), findsOneWidget);
    expect(find.text('B4'), findsNWidgets(2));
    expect(find.text('C♯5'), findsOneWidget);
    expect(find.text('G4'), findsNothing);
  });

  final now = DateTime(2026, 9, 17);
  final project = SongProject(
    id: 'song-notes',
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: 'song-notes',
        authorId: 'user-1',
        authorName: 'Taylor',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: now,
        position: 1,
      ),
    ],
  );
  // An A held through the whole first line, so the target at the top of the
  // song is A4 before anybody moves it.
  const withTune = SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-notes',
      fileId: 'file',
      storagePath: 'room/song-notes/reference.m4a',
      displayName: 'Weathervane.m4a',
      state: SongAnalysisState.ready,
      durationMs: 6000,
      musicalKey: 'G',
      transcriptText: 'turning in the wind',
      transcriptWords: <TranscriptWord>[
        TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
        TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
        TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
        TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
      ],
      melody: Melody(notes: <MelodyNote>[
        MelodyNote(startMs: 0, endMs: 2200, midi: 69),
      ]),
    ),
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[],
  );

  testWidgets('Sing along asks for the note in the key you moved to',
      (tester) async {
    SongTransposeStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_transpose_song-notes': 2,
    });
    final mic = StreamController<Uint8List>();
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LivePerformanceScreen(
        project: project,
        analysis: withTune,
        openMicrophone: () async => mic.stream,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    await tester.tap(find.byKey(const Key('live_sing')));
    await tester.pump();
    await tester.pump();

    // G up two is A: the song's A4 is asked for as the B4 the chart is in.
    expect(tester.widget<Text>(find.byKey(const Key('live_song_note'))).data, 'B4');

    // Sing the recording's own pitch and it is a tone short of the key you
    // are reading in.
    for (var i = 0; i < 3; i++) {
      mic.add(_pcm16(_tone(440)));
      await tester.pump();
    }
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('live_you_note'))).data, 'A4');
    expect(tester.widget<Text>(find.byKey(const Key('live_sing_hint'))).data, 'Higher.');

    // Sing the B the transposed song wants, and it is on it.
    for (var i = 0; i < 3; i++) {
      mic.add(_pcm16(_tone(493.88)));
      await tester.pump();
    }
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('live_you_note'))).data, 'B4');
    expect(tester.widget<Text>(find.byKey(const Key('live_sing_hint'))).data, 'On it.');

    // Not awaited: see you_and_the_song_test.dart -- a closed controller's
    // done future lives in the root zone, which the test's clock never runs.
    unawaited(mic.close());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    SongTransposeStore.resetForTesting();
  });
}
