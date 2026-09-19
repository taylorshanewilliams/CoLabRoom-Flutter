import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A capo that helps.
///
/// Every Musician, Same Song, 17 September 2026. The capo chart on the key
/// sheet answered a question about the key off five major shapes, so it had
/// nothing to say about the Bm in bar 3 or about a song whose key nobody
/// found. This counts the song's own chords and says what a capo would
/// actually leave under the hand — and says nothing at all when no capo
/// would help, which is most songs.
void main() {
  group('the capo the song asks for', () {
    test('a song in B♭ is a song in G with the capo on 3', () {
      final found = capoThatHelps(
        const <String>['Bb', 'Eb', 'F', 'Gm'],
      )!;
      expect(found.fret, 3);
      // Named in the order the song reaches for them, so the line reads the
      // way somebody would say it.
      expect(found.shapes, <String>['G', 'C', 'D', 'Em']);
    });

    test('the horn player\'s keys come back under the hand', () {
      // F, B♭ and C is two barres and one open chord; three frets up it is
      // D, G and A.
      final f = capoThatHelps(const <String>['F', 'Bb', 'C'])!;
      expect(f.fret, 3);
      expect(f.shapes, <String>['D', 'G', 'A']);

      // A blues in B♭ is a blues in A.
      final blues = capoThatHelps(const <String>['Bb7', 'Eb7', 'F7'])!;
      expect(blues.fret, 1);
      expect(blues.shapes, <String>['A7', 'D7', 'E7']);
    });

    test('a minor song takes the lowest fret that does as well', () {
      // C minor sits on G, D and A shapes at the first fret and on Am, C and
      // G at the third: the same three open shapes and the same one barre,
      // so the capo stays as low as it can.
      final found = capoThatHelps(const <String>['Cm', 'Ab', 'Eb', 'Bb'])!;
      expect(found.fret, 1);
      expect(found.shapes, <String>['G', 'D', 'A']);
    });

    test('a seventh with an open shape counts as one', () {
      final found = capoThatHelps(const <String>['Eb', 'Abmaj7', 'Bb7'])!;
      expect(found.fret, 1);
      expect(found.shapes, <String>['D', 'Gmaj7', 'A7']);
    });

    test('the F that stops everybody can be capoed away', () {
      // Am F C G is one barre in four. Five frets up it is Em C G D, which
      // is the move a guitarist makes for somebody who cannot barre yet.
      final found = capoThatHelps(const <String>['Am', 'F', 'C', 'G'])!;
      expect(found.fret, 5);
      expect(found.shapes, <String>['Em', 'C', 'G', 'D']);
    });

    test('it never sends anybody past the seventh fret', () {
      for (final song in const <List<String>>[
        <String>['C#', 'F#', 'G#'],
        <String>['Ebm', 'Ab', 'Db'],
        <String>['B', 'E', 'F#m'],
      ]) {
        final found = capoThatHelps(song);
        if (found == null) continue;
        expect(found.fret, inInclusiveRange(1, 7));
        expect(found.shapes.length, greaterThanOrEqualTo(2));
      }
    });
  });

  group('when there is nothing to say, nothing is said', () {
    test('a song of barre chords with no helpful capo offers nothing', () {
      // A half-diminished, a thirteenth and a ninth have no open shape at
      // any fret, so moving the capo moves nothing.
      expect(capoThatHelps(const <String>['Bm7b5', 'E13', 'A9']), isNull);
      expect(capoThatHelps(const <String>['C°', 'F#°', 'A+']), isNull);
    });

    test('a song that already sits open is left alone', () {
      expect(capoThatHelps(const <String>['G', 'C', 'D']), isNull);
      expect(capoThatHelps(const <String>['C', 'Am', 'Em', 'G']), isNull);
      // Even with a barre in it: every fret that keeps three open shapes
      // swaps the Bm for a different barre and gains nothing, so no capo
      // beats no capo.
      expect(capoThatHelps(const <String>['G', 'C', 'D', 'Bm']), isNull);
    });

    test('one chord is not a song, and nor is nothing', () {
      expect(capoThatHelps(const <String>['Bb']), isNull);
      expect(capoThatHelps(const <String>['Bb', 'Bb', 'Bb']), isNull);
      expect(capoThatHelps(const <String>[]), isNull);
      // Chords this cannot read are passed over rather than counted.
      expect(capoThatHelps(const <String>['N', 'X', 'Bb']), isNull);
    });

    test('both spellings of a chord reach the same answer', () {
      final harte = capoThatHelps(const <String>['Bb:maj', 'Eb:maj', 'F:maj']);
      final written = capoThatHelps(const <String>['Bb', 'Eb', 'F']);
      expect(harte!.fret, written!.fret);
      expect(harte.shapes, written.shapes);
    });
  });

  testWidgets('the offer is one line in the capo picker, and a tap away',
      (tester) async {
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
            project: _project('song-capo-helps'),
            bundle: _analysis('song-capo-helps'),
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

    // One line, in the song's own chords, standing where the chart's row for
    // that fret used to be rather than beside it.
    expect(find.text('Capo 3'), findsOneWidget);
    expect(find.text('makes these open shapes: G, C, D, Em'), findsOneWidget);
    expect(find.text('play the G shapes'), findsNothing);

    // Nothing has been set: the offer is a tap away and never taken for
    // anybody.
    expect(find.textContaining('capo 3'), findsNothing);
    await tester.tap(find.text('makes these open shapes: G, C, D, Em'));
    await tester.pumpAndSettle();
    expect(find.text('capo 3 · sounds in Bb'), findsOneWidget);

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

/// A song in B♭ whose chords are the ones a capo on 3 turns into G, C, D and
/// Em — and whose Gm is exactly the chord the old key-only chart could not
/// see.
SongAnalysisBundle _analysis(String id) => SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 20000,
        musicalKey: 'Bb',
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
        ChordCue(id: 1, startMs: 5000, endMs: 6000, chord: 'Bb',
            confidence: 0.9),
        ChordCue(id: 2, startMs: 6000, endMs: 7000, chord: 'Eb',
            confidence: 0.9),
        ChordCue(id: 3, startMs: 7000, endMs: 12500, chord: 'F',
            confidence: 0.9),
        ChordCue(id: 4, startMs: 12500, endMs: 13400, chord: 'G:min',
            confidence: 0.9),
      ],
    );
