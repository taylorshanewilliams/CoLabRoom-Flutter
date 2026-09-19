import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/bass_and_piano_diagrams.dart';
import 'package:colabroom/features/workspace/guitar_chord_diagram.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:colabroom/services/shape_reading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The same chord, four pictures of it.
///
/// Every Musician, Same Song, 17 September 2026: the diagrams were a
/// right-handed six-string guitar in standard tuning, so a uke player, a bass
/// player and a pianist were all being handed somebody else's instrument, and
/// a left-handed guitarist was being handed it the wrong way round. None of
/// these compose anything — a shape and a chord tone describe, a line you are
/// told to play composes — and none of them is shared with the room.
void main() {
  group('what a ukulele player puts their hand on', () {
    test('a dozen chords a uke class is taught', () {
      // Fourth string to first, G C E A. These are the grips, not the notes
      // moved over from a guitar: the top four strings of a guitar are the
      // same intervals a fourth down, which gets the notes right and the hand
      // wrong.
      expect(_uke('C'), <int>[0, 0, 0, 3]);
      expect(_uke('F'), <int>[2, 0, 1, 0]);
      expect(_uke('G'), <int>[0, 2, 3, 2]);
      expect(_uke('Am'), <int>[2, 0, 0, 0]);
      expect(_uke('Dm'), <int>[2, 2, 1, 0]);
      expect(_uke('Em'), <int>[0, 4, 3, 2]);
      expect(_uke('A7'), <int>[0, 1, 0, 0]);
      expect(_uke('D7'), <int>[2, 2, 2, 3]);
      expect(_uke('G7'), <int>[0, 2, 1, 2]);
      expect(_uke('E7'), <int>[1, 2, 0, 2]);
      expect(_uke('Bb'), <int>[3, 2, 1, 1]);
      expect(_uke('Bm'), <int>[4, 2, 2, 2]);
      // Am7 is four open strings, which is the first chord anybody is shown.
      expect(_uke('Am7'), <int>[0, 0, 0, 0]);
    });

    test('both spellings of a root reach the same grip', () {
      // The table is written the way a uke book writes it and a chart in a
      // sharp key is written the other way.
      expect(_uke('A#'), _uke('Bb'));
      expect(_uke('D#m'), _uke('Ebm'));
      expect(_uke('Gb'), _uke('F#'));
      // And the Harte labels the analysis produces go through it too.
      expect(_uke('A:min7'), _uke('Am7'));
    });

    test('every shape sounds the chord and nothing else', () {
      // The guard on a hand-written table: whatever comes back, every string
      // that sounds is a note of the chord asked for, and the root is in
      // there. A shape with a note the chord does not contain would be the
      // app playing something nobody wrote.
      for (final root in _theTwelve) {
        for (final quality in const <String>[
          '', 'm', '7', 'm7', 'maj7', 'm7b5', '°', '+', 'sus2', 'sus4', '5',
          '6', 'm6', '9', 'm9', 'maj9', 'add9', '11', '13', '7sus4',
        ]) {
          final label = '$root$quality';
          final tones = chordReference(label)!
              .tones
              .map((tone) => pitchOf(tone.note)! % 12)
              .toSet();
          for (final shape in ukuleleShapesFor(label)) {
            expect(shape.frets.length, 4, reason: label);
            final sounded = <int>{};
            for (var s = 0; s < 4; s += 1) {
              final fret = shape.frets[s];
              if (fret < 0) continue;
              sounded.add(
                  (ukuleleTuning[s] + shape.baseFret + fret - 1) % 12);
            }
            expect(sounded.difference(tones), isEmpty,
                reason: '$label ${shape.frets} at ${shape.baseFret}');
            expect(sounded, contains(pitchOf(root)! % 12), reason: label);
          }
        }
      }
    });

    test('a shape up the neck says where it starts', () {
      // Nothing in the table sits past the fourth fret, so a chord with no
      // open grip is the movable one and has to bring its own fret with it.
      final shapes = ukuleleShapesFor('C#m7');
      expect(shapes, isNotEmpty);
      expect(shapes.first.baseFret, 4);
      expect(shapes.first.hint, contains('Barre at fret 4'));
    });

    test('a chord nobody has a uke shape for says so by having none', () {
      // The same honesty the guitar has about a 13th: no shape is drawn
      // rather than one that is nearly the chord.
      expect(ukuleleShapesFor('C°'), isEmpty);
      expect(ukuleleShapesFor('C+'), isEmpty);
      expect(ukuleleShapesFor('N'), isEmpty);
      expect(ukuleleShapesFor('Hmaj7'), isEmpty);
    });

    test('a slash bass is not the uke player\'s note', () {
      // The same rule the guitar shapes have followed all along.
      expect(_uke('C/G'), _uke('C'));
    });
  });

  group('the same shape for a left hand', () {
    test('keeps the fret numbers and reverses the strings', () {
      const g = ChordDiagramData(
        name: 'G',
        spokenName: 'G major',
        frets: <int>[3, 2, 0, 0, 0, 3],
      );
      final mirrored = mirrorForLeftHand(g);
      expect(mirrored.frets, <int>[3, 0, 0, 0, 2, 3]);
      expect(mirrored.strings.first, 'High E');
      expect(mirrored.strings.last, 'Low E');
      expect(mirrored.baseFret, g.baseFret);
      // The 3rd fret is the 3rd fret either way round, and it is still the
      // low E that is held there — it is said last now instead of first.
      expect(
        chordDiagramReading(mirrored),
        'G major. High E, 3rd fret. B, open. G, open. D, open. A, 2nd fret. '
        'Low E, 3rd fret.',
      );
    });

    test('a barre is still said, from the other end', () {
      const a = ChordDiagramData(
        name: 'A',
        spokenName: 'A major',
        frets: <int>[1, 3, 3, 2, 1, 1],
        baseFret: 5,
      );
      expect(
        chordDiagramReading(mirrorForLeftHand(a)),
        startsWith('A major. Barre at the 5th fret, High E to Low E.'),
      );
    });

    test('a uke shape mirrors the same way', () {
      final c = ChordDiagramData(
        name: 'C',
        spokenName: 'C major',
        frets: ukuleleShapesFor('C').first.frets,
        strings: ukuleleStrings,
      );
      final mirrored = mirrorForLeftHand(c);
      expect(mirrored.frets, <int>[3, 0, 0, 0]);
      expect(mirrored.strings, <String>['A', 'E', 'C', 'G']);
      expect(
        chordDiagramReading(mirrored),
        'C major. A, 3rd fret. E, open. C, open. G, open.',
      );
    });

    test('mirroring twice is the diagram you started with', () {
      const d = ChordDiagramData(name: 'D', frets: <int>[-1, -1, 0, 2, 3, 2]);
      final there = mirrorForLeftHand(d);
      final back = mirrorForLeftHand(there);
      expect(back.frets, d.frets);
      expect(chordDiagramReading(back), chordDiagramReading(d));
    });
  });

  group('the keys under a pianist\'s hands', () {
    test('the right keys for a slash chord', () {
      final keys = pianoKeysFor('C/G');
      expect(keys.map((key) => key.note), <String>['C', 'E', 'G']);
      expect(keys.map((key) => key.degree), <String>['root', '3rd', '5th']);
      // The G is the chord's own fifth and the note it is written over, so it
      // is that one key marked as both rather than a fourth key.
      expect(keys.where((key) => key.bass).map((key) => key.note), <String>['G']);
      expect(
        pianoKeysReading('C major over G', keys),
        'C major over G. C, the root. E, the 3rd. G, the 5th, and the bass.',
      );
    });

    test('a bass that is not in the chord is marked as the bass', () {
      // D/F♯ in D minor is the third underneath; C/B is a note the C chord
      // does not contain at all, and a pianist plays it anyway.
      final keys = pianoKeysFor('C/B');
      expect(keys.map((key) => key.note), <String>['C', 'E', 'G', 'B']);
      expect(keys.last.degree, 'bass note');
      expect(keys.last.bass, isTrue);
      expect(
        pianoKeysReading('C major over B', keys),
        endsWith('B, in the bass.'),
      );
    });

    test('a keyboard has one of each key, so a 9th is not marked twice', () {
      final keys = pianoKeysFor('Cadd9');
      expect(keys.map((key) => key.note), <String>['C', 'E', 'G', 'D']);
      expect(keys.map((key) => key.pitch).toSet().length, keys.length);
    });

    test('nothing marked that the chord has not got', () {
      for (final label in const <String>[
        'C', 'Am', 'F#m7b5', 'Bb13', 'D7sus4', 'E°7', 'G+', 'Dm9',
      ]) {
        final tones = chordReference(label)!
            .tones
            .map((tone) => pitchOf(tone.note)! % 12)
            .toSet();
        for (final key in pianoKeysFor(label)) {
          expect(tones, contains(key.pitch), reason: '$label ${key.note}');
        }
      }
    });
  });

  group('the root and the fifth on a bass', () {
    test('never a note that is not a chord tone', () {
      // The line this whole reading stays on the right side of: positions
      // describe the chord, and a note that is not in it would be a line
      // somebody had been told to play.
      for (final root in _theTwelve) {
        for (final quality in const <String>[
          '', 'm', '7', 'm7', 'maj7', 'm7b5', '°', '°7', '+', 'sus2', 'sus4',
          '5', '6', 'm6', '9', 'add9', '13',
        ]) {
          final label = '$root$quality';
          final tones = chordReference(label)!
              .tones
              .map((tone) => pitchOf(tone.note)! % 12)
              .toSet();
          final positions = bassPositionsFor(label);
          expect(positions, isNotEmpty, reason: label);
          for (final position in positions) {
            final sounded =
                (bassTuning[position.string] + position.fret) % 12;
            expect(tones, contains(sounded),
                reason: '$label ${position.degree} $sounded');
          }
        }
      }
    });

    test('the fifth is the chord\'s own fifth, never an assumed one', () {
      // A perfect fifth over a diminished or an augmented chord would be a
      // note the chord does not contain.
      expect(_bassNotes('C'), <String>['C', 'G']);
      // Spelled the way the chord sheet already spells this chord's notes: a
      // root that does not ask for flats is written with sharps.
      expect(_bassNotes('C°'), <String>['C', 'F#']);
      expect(_bassNotes('C+'), <String>['C', 'G#']);
      expect(_bassNotes('Cm7b5'), <String>['C', 'F#']);
      expect(_bassNotes('Csus4'), <String>['C', 'G']);
      expect(_bassNotes('Ebm7b5'), <String>['Eb', 'A']);
    });

    test('the root sits where a bass player finds it', () {
      // Lowest down the neck on the E string or the A string, which is where
      // the root of a chord is played.
      final c = bassPositionsFor('C').first;
      expect((c.string, c.fret), (1, 3));
      final e = bassPositionsFor('E').first;
      expect((e.string, e.fret), (0, 0));
      final g = bassPositionsFor('G').first;
      expect((g.string, g.fret), (0, 3));
      // And the fifth two frets up on the next string, which is the shape the
      // hand is already in.
      final fifth = bassPositionsFor('C').last;
      expect((fifth.string, fifth.fret), (2, 5));
      expect(
        bassNeckReading('C major', bassPositionsFor('C')),
        'C major. root, A string, 3rd fret. 5th, D string, 5th fret.',
      );
    });

    test('a slash bass is the one note of it that is the bass player\'s', () {
      final positions = bassPositionsFor('C/G');
      expect(positions.last.degree, 'bass note');
      expect(positions.last.note, 'G');
      expect((positions.last.string, positions.last.fret), (0, 3));
      expect(
        bassNeckReading('C major over G', positions),
        endsWith('bass note, E string, 3rd fret.'),
      );
    });

    test('a chord with no fifth in it gets the root by itself', () {
      // There is no such quality stored today, and the day one is added this
      // must not invent a G over it.
      for (final label in const <String>['C', 'Cm', 'C7']) {
        final fifths = bassPositionsFor(label)
            .where((position) => position.degree.contains('5th'));
        expect(fifths.length, 1, reason: label);
      }
    });
  });

  testWidgets('every diagram says its shape out loud', (tester) async {
    // A CustomPaint is an empty rectangle to VoiceOver and TalkBack, and the
    // web build reads the same tree. WCAG 2.1 AA SC 1.1.1: a picture that
    // carries meaning carries a text alternative with it.
    final drawn = <(String, Widget, String)>[
      (
        'guitar',
        const FrettedChordDiagram(
          chord: ChordDiagramData(
            name: 'G',
            spokenName: 'G major',
            frets: <int>[3, 2, 0, 0, 0, 3],
          ),
        ),
        'G major. Low E, 3rd fret.',
      ),
      (
        'ukulele',
        FrettedChordDiagram(
          chord: ChordDiagramData(
            name: 'C',
            spokenName: 'C major',
            frets: ukuleleShapesFor('C').first.frets,
            strings: ukuleleStrings,
          ),
        ),
        'C major. G, open.',
      ),
      (
        'left-handed',
        FrettedChordDiagram(
          chord: mirrorForLeftHand(const ChordDiagramData(
            name: 'G',
            spokenName: 'G major',
            frets: <int>[3, 2, 0, 0, 0, 3],
          )),
        ),
        'G major. High E, 3rd fret.',
      ),
      (
        'bass',
        BassNeckDiagram(
          positions: bassPositionsFor('C/G'),
          spokenName: 'C major over G',
        ),
        'C major over G. root, A string, 3rd fret.',
      ),
      (
        'piano',
        PianoKeysDiagram(
          keys: pianoKeysFor('C/G'),
          spokenName: 'C major over G',
        ),
        'C major over G. C, the root.',
      ),
    ];

    for (final (name, widget, said) in drawn) {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: widget),
      ));
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byType(CustomPaint),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.image, isTrue, reason: name);
      expect(semantics.properties.label, startsWith(said), reason: name);
    }
  });

  group('the choice is this device\'s, and one for the whole app', () {
    test('the guitar is stored as nothing, and held the moment it is chosen',
        () async {
      ShapeReadingStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(ShapeReadingStore.held, ShapeReading.guitar);
      expect(await ShapeReadingStore.load(), ShapeReading.guitar);

      await ShapeReadingStore.save(ShapeReading.ukulele);
      expect(ShapeReadingStore.held, ShapeReading.ukulele);
      expect(await ShapeReadingStore.load(), ShapeReading.ukulele);

      await ShapeReadingStore.save(ShapeReading.guitar);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('shape')), isEmpty);
      ShapeReadingStore.resetForTesting();
    });

    test('a kept choice is in hand before any chord is tapped', () async {
      ShapeReadingStore.resetForTesting();
      LeftHandedStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'shape_reading': 'piano',
        'left_handed_shapes': true,
      });
      expect(ShapeReadingStore.held, ShapeReading.guitar);
      await ShapeReadingStore.warm();
      await LeftHandedStore.warm();
      expect(ShapeReadingStore.held, ShapeReading.piano);
      expect(LeftHandedStore.held, isTrue);
      ShapeReadingStore.resetForTesting();
      LeftHandedStore.resetForTesting();
    });

    test('a value this version cannot read is the guitar', () async {
      // Written by a later version, or by a finger in a preferences file.
      ShapeReadingStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'shape_reading': 'mandolin',
      });
      await ShapeReadingStore.warm();
      expect(ShapeReadingStore.held, ShapeReading.guitar);
      ShapeReadingStore.resetForTesting();
    });

    test('choosing one tells the page, which reads the capo off it', () async {
      ShapeReadingStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var told = 0;
      void listener() => told += 1;
      ShapeReadingStore.changes.addListener(listener);
      addTearDown(() => ShapeReadingStore.changes.removeListener(listener));

      await ShapeReadingStore.save(ShapeReading.piano);
      expect(told, 1);
      expect(ShapeReading.piano.takesACapo, isFalse);
      expect(ShapeReading.ukulele.takesACapo, isTrue);
      // Saving the same choice again is not news.
      await ShapeReadingStore.save(ShapeReading.piano);
      expect(told, 1);
      ShapeReadingStore.resetForTesting();
    });
  });

  testWidgets('the instrument sits with the other readings, and the chord '
      'sheet draws it', (tester) async {
    ShapeReadingStore.resetForTesting();
    LeftHandedStore.resetForTesting();
    SimplerShapesStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-shapes'),
            bundle: _analysis('song-shapes'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // The four instruments are chips in the Shapes section, beside the
    // numbers and the horn charts.
    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('read_shapes_guitar')), findsOneWidget);
    expect(find.byKey(const Key('read_shapes_bass')), findsOneWidget);
    // Left-handed is a fretting hand's question, so it is offered beside the
    // two instruments that have a neck and nowhere else.
    expect(find.byKey(const Key('left_handed_shapes')), findsOneWidget);
    // And a capo is one too: this key has capo rows on it until the shapes
    // being read stop being a fretting hand's.
    expect(find.text('WITH A CAPO'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('read_shapes_piano')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read_shapes_piano')));
    await tester.pumpAndSettle();
    expect(await ShapeReadingStore.load(), ShapeReading.piano);
    expect(find.byKey(const Key('left_handed_shapes')), findsNothing);
    expect(find.byKey(const Key('simpler_shapes')), findsNothing);
    expect(find.text('WITH A CAPO'), findsNothing);
    Navigator.of(tester.element(find.byKey(const Key('key_reference_sheet'))))
        .pop();
    await tester.pumpAndSettle();

    // And the chord that opened as six strings now opens as a keyboard.
    await tester.tap(find.byKey(const Key('edit_chord_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('piano_keys_diagram')), findsOneWidget);
    expect(find.byType(FrettedChordDiagram), findsNothing);
    Navigator.of(tester.element(find.byKey(const Key('chord_reference_sheet'))))
        .pop();
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    ShapeReadingStore.resetForTesting();
    LeftHandedStore.resetForTesting();
    SimplerShapesStore.resetForTesting();
  });
}

/// The frets of the first uke shape for a chord, which is the one a class is
/// taught.
List<int> _uke(String label) => ukuleleShapesFor(label).first.frets;

/// What the bass reading marks, as notes.
List<String> _bassNotes(String label) =>
    bassPositionsFor(label).map((position) => position.note).toList();

const List<String> _theTwelve = <String>[
  'C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B',
];

SongProject _project(String id) {
  final now = DateTime(2026, 9, 19);
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
        ChordCue(id: 1, startMs: 5000, endMs: 7000, chord: 'G', confidence: 0.9),
        ChordCue(
            id: 2, startMs: 12500, endMs: 13400, chord: 'D', confidence: 0.9),
      ],
    );
