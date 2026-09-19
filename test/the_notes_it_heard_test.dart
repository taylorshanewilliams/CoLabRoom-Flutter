import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/melody_reading.dart';
import 'package:colabroom/services/number_reading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The notes it heard, in sargam, jianpu or do-re-mi.
///
/// Every Musician, Same Song, 17 September 2026, build order slice 34. The
/// pipeline has heard the tune since 0106 and the app has only ever said it
/// back in letters, which is one of several ways the world writes a melody
/// and not the most widely taught one. A solfège class reads do re mi; a
/// student of Hindustani music reads Sa Re Ga; a great many people read
/// jianpu's numbers with their octave dots.
///
/// The rules this holds to: it is a reading, so it is kept on this device,
/// never written to the room and never carried by Follow me; a reading
/// counted from the 1 does not move when somebody transposes the song, and
/// fixed do does because it names a sounding pitch; the row says what it is
/// and no more, with no accuracy figure anywhere; and a stem that was barely
/// sung gets no row at all rather than a page of invented syllables.

/// The komal and tivra marks, written out rather than built the way the code
/// builds them: a test that spells its own expectations from the same helper
/// as the thing it is testing cannot fail.
const String _komalRe = 'R̲e̲';
const String _komalGa = 'G̲a̲';
const String _tivraMa = 'M̅a̅';
const String _komalDha = 'D̲h̲a̲';
const String _komalNi = 'N̲i̲';

const String _dotAbove = '̇';
const String _dotBelow = '̣';

MelodyNote _note(int startMs, int endMs, int midi, {int cents = 0}) =>
    MelodyNote(startMs: startMs, endMs: endMs, midi: midi, cents: cents);

/// A major scale sung from the 1, an octave, one note every half second.
Melody _scale({int from = 60, double? voiced = 0.42}) {
  const steps = <int>[0, 2, 4, 5, 7, 9, 11, 12];
  return Melody(
    notes: <MelodyNote>[
      for (var i = 0; i < steps.length; i += 1)
        _note(i * 500, i * 500 + 400, from + steps[i]),
    ],
    lowMidi: from,
    highMidi: from + 12,
    voicedRatio: voiced,
  );
}

List<String> _read(
  Melody melody,
  MelodyReading reading, {
  String? key = 'C',
  int transpose = 0,
  int? sa,
  MinorNumbers minor = MinorNumbers.relativeMajor,
}) {
  final spelling = MelodySpelling.forSong(
    reading: reading,
    melody: melody,
    key: key,
    transpose: transpose,
    sa: sa,
    minor: minor,
  );
  return melody.notes.map(spelling!.of).toList(growable: false);
}

/// A handful of notes given as MIDI numbers, long enough to be steady.
Melody _tune(List<int> midis, {double voiced = 0.4}) => Melody(
      notes: <MelodyNote>[
        for (var i = 0; i < midis.length; i += 1)
          _note(i * 500, i * 500 + 400, midis[i]),
      ],
      lowMidi: midis.reduce((a, b) => a < b ? a : b),
      highMidi: midis.reduce((a, b) => a > b ? a : b),
      voicedRatio: voiced,
    );

void main() {
  group('the same eight notes, in four languages', () {
    final scale = _scale();

    test('movable do counts from the 1', () {
      expect(_read(scale, MelodyReading.movableDo), <String>[
        'do', 're', 'mi', 'fa', 'sol', 'la', 'ti', 'do',
      ]);
    });

    test('fixed do names the pitch, wherever the 1 is', () {
      // The same eight notes read in a song in C and in a song in A minor:
      // fixed do is about what is sounding, so it does not care.
      expect(_read(scale, MelodyReading.fixedDo), <String>[
        'Do', 'Re', 'Mi', 'Fa', 'Sol', 'La', 'Si', 'Do',
      ]);
      expect(
        _read(scale, MelodyReading.fixedDo, key: 'A minor'),
        _read(scale, MelodyReading.fixedDo),
      );
    });

    test('sargam counts from Sa', () {
      expect(_read(scale, MelodyReading.sargam), <String>[
        'Sa', 'Re', 'Ga', 'Ma', 'Pa', 'Dha', 'Ni', 'Sa',
      ]);
    });

    test('jianpu counts 1 to 7, and dots the octave above', () {
      expect(_read(scale, MelodyReading.jianpu), <String>[
        '1', '2', '3', '4', '5', '6', '7', '1$_dotAbove',
      ]);
    });

    test('the three counted from the 1 do not move when the song does', () {
      // The whole reason a singer reads syllables: the tune is the same
      // shape in every key, exactly like the Nashville numbers over the
      // words. Fixed do is the one that moves, because it names the pitch
      // that is actually sounding after somebody drops the song.
      for (final reading in <MelodyReading>[
        MelodyReading.movableDo,
        MelodyReading.sargam,
        MelodyReading.jianpu,
      ]) {
        expect(
          _read(scale, reading, transpose: -3),
          _read(scale, reading),
          reason: '${reading.name} moved with the transpose',
        );
      }
      // Down three from C is A, and the sounding pitches come with it: the
      // mi of the scale is now a C♯, spelled the way A major spells it.
      expect(
        _read(scale, MelodyReading.fixedDo, transpose: -3).take(3),
        <String>['La', 'Si', 'Do♯'],
      );
    });

    test('a person can pick their own Sa without touching the song', () {
      // The song stays in C. This device counts from D, so the same eight
      // notes read from the seventh.
      expect(
        _read(scale, MelodyReading.sargam, sa: 2).take(3),
        <String>[_komalNi, 'Sa', 'Re'],
      );
      // And the song's key is untouched: read it without the Sa again.
      expect(_read(scale, MelodyReading.sargam).first, 'Sa');
    });
  });

  group('the notes between the seven', () {
    // The five black notes of C, sung in order.
    final chromatic = Melody(
      notes: <MelodyNote>[
        _note(0, 400, 61),
        _note(500, 900, 63),
        _note(1000, 1400, 66),
        _note(1500, 1900, 68),
        _note(2000, 2400, 70),
      ],
      lowMidi: 61,
      voicedRatio: 0.4,
    );

    test('sargam marks komal under the syllable and tivra over it', () {
      // Re, Ga, Dha and Ni are komal when lowered; Ma is tivra when raised;
      // Sa and Pa have no variants at all.
      expect(_read(chromatic, MelodyReading.sargam), <String>[
        _komalRe, _komalGa, _tivraMa, _komalDha, _komalNi,
      ]);
    });

    test('movable do names a degree, and a degree has one name', () {
      // ♭2 ♭3 ♯4 ♭6 ♭7, which is what the numbers over the words say too:
      // these are scale degrees, not letters, so no key signature gets a
      // vote on them.
      expect(_read(chromatic, MelodyReading.movableDo), <String>[
        'ra', 'me', 'fi', 'le', 'te',
      ]);
      // Counted from F the same five pitches are the 8, the 10, the 1, the 3
      // and the 5, and they are named by where they sit and nothing else.
      expect(_read(chromatic, MelodyReading.movableDo, key: 'F'), <String>[
        'le', 'te', 'ra', 'me', 'fa',
      ]);
    });

    test('jianpu writes the accidental in front of the number', () {
      expect(_read(chromatic, MelodyReading.jianpu), <String>[
        '♭2', '♭3', '♯4', '♭6', '♭7',
      ]);
    });

    test('the flat third and flat seventh agree with the numbers above them',
        () {
      // With Nashville numbers on, a chord labelled ♭7 sits over the words
      // and the sung note under them had better not be labelled ♯6.
      final blue = _tune(<int>[60, 63, 70]);
      expect(_read(blue, MelodyReading.movableDo), <String>[
        'do', 'me', 'te',
      ]);
      expect(_read(blue, MelodyReading.jianpu), <String>['1', '♭3', '♭7']);
    });

    test('the same tune reads the same in every minor key', () {
      // The one thing a reading counted from the 1 must never do is change
      // syllables when the song changes key. Sharp-side minors (A, E, B) and
      // flat-side ones (D, G, C) used to come out differently.
      for (final reading in <MelodyReading>[
        MelodyReading.movableDo,
        MelodyReading.sargam,
        MelodyReading.jianpu,
      ]) {
        final inA = _read(_tune(<int>[69, 72, 74, 76]), reading, key: 'A minor');
        for (final root in <(String, int)>[
          ('E minor', 64),
          ('B minor', 71),
          ('D minor', 62),
          ('G minor', 67),
          ('C minor', 60),
        ]) {
          expect(
            _read(
              _tune(<int>[root.$2, root.$2 + 3, root.$2 + 5, root.$2 + 7]),
              reading,
              key: root.$1,
            ),
            inA,
            reason: '${reading.name} read ${root.$1} differently from A minor',
          );
        }
      }
    });
  });

  group('a minor song is counted from the note this person counts from', () {
    // A minor's own scale, from the tonic: A B C D E F G.
    final aMinor = _tune(<int>[69, 71, 72, 74, 76, 77, 79]);

    test('jianpu writes a minor song against its relative major', () {
      // 1=C for a song in A minor, so the tonic reads 6. That is the
      // notation rather than a preference, so it is not offered as one. The
      // two below the 1 of the middle octave take their dots, as they would
      // on any page.
      expect(_read(aMinor, MelodyReading.jianpu, key: 'A minor'), <String>[
        '6$_dotBelow', '7$_dotBelow', '1', '2', '3', '4', '5',
      ]);
      expect(
        _read(aMinor, MelodyReading.jianpu,
            key: 'A minor', minor: MinorNumbers.minorTonic),
        _read(aMinor, MelodyReading.jianpu, key: 'A minor'),
      );
    });

    test('movable do follows the answer given for the numbers', () {
      // La-based minor by default, which is the convention that goes with
      // counting the chords from the relative major.
      expect(_read(aMinor, MelodyReading.movableDo, key: 'A minor'), <String>[
        'la', 'ti', 'do', 're', 'mi', 'fa', 'sol',
      ]);
      // And do-based minor for somebody who counts a minor song from 1-:
      // me, le and te, never ri, si and li.
      expect(
        _read(aMinor, MelodyReading.movableDo,
            key: 'A minor', minor: MinorNumbers.minorTonic),
        <String>['do', 're', 'me', 'fa', 'sol', 'le', 'te'],
      );
    });

    test('sargam counts from Sa, and Sa is the tonic', () {
      // A raga with a komal Ga is still counted from its own Sa, so neither
      // convention moves it.
      for (final convention in MinorNumbers.values) {
        expect(
          _read(aMinor, MelodyReading.sargam,
              key: 'A minor', minor: convention),
          <String>['Sa', 'Re', _komalGa, 'Ma', 'Pa', _komalDha, _komalNi],
        );
      }
    });

    test('a picked Sa answers the question, so nothing is inferred', () {
      // Somebody who has said where their 1 is has said it. The minor
      // convention has nothing left to decide.
      for (final convention in MinorNumbers.values) {
        expect(
          _read(aMinor, MelodyReading.jianpu,
              key: 'A minor', sa: 9, minor: convention),
          <String>['1', '2', '♭3', '4', '5', '♭6', '♭7'],
        );
      }
    });
  });

  group('jianpu says which octave', () {
    test('the middle octave is the 1 under the middle of the voice', () {
      // A tune from G3 to C5 in a song in C sits around the middle of the
      // fourth octave, so C4 is the undotted 1: the G below it takes a dot
      // under, the C above it a dot over. Counting from the lowest note
      // instead would push everything from C4 up an octave.
      final tune = Melody(
        notes: <MelodyNote>[
          _note(0, 400, 55),
          _note(500, 900, 60),
          _note(1000, 1400, 67),
          _note(1500, 1900, 72),
        ],
        lowMidi: 55,
        highMidi: 72,
        voicedRatio: 0.4,
      );
      expect(_read(tune, MelodyReading.jianpu), <String>[
        '5$_dotBelow', '1', '5', '1$_dotAbove',
      ]);
    });

    test('two octaves out is two dots', () {
      // C3, C4 and C6: the middle of that is F4, so the C below it is the
      // undotted 1, and the two ends take one dot and two.
      final tune = Melody(
        notes: <MelodyNote>[
          _note(0, 400, 48),
          _note(500, 900, 60),
          _note(1000, 1400, 84),
        ],
        lowMidi: 48,
        highMidi: 84,
        voicedRatio: 0.4,
      );
      expect(_read(tune, MelodyReading.jianpu), <String>[
        '1$_dotBelow',
        '1',
        '1$_dotAbove$_dotAbove',
      ]);
    });
  });

  group('never more than the analysis knows', () {
    test('cents are heard and never said', () {
      // pyin rounds to the nearest semitone and says how far off it sat.
      // That is enough to name the nearest note and nowhere near enough to
      // name a sruti, so the same note read forty cents flat is the same
      // syllable.
      final bent = Melody(
        notes: <MelodyNote>[
          _note(0, 400, 63, cents: -45),
          _note(500, 900, 63, cents: 40),
        ],
        lowMidi: 63,
        voicedRatio: 0.4,
      );
      expect(_read(bent, MelodyReading.sargam), <String>[_komalGa, _komalGa]);
    });

    test('a stem that was barely sung is not read out at all', () {
      // A vocal stem comes back for every song, including the ones nobody
      // sang on, and a tracker finds pitches in whatever bleed is left in
      // it. A row drawn off that names notes nobody sang.
      expect(_scale(voiced: 0.4).worthReading, isTrue);
      expect(_scale(voiced: 0.01).worthReading, isFalse);
      expect(
        _scale(voiced: Melody.readableVoicedRatio).worthReading,
        isTrue,
        reason: 'the threshold itself is enough',
      );
      expect(
        const Melody(notes: <MelodyNote>[], voicedRatio: 0.9).worthReading,
        isFalse,
      );
      // An analysis from before the worker measured it is left as it was,
      // rather than hidden on a guess.
      expect(_scale(voiced: null).worthReading, isTrue);

      expect(
        MelodySpelling.forSong(
          reading: MelodyReading.sargam,
          melody: _scale(voiced: 0.01),
          key: 'C',
        ),
        isNull,
      );
    });

    test('a song with one sung verse keeps its notes', () {
      // voiced_ratio is the share of every frame of the stem pyin called
      // voiced, not the share of the sung passages, so it is capped by how
      // much of the song is sung at all. Four minutes with one thirty-second
      // verse is an eighth at best, and nearer a fourteenth once consonants
      // and breaths are taken out -- and it has real words with real notes
      // under them, so it keeps them.
      expect(_scale(voiced: 30 / 240).worthReading, isTrue);
      expect(_scale(voiced: 0.07).worthReading, isTrue);
    });

    test('letters, no tune, or no 1 to count from means no spelling', () {
      expect(
        MelodySpelling.forSong(
          reading: MelodyReading.letters,
          melody: _scale(),
          key: 'C',
        ),
        isNull,
      );
      expect(
        MelodySpelling.forSong(
          reading: MelodyReading.sargam,
          melody: null,
          key: 'C',
        ),
        isNull,
      );
      // Key detection falls back on plenty of real recordings. Sargam
      // counted from nothing would be a made-up 1.
      expect(
        MelodySpelling.forSong(
          reading: MelodyReading.sargam,
          melody: _scale(),
          key: null,
        ),
        isNull,
      );
      // Unless this person has said where their own Sa is.
      expect(
        MelodySpelling.forSong(
          reading: MelodyReading.sargam,
          melody: _scale(),
          key: null,
          sa: 0,
        ),
        isNotNull,
      );
      // Fixed do never needed a 1.
      expect(
        MelodySpelling.forSong(
          reading: MelodyReading.fixedDo,
          melody: _scale(),
          key: null,
        ),
        isNotNull,
      );
    });
  });

  group('the row under the words', () {
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
    // "turning in the wind", sung C4 D4 E4 E4 -- the last two words carried
    // on one held note.
    final tune = Melody(
      notes: <MelodyNote>[
        _note(1060, 1480, 60),
        _note(1540, 1780, 62),
        _note(1840, 2900, 64),
      ],
      lowMidi: 60,
      voicedRatio: 0.4,
    );

    MelodySpelling spelling(MelodyReading reading) => MelodySpelling.forSong(
          reading: reading,
          melody: tune,
          key: 'C',
        )!;

    test('one syllable a word, in the language this person reads', () {
      expect(
        notesForWords(tune, line.wordStartsMs, line.endMs, 4,
            transpose: 0, key: 'C', spelling: spelling(MelodyReading.sargam)),
        <String?>['Sa', 'Re', 'Ga', 'Ga'],
      );
    });

    test('jianpu repeats the number rather than writing a dash', () {
      // A dash in jianpu is a beat: it holds the note before it and never
      // carries a syllable. This row is laid out by words, and whether two
      // words at one pitch arrive as one sung note or two is pyin finding a
      // gap between them, so a dash here would say something the analysis
      // never heard.
      expect(
        notesForWords(tune, line.wordStartsMs, line.endMs, 4,
            transpose: 0, key: 'C', spelling: spelling(MelodyReading.jianpu)),
        <String?>['1', '2', '3', '3'],
      );
      // Three words on one sung note read as three, not as one and two
      // blanks.
      const held = MusicianSheetLine(
        contributionId: null,
        body: 'hold it there',
        section: false,
        startMs: 0,
        endMs: 1500,
        chords: <ChordCue>[],
        approximateTiming: false,
        wordStartsMs: <int>[0, 500, 1000],
      );
      final one = Melody(
        notes: <MelodyNote>[_note(0, 1500, 67)],
        lowMidi: 67,
        highMidi: 67,
        voicedRatio: 0.4,
      );
      expect(
        notesForWords(one, held.wordStartsMs, held.endMs, 3,
            transpose: 0,
            key: 'C',
            spelling: MelodySpelling.forSong(
              reading: MelodyReading.jianpu,
              melody: one,
              key: 'C',
            )),
        <String?>['5', '5', '5'],
      );
    });

    test('a tune too thin to read carries no notes, in any language', () {
      final thin = Melody(
        notes: tune.notes,
        lowMidi: 60,
        voicedRatio: 0.03,
      );
      expect(
        notesForWords(thin, line.wordStartsMs, line.endMs, 4,
            transpose: 0, key: 'C'),
        isEmpty,
      );
    });

    testWidgets('Perform draws the line being sung in that language',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: MusicianChordLyricLine(
            line: line,
            transpose: 0,
            musicalKey: 'C',
            fontScale: 1.5,
            showChords: false,
            liveMode: true,
            active: true,
            elapsedMs: 1900,
            melody: tune,
            spelling: spelling(MelodyReading.sargam),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      expect(find.text('Sa'), findsOneWidget);
      expect(find.text('Re'), findsOneWidget);
      expect(find.text('Ga'), findsNWidgets(2));
      // And not the letters it would have read in before.
      expect(find.text('C4'), findsNothing);
    });

    testWidgets('the sheet carries them only once somebody has asked',
        (tester) async {
      Future<void> pump(MelodySpelling? chosen) => tester.pumpWidget(MaterialApp(
            theme: CoLabRoomTheme.dark(),
            home: Scaffold(
              body: MusicianChordLyricLine(
                line: line,
                transpose: 0,
                musicalKey: 'C',
                fontScale: 1.5,
                showChords: false,
                melody: tune,
                spelling: chosen,
              ),
            ),
          ));

      // A page of notes under every word is a score and the sheet is not
      // one -- until somebody chooses a language to read them in.
      await pump(null);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('do'), findsNothing);
      expect(find.text('C4'), findsNothing);

      await pump(spelling(MelodyReading.movableDo));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('do'), findsOneWidget);
      expect(find.text('re'), findsOneWidget);
      expect(find.text('mi'), findsNWidgets(2));
    });
  });

  group('it is this device’s, and nobody else’s', () {
    test('the reading is kept per song, and letters are kept as nothing',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await MelodyReadingStore.save('song-a', MelodyReading.sargam);
      expect(await MelodyReadingStore.load('song-a'), MelodyReading.sargam);
      expect(await MelodyReadingStore.load('song-b'), MelodyReading.letters);

      await MelodyReadingStore.save('song-a', MelodyReading.letters);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('song-a')), isEmpty);
    });

    test('a value this version does not know reads as letters', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'melody_reading_song-c': 'neumes',
      });
      expect(await MelodyReadingStore.load('song-c'), MelodyReading.letters);
    });

    test('a picked Sa is kept, and the song’s own key is kept as nothing',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await MelodySaStore.load('song-sa'), isNull);

      await MelodySaStore.save('song-sa', 1);
      expect(await MelodySaStore.load('song-sa'), 1);

      await MelodySaStore.save('song-sa', null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('song-sa')), isEmpty);

      // A pitch class is 0 to 11. Anything else is not an answer.
      await MelodySaStore.save('song-sa', 40);
      expect(await MelodySaStore.load('song-sa'), isNull);
    });

    test('Follow me does not carry it, any more than a key or a horn', () {
      const state = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 5000,
        rate: 1,
        sentAt: 1,
      );
      expect(
        state.toJson().keys.where((name) =>
            name.contains('melody') ||
            name.contains('sargam') ||
            name.contains('jianpu') ||
            name.contains('notes')),
        isEmpty,
      );
    });
  });

  testWidgets('the sheet opens in the language this device reads in',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'melody_reading_song-notes': 'sargam',
    });
    tester.view.physicalSize = const Size(520, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-notes'),
            bundle: _analysis('song-notes'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // Named for what it is, once, beside the rest of the reading. No
    // percentage and no "this may not fit".
    expect(
      find.text('The notes it heard, in sargam'),
      findsOneWidget,
    );
    expect(find.text('Sa'), findsOneWidget);
    expect(find.text('Re'), findsOneWidget);
    expect(find.text('Ga'), findsOneWidget);
    expect(find.text('Ma'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the choice is made where the key is, and kept', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-pick'),
            bundle: _analysis('song-pick'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('song_sheet_melody_row')), findsNothing);

    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.text('THE NOTES IT HEARD'), findsOneWidget);

    await tester.tap(find.byKey(const Key('read_notes_jianpu')));
    await tester.pumpAndSettle();
    expect(await MelodyReadingStore.load('song-pick'), MelodyReading.jianpu);
    // Counted from the song's own key until this person says otherwise.
    expect(find.textContaining('The 1 is C.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sa_is_D')));
    await tester.pumpAndSettle();
    expect(await MelodySaStore.load('song-pick'), 2);
    // And handing it back to the song's key is the same row.
    await tester.tap(find.byKey(const Key('sa_is_C')));
    await tester.pumpAndSettle();
    expect(await MelodySaStore.load('song-pick'), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a song with nothing sung on it is offered no language',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'melody_reading_song-thin': 'sargam',
    });
    tester.view.physicalSize = const Size(520, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-thin'),
            bundle: _analysis('song-thin', voiced: 0.02),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // The reading is still kept on the device; there is simply nothing worth
    // reading out, so the row and the choice are both absent.
    expect(find.byKey(const Key('song_sheet_melody_row')), findsNothing);
    expect(find.text('Sa'), findsNothing);

    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.text('THE NOTES IT HEARD'), findsNothing);
    expect(find.byKey(const Key('read_notes_sargam')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a song with no key still offers a language for its notes',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _pumpPanel(
      tester,
      _analysis('song-nokey', musicalKey: null),
      _project('song-nokey'),
    );

    // No key was found, so there is no badge — and the transpose label is
    // the control that is always there.
    expect(find.byKey(const Key('song_sheet_key_badge')), findsNothing);
    await tester.tap(find.byKey(const Key('song_sheet_read_as')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reading_choice_sheet')), findsOneWidget);
    expect(find.text('THE NOTES IT HEARD'), findsOneWidget);

    // Fixed do never needed a key at all.
    await tester.tap(find.byKey(const Key('read_notes_fixedDo')));
    await tester.pumpAndSettle();
    expect(await MelodyReadingStore.load('song-nokey'), MelodyReading.fixedDo);

    // And a reading counted from the 1 is offered one to count from.
    await tester.tap(find.byKey(const Key('read_notes_sargam')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sa is yours to pick here'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('sa_is_D')));
    await tester.tap(find.byKey(const Key('sa_is_D')));
    await tester.pumpAndSettle();
    expect(await MelodySaStore.load('song-nokey'), 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Perform opens in the language left on the sheet',
      (tester) async {
    // Perform has no picker of its own -- no reading does -- so the one
    // thing that has to work on stage is reading the choice back. The row
    // itself only draws under the line being sung, which needs the song
    // playing, so what this holds is that the screen comes up with the
    // choice loaded and nothing thrown.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'melody_reading_song-stage': 'sargam',
      'melody_sa_song-stage': 2,
    });
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: LivePerformanceScreen(
        project: _project('song-stage'),
        analysis: _analysis('song-stage'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('wind'), findsWidgets);
    // And the choice stayed where it was put: on this device, for this song.
    expect(await MelodyReadingStore.load('song-stage'), MelodyReading.sargam);
    expect(await MelodySaStore.load('song-stage'), 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('words with no timings are offered no language', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _pumpPanel(
      tester,
      _analysis('song-untimed', timedWords: false),
      _project('song-untimed'),
    );

    // The row is laid out word by word. Transcription came back as text with
    // no timings, so there is nowhere to put it and nothing to choose: a
    // language chip here would name a row drawn nowhere.
    expect(find.byKey(const Key('song_sheet_melody_row')), findsNothing);
    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.text('THE NOTES IT HEARD'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

/// A song whose analysis never found a key still has a tune, and there is
/// still something to choose: fixed do names the pitch it heard, and anybody
/// counting from a 1 can say where theirs is.
Future<void> _pumpPanel(WidgetTester tester, SongAnalysisBundle bundle,
    SongProject project) async {
  tester.view.physicalSize = const Size(520, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: SongSheetPanel(
          project: project,
          bundle: bundle,
          onReviewLyrics: null,
          onOpenLive: null,
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
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

/// A song in C with four words and the four notes they were sung on.
SongAnalysisBundle _analysis(
  String id, {
  double voiced = 0.42,
  String? musicalKey = 'C',
  bool timedWords = true,
}) =>
    SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 20000,
        musicalKey: musicalKey,
        transcriptText: 'turning in the wind',
        transcriptWords: timedWords
            ? const <TranscriptWord>[
                TranscriptWord(word: 'turning', startMs: 5000, endMs: 5800),
                TranscriptWord(word: 'in', startMs: 5800, endMs: 6100),
                TranscriptWord(word: 'the', startMs: 6100, endMs: 6400),
                TranscriptWord(word: 'wind', startMs: 6400, endMs: 7200),
              ]
            : const <TranscriptWord>[],
        melody: Melody(
          notes: <MelodyNote>[
            _note(5040, 5700, 60),
            _note(5840, 6050, 62),
            _note(6140, 6350, 64),
            _note(6440, 7100, 65),
          ],
          lowMidi: 60,
          highMidi: 65,
          voicedRatio: voiced,
        ),
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[
        ChordCue(
            id: 1, startMs: 5000, endMs: 7200, chord: 'C:maj', confidence: 0.9),
      ],
    );
