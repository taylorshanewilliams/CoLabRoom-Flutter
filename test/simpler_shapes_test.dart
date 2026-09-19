import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simpler shapes: changes the sound.
///
/// Every Musician, Same Song, 17 September 2026. A beginner stops at the
/// first chord they cannot make, and a Cmaj7 in bar 2 ends the song for the
/// evening. The plain chord inside it is one they can already play and every
/// note of it is a note of the chord written — so the offer is honest, and
/// the line beside it says the one true thing about taking it: it changes
/// the sound. Never "easier", never "beginner".
void main() {
  group('the plain chord inside an extended one', () {
    test('a dozen extended chords keep their root and their quality', () {
      // Everything stacked above the fifth comes off. The root never moves
      // and a major stays major, a minor minor, a diminished diminished.
      expect(simplerChord('Cmaj7'), 'C');
      expect(simplerChord('C7'), 'C');
      expect(simplerChord('C9'), 'C');
      expect(simplerChord('C11'), 'C');
      expect(simplerChord('C13'), 'C');
      expect(simplerChord('C6'), 'C');
      expect(simplerChord('Cadd9'), 'C');
      expect(simplerChord('Cmaj9'), 'C');
      expect(simplerChord('Am7'), 'Am');
      expect(simplerChord('Am9'), 'Am');
      expect(simplerChord('Am6'), 'Am');
      expect(simplerChord('Bbmaj7'), 'Bb');
      // A half-diminished is still diminished when the seventh comes off:
      // the flat fifth is what makes it the chord it is, so it stays.
      expect(simplerChord('F#m7b5'), 'F#°');
      expect(simplerChord('Bdim7'), 'B°');
      // A suspension is not a third, so taking the seventh off a 7sus4
      // leaves a sus4 rather than a major chord.
      expect(simplerChord('G7sus4'), 'Gsus4');
    });

    test('a chord that is already three notes has nothing to take off', () {
      expect(simplerChord('C'), isNull);
      expect(simplerChord('Am'), isNull);
      expect(simplerChord('Dsus4'), isNull);
      expect(simplerChord('Asus2'), isNull);
      expect(simplerChord('C°'), isNull);
      expect(simplerChord('C+'), isNull);
      // Nor has something this cannot read at all.
      expect(simplerChord('N'), isNull);
      expect(simplerChord('Hmaj7'), isNull);
    });

    test('both spellings of a chord reach the same plain one', () {
      // ChordMini writes Harte, a person writes it the way it goes on paper.
      expect(simplerChord('A:min7'), 'Am');
      expect(simplerChord('C:maj7'), 'C');
    });

    test('a slash bass does not come with it', () {
      // The bass is the bass player's note, not the guitar's, and no shape
      // here has ever been drawn from one.
      expect(simplerChord('Cmaj7/G'), 'C');
      expect(simplerChord('C/G'), isNull);
    });
  });

  group('the shape that gets drawn instead', () {
    test('the triad, when there is one to draw', () {
      final c = simplerShapeFor('Cmaj7')!;
      expect(c.display, 'C');
      expect(c.shapes, isNotEmpty);
      expect(c.shapes.first.name, 'C');
      final am = simplerShapeFor('Am9')!;
      expect(am.display, 'Am');
      expect(am.shapes, isNotEmpty);
    });

    test('the fifth, when the triad is one nobody has a shape for', () {
      // Gsus4 is not an open shape and there is no movable sus shape, so
      // what is left is the two notes of the fifth — both of them notes of
      // the chord written.
      final g = simplerShapeFor('G7sus4')!;
      expect(g.display, 'G5');
      expect(g.shapes, isNotEmpty);
      expect(g.shapes.first.hint, contains('Root and fifth'));
      expect(g.shapes.first.hint, isNot(contains('Barre')));
      // And it really is only the root and the fifth.
      expect(g.tones.map((tone) => tone.note), <String>['G', 'D']);
    });

    test('nothing at all, rather than a note the chord does not contain', () {
      // A half-diminished has no plain fifth in it, so a power chord over
      // one would put a note in the room the chord does not have. There is
      // no diminished shape stored either, so this offers nothing.
      expect(simplerShapeFor('F#m7b5'), isNull);
      expect(simplerShapeFor('Cdim7'), isNull);
      // And a chord that is already plain is left alone.
      expect(simplerShapeFor('C'), isNull);
      expect(simplerShapeFor('Em'), isNull);
    });

    test('the fifths at the nut are drawn at the nut', () {
      // E5 seven frets up is the one place somebody offered a simpler shape
      // should never be sent.
      expect(chordReference('E5')!.shapes.first.baseFret, 1);
      expect(chordReference('E5')!.shapes.first.hint, 'Open position');
      expect(chordReference('A5')!.shapes.first.hint, 'Open position');
    });
  });

  group('the choice is this device\'s, and one for the whole app', () {
    test('off is stored as nothing, and held the moment it is chosen',
        () async {
      SimplerShapesStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(SimplerShapesStore.held, isFalse);
      expect(await SimplerShapesStore.load(), isFalse);

      await SimplerShapesStore.save(true);
      expect(SimplerShapesStore.held, isTrue);
      expect(await SimplerShapesStore.load(), isTrue);

      await SimplerShapesStore.save(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('simpler')), isEmpty);
      SimplerShapesStore.resetForTesting();
    });

    test('a kept choice is in hand before any chord is tapped', () async {
      SimplerShapesStore.resetForTesting();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simpler_shapes': true,
      });
      expect(SimplerShapesStore.held, isFalse);
      await SimplerShapesStore.warm();
      expect(SimplerShapesStore.held, isTrue);
      SimplerShapesStore.resetForTesting();
    });
  });

  testWidgets('the toggle is beside the other readings, and the chord sheet '
      'takes it', (tester) async {
    SimplerShapesStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-simpler'),
            bundle: _analysis('song-simpler'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // The chord as written opens the shapes of the chord as written.
    await tester.tap(find.byKey(const Key('edit_chord_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chord_reference_sheet')), findsOneWidget);
    expect(find.byKey(const Key('simpler_shape_said')), findsNothing);
    Navigator.of(tester.element(find.byKey(const Key('chord_reference_sheet'))))
        .pop();
    await tester.pumpAndSettle();

    // The toggle sits with the other readings, on the key badge.
    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    expect(find.text('SHAPES'), findsOneWidget);
    await tester.tap(find.byKey(const Key('simpler_shapes')));
    await tester.pumpAndSettle();
    expect(await SimplerShapesStore.load(), isTrue);
    Navigator.of(tester.element(find.byKey(const Key('key_reference_sheet'))))
        .pop();
    await tester.pumpAndSettle();

    // Now the same chord draws the plain one inside it, and says what that
    // costs in the app's own words.
    await tester.tap(find.byKey(const Key('edit_chord_1')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.descendant(
            of: find.byKey(const Key('simpler_shape_said')),
            matching: find.byType(Text),
          ))
          .data,
      'G in place of Gmaj7 — changes the sound.',
    );
    // The chord itself is still the chord: the sheet is still headed Gmaj7
    // and the notes in it do not change because a hand cannot reach them
    // all yet.
    expect(
      find.descendant(
        of: find.byKey(const Key('chord_reference_sheet')),
        matching: find.text('Gmaj7'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('chord_reference_sheet')),
        matching: find.text('7th'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SimplerShapesStore.resetForTesting();
  });

  testWidgets('a song with no key can still be read with simpler shapes',
      (tester) async {
    // Key detection falls back on plenty of recordings, and the chart has no
    // key badge at all. A chord has a shape either way, so the plain Read as
    // sheet carries the same chip.
    SimplerShapesStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

    await tester.tap(find.byKey(const Key('song_sheet_read_as')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reading_choice_sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('simpler_shapes')));
    await tester.pumpAndSettle();
    expect(await SimplerShapesStore.load(), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SimplerShapesStore.resetForTesting();
  });
}

SongProject _project(String id) {
  final now = DateTime(2026, 9, 18);
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
        ChordCue(id: 1, startMs: 5000, endMs: 7000, chord: 'G:maj7',
            confidence: 0.9),
        ChordCue(id: 2, startMs: 12500, endMs: 13400, chord: 'D',
            confidence: 0.9),
      ],
    );
