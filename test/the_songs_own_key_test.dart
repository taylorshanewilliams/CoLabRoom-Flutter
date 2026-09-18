import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// This is the 1.
///
/// Every Musician, Same Song, 17 September 2026. Key detection knows major
/// and minor only, so a Mixolydian song or one that opens on its IV gets
/// named by the wrong chord — and the scale, the chords, the capo chart and
/// the numbers are all counted from it. The band can say where the 1 really
/// is, and everybody in the room reads from their answer.
///
/// It is the one thing on the key badge that is not a reading: a person's
/// transpose and capo are theirs, and this changes what everybody's numbers
/// mean. So it goes through an RPC (0144) that only the room's owner and
/// editors may call, and a refusal comes back as a sentence.
void main() {
  group('which key the song is in', () {
    test('what the band said stands in front of what was heard', () {
      expect(_project('s', keyOverride: 'G major').songKey('C major'),
          'G major');
      expect(_project('s').songKey('C major'), 'C major');
      expect(_project('s').songKey(null), isNull);
      // A blank is not an answer, whichever side it is on.
      expect(_project('s', keyOverride: '   ').songKey('C major'), 'C major');
      expect(_project('s', keyOverride: 'G').songKey('   '), 'G');
      expect(_project('s').songKey('   '), isNull);
    });

    test('the detected key can be asked for again', () {
      final said = _project('s').copyWith(keyOverride: 'G major');
      expect(said.keyOverride, 'G major');
      expect(said.copyWith(keyOverride: null).keyOverride, isNull);
      // Without the argument it is left where it was, which is what every
      // other copyWith on this song does.
      expect(said.copyWith(title: 'Other').keyOverride, 'G major');
    });
  });

  test('the repository keeps the answer, and lets it be taken back', () async {
    final repository = InMemoryMusicRepository.seeded();
    final rooms = await repository.loadRooms();
    final song = rooms.first.projects.first;

    await repository.setSongKey(song.id, 'A minor');
    expect((await repository.loadProject(song.id))?.keyOverride, 'A minor');

    await repository.setSongKey(song.id, null);
    expect((await repository.loadProject(song.id))?.keyOverride, isNull);

    // A blank clears it too, the way 0144's nullif(btrim(...)) does, so the
    // app cannot leave an empty box standing in for a key.
    await repository.setSongKey(song.id, 'A minor');
    await repository.setSongKey(song.id, '  ');
    expect((await repository.loadProject(song.id))?.keyOverride, isNull);
  });

  testWidgets('the sheet counts from the key the band said', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // Reading in numbers, which is where a wrong 1 does the most damage.
      'song_numbers_song-one': 'numbers',
    });
    tester.view.physicalSize = const Size(520, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            // The analysis heard C. The band says the song is in G, which is
            // what a Mixolydian song does to Krumhansl-Schmuckler.
            project: _project('song-one', keyOverride: 'G major'),
            bundle: _analysis('song-one'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // G is the 1 and F is its flat 7, which is the chart the band actually
    // plays. Counted from C they would have read 5 and 4.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('♭7'), findsOneWidget);
    expect(find.text('G major'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('saying where the 1 is, and asking for the detected key back',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var project = _project('song-said');
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: SongSheetPanel(
              project: project,
              bundle: _analysis('song-said'),
              onReviewLyrics: null,
              onOpenLive: null,
              onSetKey: (key) async {
                setState(() => project = project.copyWith(keyOverride: key));
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('C'), findsOneWidget);

    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    // Nothing to take back yet, so nothing offers to.
    expect(find.byKey(const Key('use_the_detected_key')), findsNothing);

    await tester.tap(find.byKey(const Key('the_one_is_G')));
    await tester.pumpAndSettle();
    expect(project.keyOverride, 'G major');
    // The sheet redraws from the key it was just told, so its scale and its
    // chords are the ones the band meant.
    final sheet = find.byKey(const Key('key_reference_sheet'));
    expect(
      find.descendant(of: sheet, matching: find.text('G major')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('the_one_is_minor')));
    await tester.pumpAndSettle();
    expect(project.keyOverride, 'G minor');

    await tester.tap(find.byKey(const Key('use_the_detected_key')));
    await tester.pumpAndSettle();
    expect(project.keyOverride, isNull);
    // Closed, and the page behind back on what the recording was heard in.
    expect(sheet, findsNothing);
    expect(find.text('C'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('somebody who cannot edit is told, not ignored', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-refused'),
            bundle: _analysis('song-refused'),
            onReviewLyrics: null,
            onOpenLive: null,
            // What 0144 raises for somebody who can only look, arriving the
            // way PostgREST delivers it. The song page does not offer the
            // choice to a viewer at all, so on a phone this is somebody whose
            // role was changed after their rooms were loaded.
            onSetKey: (key) async => throw const PostgrestException(
              message: 'Only somebody who can edit this song can say its key.',
              code: '42501',
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('song_sheet_key_badge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('the_one_is_G')));
    await tester.pumpAndSettle();

    // A sentence somebody can read, not a Postgres error code and not
    // silence -- and said on the sheet they tapped, not in a snackbar on the
    // page underneath it, where it would be hidden behind this very sheet.
    final sheet = find.byKey(const Key('key_reference_sheet'));
    expect(
      find.descendant(
        of: sheet,
        matching: find.text("You don't have access to do that."),
      ),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    // And the sheet is back on the key the room actually has. Left in G it
    // would send somebody away believing the band is in a key nobody saved.
    expect(
      find.descendant(of: sheet, matching: find.text('C major')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('G major')),
      findsNothing,
    );
    expect(find.byKey(const Key('use_the_detected_key')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a sheet that cannot say the key does not offer to',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            // What the song page hands somebody the room only lets look: no
            // way to write, so the key sheet stays a reference.
            project: _project('song-looking'),
            bundle: _analysis('song-looking'),
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
    expect(find.byKey(const Key('key_reference_sheet')), findsOneWidget);
    expect(find.text('Where the 1 is'), findsNothing);
    expect(find.byKey(const Key('the_one_is_G')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('only the owner and the editors can say what key a song is in', () {
    final now = DateTime(2026, 9, 17);
    RoomMember member(String id, RoomRole role) => RoomMember(
          userId: id,
          displayName: id,
          role: role,
          colorValue: 0xFFFF8A4C,
        );
    final room = MusicRoom(
      id: 'room',
      accountId: 'account',
      name: 'The Modal Room',
      icon: 'guitar',
      createdAt: now,
      updatedAt: now,
      members: <RoomMember>[
        member('writer', RoomRole.owner),
        member('bassist', RoomRole.editor),
        member('critic', RoomRole.commenter),
        member('listener', RoomRole.viewer),
      ],
    );
    // The same two set_song_key lets through (0144), so the app never offers
    // a choice the room would refuse.
    expect(room.canEditSongs('writer'), isTrue);
    expect(room.canEditSongs('bassist'), isTrue);
    expect(room.canEditSongs('critic'), isFalse);
    expect(room.canEditSongs('listener'), isFalse);
    // Nobody from here, and nobody signed in at all.
    expect(room.canEditSongs('stranger'), isFalse);
    expect(room.canEditSongs(''), isFalse);
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

/// A song the analysis heard in C, over a G and an F — which is either 5 and
/// 4 of C, or 1 and ♭7 of G, and only the band knows which.
SongAnalysisBundle _analysis(String id) => SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 20000,
        musicalKey: 'C',
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
          id: 1,
          startMs: 5000,
          endMs: 7000,
          chord: 'G:maj',
          confidence: 0.9,
        ),
        ChordCue(
          id: 2,
          startMs: 12500,
          endMs: 13400,
          chord: 'F:maj',
          confidence: 0.9,
        ),
      ],
    );
