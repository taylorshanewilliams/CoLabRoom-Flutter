import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/musician_song_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transposeChord preserves chord quality', () {
    expect(transposeChord('Bbmaj7', 2), 'Cmaj7');
    expect(transposeChord('F#m', -2), 'Em');
    expect(transposeChord('N.C.', 4), 'N.C.');
  });

  test('chords are placed over different lyric words by time', () {
    final placements = chordPlacementsForLine(
      wordCount: 8,
      lineStartMs: 1000,
      lineEndMs: 5000,
      chords: const <ChordCue>[
        ChordCue(
          startMs: 1000,
          endMs: 2500,
          chord: 'G',
          confidence: 0.8,
        ),
        ChordCue(
          startMs: 3000,
          endMs: 5000,
          chord: 'C',
          confidence: 0.8,
        ),
      ],
    );

    expect(placements[0]?.chord, 'G');
    expect(placements[4]?.chord, 'C');
    expect(
      chordStartForWordIndex(
        wordIndex: 4,
        wordCount: 8,
        lineStartMs: 1000,
        lineEndMs: 5000,
      ),
      3000,
    );
  });

  test('stale lyric cue IDs fall back to current document order', () {
    final now = DateTime(2026, 8, 16);
    final project = SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'account-1',
      title: 'Current Lyrics',
      createdAt: now,
      updatedAt: now,
      contributions: <Contribution>[
        _line(now, id: 'current-1', body: 'First current line', position: 1),
        _line(now, id: 'current-2', body: 'Second current line', position: 2),
        _line(now, id: 'current-3', body: 'Third current line', position: 3),
      ],
    );
    const bundle = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-1',
        fileId: 'file-1',
        storagePath: 'room/song/reference.wav',
        displayName: 'reference.wav',
        state: SongAnalysisState.ready,
        durationMs: 12000,
      ),
      lyricCues: <LyricSyncCue>[
        LyricSyncCue(
          contributionId: 'deleted-old-line',
          startMs: 1000,
          endMs: 4000,
          confidence: 0.9,
        ),
      ],
      chordCues: <ChordCue>[],
    );

    final cues = buildPerformanceLyricCues(project, bundle);

    expect(
      cues.map((cue) => cue.contributionId),
      <String>['current-1', 'current-2', 'current-3'],
    );
    expect(cues[0].startMs, lessThan(cues[1].startMs));
    expect(cues[1].startMs, lessThan(cues[2].startMs));
    expect(cues.every((cue) => cue.endMs > cue.startMs), isTrue);
  });

  testWidgets('song sheet renders saved lyrics with editable chords', (
    tester,
  ) async {
    final now = DateTime(2026, 8, 16);
    final project = SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'account-1',
      title: 'Long Lines',
      createdAt: now,
      updatedAt: now,
      contributions: <Contribution>[
        Contribution(
          id: 'section-1',
          projectId: 'song-1',
          authorId: 'user-1',
          authorName: 'Taylor',
          body: '[Verse 1]',
          colorValue: 0xFFFF8A4C,
          createdAt: now,
          kind: ContributionKind.section,
        ),
        _line(
          now,
          id: 'line-1',
          body: 'We wait in long lines',
          position: 1024,
        ),
      ],
    );
    const bundle = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-1',
        fileId: 'file-1',
        storagePath: 'room/song/reference.wav',
        displayName: 'reference.wav',
        state: SongAnalysisState.ready,
        durationMs: 5000,
        musicalKey: 'G',
      ),
      lyricCues: <LyricSyncCue>[
        LyricSyncCue(
          contributionId: 'line-1',
          startMs: 1000,
          endMs: 5000,
          confidence: 0.8,
        ),
      ],
      chordCues: <ChordCue>[
        ChordCue(
          id: 10,
          startMs: 1000,
          endMs: 2800,
          chord: 'G',
          confidence: 0.8,
        ),
        ChordCue(
          id: 11,
          startMs: 3000,
          endMs: 5000,
          chord: 'C',
          confidence: 0.8,
        ),
      ],
    );

    ChordCue? tappedChord;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MusicianSongSheet(
              project: project,
              bundle: bundle,
              transpose: 0,
              fontScale: 1,
              showChords: true,
              editableChords: true,
              onEditChord: (_, chord, __) => tappedChord = chord,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Long Lines'), findsOneWidget);
    expect(find.text('VERSE 1'), findsOneWidget);
    expect(find.text('We'), findsOneWidget);
    expect(find.text('G'), findsWidgets);
    expect(find.text('C'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit_chord_10')));
    await tester.pump();
    expect(tappedChord?.chord, 'G');
  });
}

Contribution _line(
  DateTime now, {
  required String id,
  required String body,
  required double position,
}) {
  return Contribution(
    id: id,
    projectId: 'song-1',
    authorId: 'user-1',
    authorName: 'Taylor',
    body: body,
    colorValue: 0xFFFF8A4C,
    createdAt: now,
    position: position,
  );
}
