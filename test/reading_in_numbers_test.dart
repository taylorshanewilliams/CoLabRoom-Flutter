import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:colabroom/services/number_reading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set a capo, and read the song in numbers.
///
/// Every Musician, Same Song, 17 September 2026. A Nashville bassist reads
/// 1 4 5, not G C D, and the whole value of that is that it survives the
/// singer changing key: the band drops the song a tone and the chart does not
/// change a mark. A capo is the guitarist's version of the same idea from the
/// other end -- the shapes move, the song does not, and the badge has to say
/// both or the band is a tone apart.
///
/// Both are readings: personal, kept on the device, never carried by Follow
/// me. Where the 1 is is the one thing here that is not.
void main() {
  group('the number a chord is', () {
    test('a major key counts its chords from the 1', () {
      expect(chordAsDegree('G', 'G major'), '1');
      expect(chordAsDegree('C', 'G major'), '4');
      expect(chordAsDegree('D', 'G major'), '5');
      expect(chordAsDegree('Am', 'G major'), '2-');
      expect(chordAsDegree('Em', 'G major'), '6-');
      // A Mixolydian song's flat seventh, which is the chord that sends
      // people looking for numbers in the first place.
      expect(chordAsDegree('F', 'G major'), '♭7');
    });

    test('a slash chord names its bass as a number too', () {
      // The V with the leading tone under it, written the way a chart writes
      // it: the bass is a note of the key, not a chord of its own.
      expect(chordAsDegree('D/F#', 'G major'), '5/7');
      expect(chordAsDegree('C/G', 'G major'), '4/1');
    });

    test('Roman numerals say the quality in the case', () {
      expect(chordAsDegree('G', 'G major', roman: true), 'I');
      expect(chordAsDegree('Am', 'G major', roman: true), 'ii');
      expect(chordAsDegree('D', 'G major', roman: true), 'V');
      expect(chordAsDegree('Em', 'G major', roman: true), 'vi');
      // ii, not ii- : the case has already said it is minor.
      expect(chordAsDegree('Am7', 'G major', roman: true), 'ii7');
      expect(chordAsDegree('F#dim', 'G major', roman: true), 'vii°');
      expect(chordAsDegree('F', 'G major', roman: true), '♭VII');
    });

    test('sevenths and suspensions keep their own spelling', () {
      expect(chordAsDegree('D7', 'G major'), '57');
      expect(chordAsDegree('Am7', 'G major'), '2-7');
      expect(chordAsDegree('Cmaj7', 'G major'), '4maj7');
      expect(chordAsDegree('Dsus4', 'G major'), '5sus4');
    });

    test('a minor song counts from its relative major by default', () {
      // The convention the written system describes: A minor is counted
      // against C, so the home chord is the 6. See MinorNumbers.
      expect(chordAsDegree('Am', 'A minor'), '6-');
      expect(chordAsDegree('F', 'A minor'), '4');
      expect(chordAsDegree('C', 'A minor'), '1');
      expect(chordAsDegree('G', 'A minor'), '5');
      expect(chordAsDegree('Am', 'A minor', roman: true), 'vi');
      expect(chordAsDegree('F', 'A minor', roman: true), 'IV');
    });

    test('or from the minor tonic, for anybody who reads it that way', () {
      expect(chordAsDegree('Am', 'A minor', fromMinorTonic: true), '1-');
      expect(chordAsDegree('F', 'A minor', fromMinorTonic: true), '♭6');
      expect(chordAsDegree('C', 'A minor', fromMinorTonic: true), '♭3');
      expect(chordAsDegree('G', 'A minor', fromMinorTonic: true), '♭7');
      expect(
        chordAsDegree('Am', 'A minor', roman: true, fromMinorTonic: true),
        'i',
      );
      expect(
        chordAsDegree('G', 'A minor', roman: true, fromMinorTonic: true),
        '♭VII',
      );
    });

    test('nothing it can place comes back as nothing, not as a guess', () {
      expect(chordAsDegree('N', 'G major'), isNull);
      expect(chordAsDegree('', 'G major'), isNull);
      expect(chordAsDegree('G', 'not a key'), isNull);
    });
  });

  group('numbers do not move when the song does', () {
    const numbers = NumberReading(style: NumberStyle.nashville);

    test('the same chart at every transpose', () {
      for (final transpose in <int>[-5, 0, 2, 7]) {
        expect(
          chordAsRead('G:maj', transpose: transpose, key: 'G', numbers: numbers),
          '1',
          reason: 'the 1 stopped being the 1 at $transpose',
        );
        expect(
          chordAsRead('C:maj', transpose: transpose, key: 'G', numbers: numbers),
          '4',
        );
      }
    });

    test('Harte from the analysis reads like a chord on paper', () {
      // chordDisplay resolves the degree bass first, so G over its third is
      // the 1 with the 3 under it.
      expect(
        chordAsRead('G:maj/3', transpose: 0, key: 'G', numbers: numbers),
        '1/3',
      );
      expect(
        chordAsRead('A:min7', transpose: 0, key: 'G', numbers: numbers),
        '2-7',
      );
    });

    test('with no key to count from, letters', () {
      expect(chordAsRead('G:maj', transpose: 2, key: null, numbers: numbers),
          'A');
      expect(chordAsRead('G:maj', transpose: 2, key: '  ', numbers: numbers),
          'A');
    });

    test('letters is still letters', () {
      expect(chordAsRead('G:maj', transpose: 2, key: 'G'), 'A');
    });
  });

  group('a capo', () {
    test('names the shapes and the key it still sounds in', () {
      expect(
        capoLine('B', capo: 4, transpose: 0),
        'Capo 4 · G shapes · sounds in B',
      );
      // A minor song keeps its word, because the shapes are minor shapes.
      expect(
        capoLine('G minor', capo: 3, transpose: 0),
        'Capo 3 · E minor shapes · sounds in G minor',
      );
      // Somebody who has also moved the song reads both from where they
      // actually are.
      expect(
        capoLine('B', capo: 4, transpose: -2),
        'Capo 4 · F shapes · sounds in A',
      );
    });

    test('with no capo on, it is just the key', () {
      expect(capoLine('B', capo: 0, transpose: 0), 'B');
    });

    test('the chords come down by the fret the capo is on', () {
      // A song in B with a capo on 4 is played with G, C and D shapes.
      expect(chordAsPlayed('B:maj', transpose: -4, key: 'B'), 'G');
      expect(chordAsPlayed('E:maj', transpose: -4, key: 'B'), 'C');
      expect(chordAsPlayed('F#:maj', transpose: -4, key: 'B'), 'D');
    });
  });

  testWidgets('tapping a capo row moves the shapes and not the song',
      (tester) async {
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
            bundle: _analysis('song-capo', musicalKey: 'B'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // The key badge and the song's own 1, both reading B.
    expect(find.text('B'), findsNWidgets(2));
    expect(find.text('E'), findsOneWidget);

    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('set_capo_4')));
    await tester.pumpAndSettle();
    expect(await SongCapoStore.load('song-capo'), 4);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // G shapes under the hand, and the badge still saying what the band
    // hears -- both, because a capo changes only one of them.
    expect(find.text('G'), findsNWidgets(2));
    expect(find.text('C'), findsOneWidget);
    expect(find.text('capo 4 · sounds in B'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the sheet reads in numbers, and stays there when it moves',
      (tester) async {
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
            project: _project('song-numbers'),
            bundle: _analysis('song-numbers'),
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
    await tester.tap(find.byKey(const Key('read_numbers_nashville')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(await SongNumbersStore.load('song-numbers'), NumberStyle.nashville);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    // Up three: the chart does not change a mark, which is the whole reason
    // those players read it.
    await tester.tap(find.byTooltip('Transpose up'));
    await tester.pump();
    await tester.tap(find.byTooltip('Transpose up'));
    await tester.pump();
    await tester.tap(find.byTooltip('Transpose up'));
    await tester.pump();
    expect(find.text('+3 semitones'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Perform opens with the capo left on the sheet',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_capo_song-stage': 4,
    });
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: LivePerformanceScreen(
        project: _project('song-stage'),
        analysis: _analysis('song-stage', musicalKey: 'B'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The shapes under the hand, and the key the band is in beside them.
    expect(find.text('Capo 4 · G shapes · sounds in B'), findsOneWidget);
    expect(find.text('G'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Perform reads numbers from the key the band said',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'song_numbers_song-roman': 'roman',
    });
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: LivePerformanceScreen(
        // Heard in G, said to be in C: the G is the V and the C the I.
        project: _project('song-roman', keyOverride: 'C major'),
        analysis: _analysis('song-roman'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    expect(find.text('V'), findsOneWidget);
    expect(find.text('I'), findsOneWidget);
    expect(find.text('Key of C major'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

SongProject _project(String id, {String? keyOverride}) {
  final now = DateTime(2026, 9, 17);
  return SongProject(
    id: id,
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: now,
    updatedAt: now,
    keyOverride: keyOverride,
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

/// A song with its 1 and its 4 over two words, in whatever key the test wants
/// the analysis to have heard.
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
      chordCues: <ChordCue>[
        // The 1 and the 4 of whatever key the reference claims.
        ChordCue(
          id: 1,
          startMs: 5000,
          endMs: 7000,
          chord: musicalKey == 'B' ? 'B:maj' : 'G:maj',
          confidence: 0.9,
        ),
        ChordCue(
          id: 2,
          startMs: 12500,
          endMs: 13400,
          chord: musicalKey == 'B' ? 'E:maj' : 'C:maj',
          confidence: 0.9,
        ),
      ],
    );
