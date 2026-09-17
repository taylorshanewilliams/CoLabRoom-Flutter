import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/features/workspace/song_transpose_store.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Perform keeps your key, and slash chords keep their bass.
///
/// From the audit of 17 September 2026. Perform drew every chord with a
/// transpose of zero, so a song moved down to fit somebody's voice went on
/// stage in its original key. The transpose itself was forgotten the moment
/// you left the song. And transposing moved only the root of a slash chord:
/// "G/B" up two read "A/B", with the wrong note under it.
void main() {
  group('slash chords keep their bass', () {
    test('the bass moves with the root', () {
      expect(transposeChord('G/B', 2), 'A/C#');
      expect(chordAsPlayed('G/B', transpose: 2, key: 'G'), 'A/C#');
      expect(transposeChord('Am7/G', 2), 'Bm7/A');
      expect(transposeChord('Bb/D', 2), 'C/E');
    });

    test('down two from D is C, and the bass lands on E', () {
      expect(chordAsPlayed('D/F#', transpose: -2, key: 'D'), 'C/E');
      expect(keyAsPlayed('D', -2), 'C');
    });

    test('a flat key spells root and bass with flats', () {
      // D up one is E-flat major: D/A becomes Eb/Bb, not D#/A#.
      expect(chordAsPlayed('D/A', transpose: 1, key: 'D major'), 'Eb/Bb');
      expect(keyAsPlayed('D major', 1), 'Eb major');
      expect(chordAsPlayed('G/D', transpose: 3, key: 'G'), 'Bb/F');
      // The same chord in a sharp key stays sharp.
      expect(chordAsPlayed('G/D', transpose: 4, key: 'G'), 'B/F#');
    });

    test('a Harte degree in the bass is not moved as if it were a note', () {
      // G:maj/3 is G over its own third. Moving the root has already moved
      // the third; the degree stays a degree.
      expect(transposeChord('G:maj/3', 2), 'A:maj/3');
      expect(transposeChord('A:min7/b7', -2), 'G:min7/b7');
      expect(chordAsPlayed('G:maj/3', transpose: 2, key: 'G'), 'A/C#');
      expect(chordAsPlayed('G:maj/3', transpose: 3, key: 'G'), 'Bb/D');
      // A source that writes the bass out as a note has it moved.
      expect(transposeChord('G:maj/B', 2), 'A:maj/C#');
    });

    test('a slash that is not a bass, and chords that do not move', () {
      expect(transposeChord('C6/9', 2), 'D6/9');
      expect(transposeChord('N', 3), 'N');
      expect(transposeChord('G/B', 0), 'G/B');
      expect(transposeChord('G/B', 12), 'G/B');
      expect(transposeChord('G/B', -12), 'G/B');
    });
  });

  group('the key is yours', () {
    test('it is kept per song, and zero is kept as nothing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SongTransposeStore.save('song-a', -3);
      expect(await SongTransposeStore.load('song-a'), -3);
      expect(await SongTransposeStore.load('song-b'), 0);

      await SongTransposeStore.save('song-a', 40);
      expect(await SongTransposeStore.load('song-a'), SongTransposeStore.limit);

      await SongTransposeStore.save('song-a', 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((key) => key.contains('song-a')), isEmpty);
    });

    test('Follow me does not carry it', () {
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
              (name) => name.contains('transpose') || name.contains('key'),
            ),
        isEmpty,
      );
    });
  });

  testWidgets('Perform opens a transposed song in the key it was left in',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_transpose_song-key': 3,
    });
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: LivePerformanceScreen(
          project: _project('song-key'),
          analysis: _analysis('song-key'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    // G up three is B-flat, and the chords are written in it.
    expect(find.byKey(const Key('live_key')), findsOneWidget);
    expect(find.text('Key of Bb'), findsOneWidget);
    expect(find.text('Bb/D'), findsOneWidget);
    expect(find.text('F/A'), findsOneWidget);
    expect(find.text('G/B'), findsNothing);
    expect(find.text('Key of G'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a song nobody transposed opens in its own key', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_transpose_some-other-song': 5,
    });
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: LivePerformanceScreen(
          project: _project('song-key'),
          analysis: _analysis('song-key'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Key of G'), findsOneWidget);
    expect(find.text('G/B'), findsOneWidget);
    expect(find.text('D/F#'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a chord tapped on a transposed chart is placed in the key read',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    ChartBar bar(int number, String chord) => ChartBar(
          number: number,
          startMs: (number - 1) * 2000,
          endMs: number * 2000,
          beatsInBar: 4,
          chords: <ChartChord>[ChartChord(chord: chord, beat: 1, startMs: 0)],
        );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChordChartView(
              rows: <ChartRow>[
                ChartRow(
                  sectionLabel: 'Verse',
                  bars: <ChartBar>[
                    bar(1, 'G:maj'),
                    bar(2, 'C:maj'),
                    bar(3, 'D:maj/3'),
                    bar(4, 'G:maj'),
                  ],
                ),
              ],
              transpose: 2,
              fontScale: 1,
              musicalKey: 'G',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('D'), findsOneWidget);
    expect(find.text('E/G#'), findsOneWidget);
    expect(find.text('A'), findsNWidgets(2));

    // In G up two, the A on the chart is the I -- not the II of G, which is
    // what it was called when the key was asked about untransposed.
    await tester.tap(find.text('A').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chord_reference_sheet')), findsOneWidget);
    expect(find.textContaining('the I here'), findsOneWidget);
  });

  testWidgets('the transpose survives leaving the song and coming back',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget panel(String id) => MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SongSheetPanel(
                key: ValueKey<String>(id),
                project: _project(id),
                bundle: _analysis(id),
                onReviewLyrics: null,
                onOpenLive: null,
              ),
            ),
          ),
        );

    await tester.pumpWidget(panel('song-key'));
    await tester.pump();
    expect(find.text('Original key'), findsOneWidget);
    expect(find.text('G/B'), findsOneWidget);

    await tester.tap(find.byTooltip('Transpose up'));
    await tester.pump();
    await tester.tap(find.byTooltip('Transpose up'));
    await tester.pump();
    expect(find.text('+2 semitones'), findsOneWidget);
    expect(find.text('A/C#'), findsOneWidget);

    // Correcting chords reads them in the song's own key, and Done gives
    // your key back rather than throwing it away.
    await tester.tap(find.byKey(const Key('toggle_chord_editing')));
    await tester.pump();
    expect(find.text('Original key'), findsOneWidget);
    expect(find.text('G/B'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle_chord_editing')));
    await tester.pump();
    expect(find.text('+2 semitones'), findsOneWidget);

    // Leave the song, and come back to it.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(panel('song-key'));
    await tester.pump();
    await tester.pump();
    expect(find.text('+2 semitones'), findsOneWidget);
    expect(find.text('A/C#'), findsOneWidget);
    expect(find.text('A'), findsOneWidget, reason: 'the key badge');

    // Another song is not moved by this one.
    await tester.pumpWidget(panel('song-other'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Original key'), findsOneWidget);
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
        // Harte, as the analysis writes it: G over its third.
        ChordCue(id: 1, startMs: 5000, endMs: 7000, chord: 'G:maj/3', confidence: 0.9),
        // Typed by hand, with the bass as a note.
        ChordCue(id: 2, startMs: 12500, endMs: 13400, chord: 'D/F#', confidence: 0.9, source: 'manual'),
      ],
    );
