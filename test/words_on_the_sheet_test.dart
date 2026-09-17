import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// A song whose words are on its song sheet says so.
///
/// From the audit of 17 September 2026: Dakota was made from a recording, its
/// words are on its sheet, and on a phone it opened to "Tap anywhere and start
/// writing…" right after Home said somebody had changed the words.
void main() {
  final at = DateTime(2026, 9, 17);
  SongProject song({List<Contribution> lines = const <Contribution>[]}) => SongProject(
        id: 's1',
        roomId: 'r1',
        accountId: 'me',
        title: 'Dakota',
        createdAt: at,
        updatedAt: at,
        contributions: lines,
      );
  SongAnalysisBundle sheet({String? transcript}) => SongAnalysisBundle(
        reference: ReferenceTrack(
          projectId: 's1',
          fileId: 'f1',
          storagePath: 'p',
          displayName: 'dakota.m4a',
          state: SongAnalysisState.ready,
          transcriptText: transcript,
        ),
        lyricCues: const <LyricSyncCue>[],
        chordCues: const <ChordCue>[],
      );
  final line = Contribution(
    id: 'c1', projectId: 's1', authorId: 'me', authorName: 'Me', body: 'a line',
    colorValue: 1, position: 1, createdAt: at,
  );

  test('nothing written here and words on the sheet: say where they are', () {
    expect(wordsLiveOnTheSheet(song(), sheet(transcript: 'the map, it is small')), isTrue);
  });

  test('words written here: nothing to point at', () {
    expect(wordsLiveOnTheSheet(song(lines: <Contribution>[line]), sheet(transcript: 'the map')), isFalse);
  });

  test('no sheet, or a sheet with no words: a blank page is a blank page', () {
    expect(wordsLiveOnTheSheet(song(), null), isFalse);
    expect(wordsLiveOnTheSheet(song(), sheet()), isFalse);
    expect(wordsLiveOnTheSheet(song(), sheet(transcript: '   ')), isFalse);
  });
}
