import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/features/workspace/tuner_reference_store.dart';
import 'package:colabroom/features/workspace/tuner_sheet.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/horn_reading.dart';
import 'package:colabroom/services/pitch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Read it for your horn, and tell the tuner what A is.
///
/// Every Musician, Same Song, 17 September 2026. A trumpet player fingers a
/// written C and a concert B♭ comes out, so a band's chart in concert pitch
/// costs them a transposition per chord while the count-in is happening. The
/// song knows its key and its chords, so it can be read out in the
/// instrument's written pitch -- with the concert key always beside it,
/// because that is what they have to say out loud to everybody else.
///
/// And 440 is a convention, not a fact: 415 for a baroque group, 442 for a
/// lot of European orchestras.
void main() {
  group('the written key for each instrument', () {
    test('a B♭ instrument reads a major second up', () {
      // A concert B♭ is a trumpet's C.
      expect(
        keyAsRead('Bb', transpose: 0, reading: HornReading.bFlat),
        'For B♭ · written in C · concert Bb',
      );
    });

    test('an E♭ instrument reads a major sixth up', () {
      // A concert F is an alto sax's D.
      expect(
        keyAsRead('F', transpose: 0, reading: HornReading.eFlat),
        'For E♭ · written in D · concert F',
      );
    });

    test('an F instrument reads a perfect fifth up', () {
      // A concert C is a horn player's G.
      expect(
        keyAsRead('C', transpose: 0, reading: HornReading.f),
        'For F · written in G · concert C',
      );
    });

    test('concert pitch names one key, because nothing has moved', () {
      expect(keyAsRead('G', transpose: 0, reading: HornReading.concert), 'G');
      expect(keyAsRead('G', transpose: 2, reading: HornReading.concert), 'A');
    });

    test('the written key is spelled the way that key is written', () {
      // D♭ concert is B♭ on an alto sax, not A♯ -- the spelling follows the
      // key it lands in, the same rule the chords go through.
      expect(
        keyAsRead('Db major', transpose: 0, reading: HornReading.eFlat),
        'For E♭ · written in Bb major · concert Db major',
      );
      expect(
        keyAsRead('D major', transpose: 0, reading: HornReading.bFlat),
        'For B♭ · written in E major · concert D major',
      );
    });

    test('chords are written in the key they land in', () {
      // A song in concert E♭ reads in F for a trumpet, and F is a flat key:
      // the A♭ in it is an A♭ on the part, never a G♯.
      expect(
        chordAsPlayed('Ab', transpose: HornReading.bFlat.semitones, key: 'Eb'),
        'Bb',
      );
      // Concert B♭ for a trumpet is C, where the IV is F and the V is G.
      expect(
        chordAsPlayed('Eb', transpose: HornReading.bFlat.semitones, key: 'Bb'),
        'F',
      );
      // A slash chord keeps its bass through the move, like any other.
      expect(
        chordAsPlayed('G/B', transpose: HornReading.eFlat.semitones, key: 'G'),
        'E/G#',
      );
    });
  });

  group('a reading stacks on the key you play in', () {
    test('a B♭ player in a band that took the song up two', () {
      // The band plays a C song in D. The trumpet reads it in E, and still
      // has to call it D to everybody else.
      expect(
        keyAsRead('C', transpose: 2, reading: HornReading.bFlat),
        'For B♭ · written in E · concert D',
      );
    });

    test('the two moves add rather than replace each other', () {
      expect(
        keyAsRead('C', transpose: -2, reading: HornReading.eFlat),
        'For E♭ · written in G · concert Bb',
      );
      expect(
        chordAsPlayed('C', transpose: -2 + HornReading.eFlat.semitones, key: 'C'),
        'G',
      );
    });

    test('Follow me does not carry a reading, any more than a key', () {
      const state = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 5000,
        rate: 1,
        sentAt: 1,
      );
      expect(
        state.toJson().keys.where(
              (name) => name.contains('reading') || name.contains('horn'),
            ),
        isEmpty,
      );
    });
  });

  group('it is remembered on this device', () {
    test('a reading is kept per song, and concert is kept as nothing',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SongReadingStore.save('song-a', HornReading.bFlat);
      expect(await SongReadingStore.load('song-a'), HornReading.bFlat);
      expect(await SongReadingStore.load('song-b'), HornReading.concert);

      await SongReadingStore.save('song-a', HornReading.concert);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('song-a')), isEmpty);
    });

    test('a value this version does not know reads as concert', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'song_reading_song-c': 'contrabass clarinet',
      });
      expect(await SongReadingStore.load('song-c'), HornReading.concert);
    });

    test('Home has the part before it draws, and follows a change', () async {
      // Home's Tonight card names a chord in the middle of a build, so it
      // cannot wait on a disk read -- the same reason the transpose is held.
      // Without this the card named the band's chord on a song whose sheet
      // opens a tone up (review, 17 September 2026).
      SongReadingStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'song_reading_song-held': 'Bb',
        'song_reading_song-unknown': 'contrabass clarinet',
      });
      expect(SongReadingStore.held('song-held'), HornReading.concert);

      await SongReadingStore.warm();
      expect(SongReadingStore.held('song-held'), HornReading.bFlat);
      expect(SongReadingStore.held('song-unknown'), HornReading.concert);

      var ticks = 0;
      void listener() => ticks += 1;
      SongReadingStore.changes.addListener(listener);
      addTearDown(() => SongReadingStore.changes.removeListener(listener));
      await SongReadingStore.save('song-held', HornReading.f);
      expect(SongReadingStore.held('song-held'), HornReading.f);
      expect(ticks, 1);
      // Choosing the same part again is not a change.
      await SongReadingStore.save('song-held', HornReading.f);
      expect(ticks, 1);
      SongReadingStore.resetForTesting();
    });

    test('the tuner reference is kept, clamped, and 440 is kept as nothing',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await TunerReferenceStore.load(), 440);

      await TunerReferenceStore.save(442);
      expect(await TunerReferenceStore.load(), 442);

      await TunerReferenceStore.save(600);
      expect(await TunerReferenceStore.load(), TunerReferenceStore.highest);

      await TunerReferenceStore.save(440);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('tuner')), isEmpty);
    });
  });

  group('what the tuner calls A', () {
    test('442 Hz is an A at 442, and sharp at 440', () {
      expect(readPitch(442, a4: 442)!.name, 'A');
      expect(readPitch(442, a4: 442)!.cents, closeTo(0, 0.01));
      expect(readPitch(442, a4: 442)!.inTune, isTrue);

      final atStandard = readPitch(442)!;
      expect(atStandard.name, 'A');
      expect(atStandard.cents, closeTo(7.85, 0.5));
      expect(atStandard.inTune, isFalse);
    });

    test('at 415 the old A is nearly the new B♭', () {
      // A baroque group tunes a whole semitone below a modern piano, so a
      // modern 440 read against 415 is almost the note above.
      final reading = readPitch(440, a4: 415)!;
      expect(reading.name, 'A♯');
      expect(reading.octave, 4);
    });

    test('a written name is the sounding note moved to the part', () {
      // Concert A4 is a trumpet's B4, an alto sax's F♯5, a horn's E5.
      expect(writtenNote(HornReading.bFlat, 69), ('B', 4));
      expect(writtenNote(HornReading.eFlat, 69), ('F♯', 5));
      expect(writtenNote(HornReading.f, 69), ('E', 5));
      // Concert B♭3 is the trumpet's own C4.
      expect(writtenNote(HornReading.bFlat, 58), ('C', 4));
      expect(writtenNote(HornReading.concert, 69), ('A', 4));
    });
  });

  testWidgets('the key badge names both keys, and remembers the choice',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_reading_song-horn': 'Bb',
    });
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-horn'),
            bundle: _analysis('song-horn'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // A song in G reads in A for a trumpet, and the band's key stays on the
    // badge beside it.
    expect(find.text('KEY FOR B♭'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('concert G'), findsOneWidget);
    expect(find.text('A/C#'), findsOneWidget);
    // The control that is always on screen says which part is being read.
    expect(find.text('Original key'), findsOneWidget);
    expect(find.text('For B♭'), findsOneWidget);

    // The choice lives where the key does.
    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('key_reference_sheet')), findsOneWidget);
    expect(find.text('A major'), findsOneWidget);

    await tester.tap(find.byKey(const Key('read_as_eFlat')));
    await tester.pumpAndSettle();
    // The sheet itself is now the alto sax's key, and the band's is beside it.
    expect(find.text('E major'), findsOneWidget);
    expect(find.textContaining('concert G major'), findsOneWidget);
    expect(await SongReadingStore.load('song-horn'), HornReading.eFlat);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Perform opens the part you left on the sheet', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_transpose_song-key': 3,
      'song_reading_song-key': 'Bb',
    });
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: LivePerformanceScreen(
        project: _project('song-key'),
        analysis: _analysis('song-key'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    // G up three is B♭ for the band, and C on the trumpet's part.
    expect(find.byKey(const Key('live_key')), findsOneWidget);
    expect(find.text('For B♭ · written in C · concert Bb'), findsOneWidget);
    expect(find.text('C/E'), findsOneWidget);
    expect(find.text('G/B'), findsOneWidget);
    expect(find.text('Key of Bb'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the tuner takes a reference, and can name the written note',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tuner_a4_hz': 442,
    });
    final controller = StreamController<Uint8List>();
    addTearDown(controller.close);
    // A small phone, because a reference row and a toggle are two more rows
    // on a sheet that already has a needle on it.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TunerSheet(
          openStream: () async => controller.stream,
          reading: HornReading.bFlat,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('A = 442 Hz'), findsOneWidget);

    // A tone at 442 is in tune for somebody tuned to 442, and would have been
    // eight cents sharp against 440.
    for (var i = 0; i < 3; i++) {
      controller.add(_pcm16(_tone(442)));
      await tester.pump();
    }
    await tester.pump();
    expect(_noteOnScreen(tester), 'A4');
    expect(find.text('In tune.'), findsOneWidget);

    // The same note, named the way the part writes it.
    await tester.tap(find.byKey(const Key('tuner_written_names')));
    await tester.pump();
    expect(_noteOnScreen(tester), 'B4');
    expect(find.text('Written for B♭'), findsOneWidget);
    // The frequency is still the frequency; only the name moved.
    expect(find.textContaining('442.0 Hz'), findsOneWidget);

    // And moving the reference moves what the same tone is called.
    for (var i = 0; i < 27; i++) {
      await tester.tap(find.byTooltip('Lower reference'));
      await tester.pump();
    }
    expect(find.text('A = 415 Hz'), findsOneWidget);
    expect(await TunerReferenceStore.load(), 415);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the chart names both keys, and the choice is reachable there',
      (tester) async {
    // The chart has no key badge to hang the choice on, and a horn player
    // reading from it still has to know what to call the tune to everybody
    // else (review, 17 September 2026).
    SongReadingStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_reading_song-chart': 'Bb',
    });
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-chart'),
            bundle: _analysis('song-chart'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Chart'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('song_sheet_key_badge')), findsNothing);
    expect(find.text('For B♭ · written in A · concert G'), findsOneWidget);

    // And the same control opens the same choice, so the part can be put
    // back without leaving the chart.
    await tester.tap(find.byKey(const Key('song_sheet_read_as')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('key_reference_sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('read_as_concert')));
    await tester.pumpAndSettle();
    expect(await SongReadingStore.load('song-chart'), HornReading.concert);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SongReadingStore.resetForTesting();
  });

  testWidgets('a song with no key can still be read for a horn',
      (tester) async {
    // Key detection falls back on plenty of real recordings. The chords are
    // still chords, and they still have to be written for the part.
    SongReadingStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-nokey'),
            bundle: _analysis('song-nokey', musicalKey: null),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('song_sheet_key_badge')), findsNothing);
    await tester.tap(find.byKey(const Key('song_sheet_read_as')));
    await tester.pumpAndSettle();
    // No key to describe, so the row comes on its own.
    expect(find.byKey(const Key('reading_choice_sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('read_as_bFlat')));
    await tester.pumpAndSettle();
    expect(await SongReadingStore.load('song-nokey'), HornReading.bFlat);
    expect(find.text('Chords written for B♭'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SongReadingStore.resetForTesting();
  });

  testWidgets('a capo chart is only offered in concert pitch', (tester) async {
    // A capo is a guitar answer about the key the band is in. Worked out
    // from a written key it names frets a tone away from everybody else, and
    // it says nothing at all to the instrument the reading was for.
    SongReadingStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-capo'),
            bundle: _analysis('song-capo'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.text('WITH A CAPO'), findsOneWidget);

    await tester.tap(find.byKey(const Key('read_as_bFlat')));
    await tester.pumpAndSettle();
    expect(find.text('A major'), findsOneWidget);
    expect(find.text('WITH A CAPO'), findsNothing);
    expect(
      find.text('This key already sits under open chords — no capo needed.'),
      findsNothing,
    );
    // The scale is still there: it is right in the written key.
    expect(find.text('THE SCALE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SongReadingStore.resetForTesting();
  });

  testWidgets('Sing along is named the way the part is, and still hears '
      'concert pitch', (tester) async {
    // One screen, one language. The note names under the words ride the same
    // move as the chords over them, so the row underneath has to as well --
    // otherwise the same pitch is called two things at once. Both sides move
    // by the same amount, so what is compared never changes (review, 17
    // September 2026).
    SongReadingStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_reading_song-sing': 'Bb',
    });
    final mic = StreamController<Uint8List>();
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: LivePerformanceScreen(
        project: _project('song-sing'),
        analysis: _withTune('song-sing'),
        openMicrophone: () async => mic.stream,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    await tester.tap(find.byKey(const Key('live_sing')));
    await tester.pump();
    await tester.pump();

    // The recording's A4, written for a trumpet, is a B4 -- which is exactly
    // what the note under the word says, through noteAsPlayed on the same
    // move.
    expect(noteAsPlayed(69, transpose: HornReading.bFlat.semitones, key: 'G'),
        'B4');
    expect(
      tester.widget<Text>(find.byKey(const Key('live_song_note'))).data,
      'B4',
    );

    // Sing the concert A the recording actually sang and it is on it: the
    // microphone is still being compared against the song in concert pitch.
    for (var i = 0; i < 3; i++) {
      mic.add(_pcm16(_tone(440)));
      await tester.pump();
    }
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('live_you_note'))).data,
      'B4',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('live_sing_hint'))).data,
      'On it.',
    );

    // Not awaited: a closed controller's done future lives in the root zone,
    // which the test's clock never runs. See you_and_the_song_test.dart.
    unawaited(mic.close());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    SongReadingStore.resetForTesting();
  });
}

/// A Text.rich rather than a RichText: the note is drawn at the size the
/// phone asks for now, and a RichText ignores that setting outright.
String _noteOnScreen(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('tuner_note')))
    .textSpan!
    .toPlainText();

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
    bytes.setInt16(
        i * 2, (floats[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
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

/// The same song with a tune in it, for the Sing along row.
SongAnalysisBundle _withTune(String id) => SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 6000,
        musicalKey: 'G',
        transcriptText: 'turning in the wind',
        transcriptWords: const <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
          TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
          TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
          TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
        ],
        // An A held through the whole first line, so the note the song wants
        // at the top is A4 before anybody moves it.
        melody: const Melody(notes: <MelodyNote>[
          MelodyNote(startMs: 0, endMs: 2200, midi: 69),
        ]),
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[],
    );

SongAnalysisBundle _analysis(String id, {String? musicalKey = 'G'}) =>
    SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 20000,
        musicalKey: musicalKey,
        transcriptText: 'turning in the wind again',
        transcriptWords: const <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 5000, endMs: 5800),
          TranscriptWord(word: 'in', startMs: 5800, endMs: 6100),
          TranscriptWord(word: 'the', startMs: 6100, endMs: 6400),
          TranscriptWord(word: 'wind', startMs: 6400, endMs: 7200),
          TranscriptWord(word: 'again', startMs: 12500, endMs: 13400),
        ],
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[
        ChordCue(
            id: 1, startMs: 5000, endMs: 7000, chord: 'G:maj/3', confidence: 0.9),
        ChordCue(
            id: 2,
            startMs: 12500,
            endMs: 13400,
            chord: 'D/F#',
            confidence: 0.9,
            source: 'manual'),
      ],
    );
