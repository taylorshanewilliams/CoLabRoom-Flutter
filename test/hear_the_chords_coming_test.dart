import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/hear_the_chords.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/chord_voice.dart';
import 'package:colabroom/services/click_player.dart';
import 'package:colabroom/services/spoken_chords.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A count-in with no sound in it, so a test can count the beats rather than
/// wait for a file to be written.
class _SilentClick implements ClickPlayer {
  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
    List<int> accents = const <int>[],
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// A voice that keeps what it was told instead of saying it, so a test can
/// read the calls rather than listen for them.
class _WrittenDown implements ChordVoice {
  final List<String> said = <String>[];
  int hushes = 0;
  bool disposed = false;

  @override
  Future<void> say(String words) async => said.add(words);

  @override
  Future<void> stop() async => hushes += 1;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Hear the chords coming.
///
/// The second half of "feel the beat, hear the chords coming". A blind
/// player, or anybody whose eyes are on their instrument, hears the name of
/// the next chord one beat before it lands, in the reading they are on — so a
/// B♭ player hears the C they are about to finger and a Nashville reader
/// hears "four" (Every Musician, Same Song, 17 September 2026).
///
/// Off until it is asked for, kept on this device, and never carried to
/// anybody else's phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final day = DateTime(2026, 9, 17);

  /// Sixteen seconds at 120 in four: a beat every half second, a bar every
  /// two, the way the tracker writes them down.
  final beats = <int>[for (var ms = 0; ms <= 15500; ms += 500) ms];
  const downbeats = <int>[0, 2000, 4000, 6000, 8000, 10000, 12000, 14000];

  ChordCue chord(String label, int startMs, int endMs) => ChordCue(
        startMs: startMs,
        endMs: endMs,
        chord: label,
        confidence: 0.9,
      );

  /// A bar each of G, C, D and back to G, in Harte, snapped to the grid the
  /// way the analysis leaves them.
  final cues = <ChordCue>[
    chord('G:maj', 0, 2000),
    chord('C:maj', 2000, 4000),
    chord('D:7', 4000, 6000),
    chord('G:maj', 6000, 8000),
  ];

  group('what a chord is called out loud', () {
    test('letters, with the accidental said and the plain major left bare',
        () {
      // A major triad is the name and nothing else, because that is what
      // somebody calling a band through a song shouts, and a beat is not long
      // enough for a word that adds nothing.
      expect(speakableChord('C'), 'C');
      expect(speakableChord('F♯'), 'F sharp');
      expect(speakableChord('Bb'), 'B flat');
      expect(speakableChord('Em'), 'E minor');
      expect(speakableChord('F#m7'), 'F sharp minor seven');
      expect(speakableChord('Bbmaj7'), 'B flat major seven');
      expect(speakableChord('Am7♭5'), 'A minor seven flat five');
      expect(speakableChord('C°7'), 'C diminished seven');
      expect(speakableChord('Gsus4'), 'G sus four');
      expect(speakableChord('C6'), 'C six');
      expect(speakableChord('G+'), 'G augmented');
      expect(speakableChord('CmMaj7'), 'C minor major seven');
      // The bass of a slash chord is said the way it is written.
      expect(speakableChord('G/B'), 'G over B');
      expect(speakableChord('C/Bb'), 'C over B flat');
    });

    test('numbers, which is the same handful of words in either system', () {
      expect(speakableChord('1'), 'one');
      expect(speakableChord('4'), 'four');
      expect(speakableChord('♭6'), 'flat six');
      expect(speakableChord('♯4'), 'sharp four');
      expect(speakableChord('2-'), 'two minor');
      expect(speakableChord('6-7'), 'six minor seven');
      expect(speakableChord('1-7♭5'), 'one minor seven flat five');
      expect(speakableChord('5/7'), 'five over seven');
      expect(speakableChord('4sus2'), 'four sus two');
      expect(speakableChord('5add9'), 'five add nine');
      expect(speakableChord('1maj7'), 'one major seven');
      expect(speakableChord('7°'), 'seven diminished');
    });

    test('numerals say the number, and the case says the quality', () {
      // A player reading IV says "four", the same as the one reading 4.
      expect(speakableChord('I'), 'one');
      expect(speakableChord('IV'), 'four');
      expect(speakableChord('V7'), 'five seven');
      expect(speakableChord('♭VI'), 'flat six');
      // Lower case is how a Roman reading writes minor, so it has to be said:
      // a voice saying "two" for a ii would be naming a different chord.
      expect(speakableChord('ii'), 'two minor');
      expect(speakableChord('iii7'), 'three minor seven');
      // Diminished already says there is a minor third in it, so the numeral
      // beside it does not say it twice.
      expect(speakableChord('vii°'), 'seven diminished');
      expect(speakableChord('viiø7'), 'seven half diminished seven');
    });

    test('nothing is said for no chord, and nothing is guessed at', () {
      expect(speakableChord(''), '');
      expect(speakableChord('N'), '');
      expect(speakableChord('X'), '');
      // A spelling this cannot read comes back as it was written. A voice
      // reading a symbol awkwardly is a poor call; one confidently saying a
      // different chord is a wrong one.
      expect(speakableChord('Ω'), 'Ω');
      // A quality nobody has a word for is carried through rather than
      // dropped, because dropping it would name a different chord.
      expect(speakableChord('Calt'), 'C alt');
    });
  });

  group('the calls a song is read through', () {
    test('each chord is called on the beat before it lands', () {
      final calls = chordCalls(cues: cues, beatsMs: beats);
      // Not the G on the song's own first beat: there is nothing in front of
      // it to be called from, and a name said late is a chord already
      // sounding.
      expect(calls, <ChordCall>[
        const ChordCall(atMs: 1500, changeMs: 2000, chord: 'C:maj'),
        const ChordCall(atMs: 3500, changeMs: 4000, chord: 'D:7'),
        const ChordCall(atMs: 5500, changeMs: 6000, chord: 'G:maj'),
      ]);
    });

    test('a change the tracker left between two beats is called early', () {
      // A push, sitting a fraction ahead of the bar. The call goes on the
      // beat before the one it belongs to, which is a little early rather
      // than a little late — early is the one a player can use.
      final calls = chordCalls(
        cues: <ChordCue>[chord('G:maj', 0, 1880), chord('C:maj', 1880, 4000)],
        beatsMs: beats,
      );
      expect(calls.single.atMs, 1500);
      expect(calls.single.changeMs, 1880);
    });

    test('nothing stacks: two changes inside a beat get one call', () {
      // A stab and the chord it lands on, 120ms apart. Both want the same
      // beat to be called on; the first keeps it, because two names at once
      // is neither of them.
      final calls = chordCalls(
        cues: <ChordCue>[
          chord('G:maj', 0, 2000),
          chord('F:maj', 2000, 2120),
          chord('C:maj', 2120, 4000),
        ],
        beatsMs: beats,
      );
      expect(calls, hasLength(1));
      expect(calls.single, const ChordCall(
        atMs: 1500,
        changeMs: 2000,
        chord: 'F:maj',
      ));
    });

    test('a stretch with no chord in it is passed over, not called', () {
      final calls = chordCalls(
        cues: <ChordCue>[
          chord('G:maj', 0, 2000),
          chord('N', 2000, 4000),
          chord('C:maj', 4000, 6000),
        ],
        beatsMs: beats,
      );
      // "N" is a letter, not a chord — and it does not block the chord after
      // it either.
      expect(calls, <ChordCall>[
        const ChordCall(atMs: 3500, changeMs: 4000, chord: 'C:maj'),
      ]);
    });

    test('a song with no chords, or no beat, offers nothing', () {
      expect(chordCalls(cues: const <ChordCue>[], beatsMs: beats), isEmpty);
      // A name called on the downbeat before a change would be a whole bar
      // early, which is not a call at all, so downbeats are no substitute for
      // the beat grid.
      expect(chordCalls(cues: cues, beatsMs: const <int>[]), isEmpty);
      expect(chordCalls(cues: cues, beatsMs: const <int>[0]), isEmpty);
    });

    test('the next call, and the beat the song landed on by itself', () {
      final calls = chordCalls(cues: cues, beatsMs: beats);
      expect(nextChordCall(0, calls: calls), calls.first);
      expect(nextChordCall(1499, calls: calls), calls.first);
      // Strictly after: a finger moved the song, so a call sitting on the
      // beat it landed on is a call for a change that is already here.
      expect(nextChordCall(1500, calls: calls), calls[1]);
      // Unless the song arrived on that beat by itself — a passage turning
      // round, a count-in handing over.
      expect(
        nextChordCall(1500, calls: calls, onTheBeat: true),
        calls.first,
      );
      expect(nextChordCall(6000, calls: calls), isNull);
    });

    test('a passage on repeat is not told about the chord after it', () {
      final calls = chordCalls(cues: cues, beatsMs: beats);
      // Two bars on repeat, turning round at 4000. The call at 3500 is for
      // the D at 4000, which is on the far side of the turn: nobody is going
      // to play it, so nobody is told about it.
      expect(nextChordCall(1500, calls: calls, untilMs: 4000), isNull);
      expect(
        nextChordCall(0, calls: calls, untilMs: 4000),
        calls.first,
        reason: 'the chord inside the passage is still called',
      );
    });

    test('a passage drilled at 70% is called at 70%', () {
      final calls = chordCalls(cues: cues, beatsMs: beats);
      // The call has not moved in the song — it is still a beat and a half
      // in — but the song takes ten sevenths as long to reach it.
      expect(
        untilCalled(calls.first, fromMs: 0),
        const Duration(milliseconds: 1500),
      );
      expect(
        untilCalled(calls.first, fromMs: 0, rate: 0.7),
        const Duration(microseconds: 2142857),
      );
      expect(
        untilCalled(calls[1], fromMs: 1500, rate: 0.7),
        const Duration(microseconds: 2857143),
      );
      // A call that was scheduled a hair late is made now rather than never.
      expect(untilCalled(calls.first, fromMs: 2000), Duration.zero);
    });
  });

  group('what this phone remembers', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('off is the absence of a choice, and comes back off', () async {
      expect(await HearTheChordsStore.load(), HearTheChords.off);
      await HearTheChordsStore.save(HearTheChords.on);
      expect(await HearTheChordsStore.load(), HearTheChords.on);
      await HearTheChordsStore.save(HearTheChords.off);
      expect(await HearTheChordsStore.load(), HearTheChords.off);
      expect(HearTheChords.fromStored('something later'), HearTheChords.off);
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-hear',
      roomId: 'room',
      accountId: 'account',
      title: 'Weathervane',
      createdAt: day,
      updatedAt: day,
      keyOverride: 'G',
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-hear',
          authorId: 'u2',
          authorName: 'Jess',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: day,
          position: 1,
        ),
      ],
    );

    const words = <TranscriptWord>[
      TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
      TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
      TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
      TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
    ];

    final withChords = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-hear',
        fileId: 'file',
        storagePath: 'room/song-hear/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 16000,
        bpm: 120,
        beatsPerBar: 4,
        beatsMs: beats,
        downbeatsMs: downbeats,
        musicalKey: 'G',
        transcriptText: 'turning in the wind',
        transcriptWords: words,
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: cues,
    );

    const noChords = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-hear',
        fileId: 'file',
        storagePath: 'room/song-hear/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 16000,
        bpm: 120,
        beatsPerBar: 4,
        beatsMs: <int>[],
        downbeatsMs: <int>[],
        transcriptText: 'turning in the wind',
        transcriptWords: words,
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    Future<void> sized(
      WidgetTester tester, {
      bool hear = false,
      bool countIn = false,
      String? numbers,
      String? horn,
      int? capo,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'live_countdown_enabled': countIn,
        if (hear) 'live_hear_the_chords': HearTheChords.on.stored,
        if (numbers != null) 'song_numbers_song-hear': numbers,
        if (horn != null) 'song_reading_song-hear': horn,
        if (capo != null) 'song_capo_song-hear': capo,
      });
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    /// The clock the song is kept by, handed to the screen so it is the one
    /// the test moves. Without it the timers run on the test's clock and the
    /// song runs on the wall clock, which does not move during a test.
    DateTime Function() clockOf(WidgetTester tester) =>
        () => tester.binding.clock.now();

    /// Closes the sound sheet.
    ///
    /// Popped rather than dismissed with a tap outside it: the sheet now
    /// carries four sections and on a phone-sized screen there is no longer a
    /// reliable patch of barrier to aim at.
    Future<void> closeSheet(WidgetTester tester) async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
    }

    testWidgets('the next chord is said a beat before it lands',
        (tester) async {
      await sized(tester, hear: true);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      expect(voice.said, isEmpty, reason: 'the press is not a beat');

      // The C arrives on the bar line at two seconds, so it is called on the
      // beat before it.
      await tester.pump(const Duration(milliseconds: 1499));
      expect(voice.said, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(voice.said, <String>['C']);

      // And on through the song, a beat ahead each time.
      await tester.pump(const Duration(milliseconds: 2000));
      expect(voice.said, <String>['C', 'D seven']);
      await tester.pump(const Duration(milliseconds: 2000));
      expect(voice.said, <String>['C', 'D seven', 'G']);

      // Paused, the voice stops mid-word and says nothing more.
      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      expect(voice.hushes, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 4000));
      expect(voice.said, hasLength(3));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(voice.disposed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a passage drilled at 70% is called at 70%', (tester) async {
      await sized(tester, hear: true);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // Down the speeds one step at a time: 90, 80, 75, 70.
      for (var step = 0; step < 4; step += 1) {
        await tester.tap(find.byKey(const Key('live_rate_slower')));
        await tester.pump();
      }
      expect(find.text('70%'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      // The call has not moved in the song — a beat and a half in — but the
      // song is taking ten sevenths as long to get there.
      await tester.pump(const Duration(milliseconds: 2142));
      expect(voice.said, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(voice.said, <String>['C']);

      // Still on the song's own changes two bars later, rather than running
      // away from them: the wait is measured from where the song is every
      // time, never from the last call.
      await tester.pump(const Duration(milliseconds: 5715));
      expect(voice.said, <String>['C', 'D seven', 'G']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Nashville reader hears four, a B-flat player hears their '
        'own note', (tester) async {
      // The song is in G and the chords are G, C, D7, G. In numbers that is
      // 1, 4, 5-with-a-seven, 1, whatever key anybody moves it to.
      await sized(tester, hear: true, numbers: 'numbers');
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3500));
      expect(voice.said, <String>['four', 'five seven']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // The same song read for a B♭ instrument: a concert C is written D, and
      // that is the note the player has to finger.
      await sized(tester, hear: true, horn: 'Bb');
      final horn = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: horn,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3500));
      expect(horn.said, <String>['D', 'E seven']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a capo is heard where the hand goes, not where it sounds',
        (tester) async {
      // Capo 2 on a song in G: the shapes on the page are F, B♭, C7, F, and
      // those are the shapes the hand makes. What is said out loud has to be
      // the same chord as what is printed over the word, or a player is
      // being told one thing and shown another.
      await sized(tester, hear: true, capo: 2);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3500));
      expect(voice.said, <String>['B flat', 'C seven']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing is said until somebody asks for it', (tester) async {
      await sized(tester);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 6000));
      expect(voice.said, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing is said over a count-in', (tester) async {
      await sized(tester, hear: true, countIn: true);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
          click: _SilentClick(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      // Four beats of the song's own tempo, counted. The song has not started
      // and nothing is said over the count: a name in the middle of "one, two,
      // three, four" is a fifth thing to listen to.
      await tester.pump(const Duration(milliseconds: 1999));
      expect(find.byKey(const Key('live_count_in')), findsOneWidget);
      expect(voice.said, isEmpty);

      // The count hands the song over on the beat after the fourth, and the
      // song starts at nothing: still nothing said, because the first change
      // is a bar and a half away.
      await tester.pump(const Duration(milliseconds: 2));
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(voice.said, isEmpty);

      // And the calls start from there, a beat ahead of the change as always.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(voice.said, <String>['C']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the choice is offered only where there is a chord to call',
        (tester) async {
      await sized(tester);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // The button that leads to it says so, which is also what a screen
      // reader reads out — and the player this is written for is reading that
      // button with their ears.
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('live_countdown_settings')))
            .tooltip,
        'Count-in, beat, chords and drone',
      );

      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.text('Hear the chords coming'), findsOneWidget);
      await closeSheet(tester);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: noChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('live_countdown_settings')))
            .tooltip,
        'Count-in and drone',
        reason: 'a song with no chords and no beat is offered neither',
      );
      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.text('Hear the chords coming'), findsNothing);

      await closeSheet(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning it on starts the calls, and is remembered',
        (tester) async {
      await sized(tester);
      final voice = _WrittenDown();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: withChords,
          now: clockOf(tester),
          chordVoice: voice,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_hear_chords_on')));
      await tester.pumpAndSettle();
      // The chip they tapped is the one that is lit. The sheet is its own
      // route, so it has to keep the answer itself.
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('live_hear_chords_on')))
            .selected,
        isTrue,
      );
      await closeSheet(tester);

      expect(await HearTheChordsStore.load(), HearTheChords.on);

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      expect(voice.said, <String>['C']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
