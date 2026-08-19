import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognized vocal text is split into editable lyric-sized lines', () {
    final lines = splitTranscriptIntoLyricLines(
      'We drove all night through the rain. '
      'Nobody said where the highway would end but we kept going.',
      maxWordsPerLine: 6,
    );

    expect(lines, isNotEmpty);
    expect(lines.every((line) => line.split(' ').length <= 6), isTrue);
    expect(lines.join(' '), contains('highway'));
  });

  test('analysis can be ready from a vocal draft before lyrics are synced', () {
    const reference = ReferenceTrack(
      projectId: 'project',
      fileId: 'file',
      storagePath: 'room/project/reference.mp3',
      displayName: 'reference.mp3',
      state: SongAnalysisState.ready,
      transcriptText: 'we kept going',
      transcriptWords: <TranscriptWord>[
        TranscriptWord(word: 'we', startMs: 100, endMs: 260),
        TranscriptWord(word: 'kept', startMs: 260, endMs: 480),
        TranscriptWord(word: 'going', startMs: 480, endMs: 760),
      ],
    );
    const bundle = SongAnalysisBundle(
      reference: reference,
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    expect(bundle.ready, isTrue);
    expect(bundle.hasSyncedLyrics, isFalse);
  });

  test('transcript words round-trip through the stored JSON shape', () {
    const word = TranscriptWord(
      word: 'home',
      startMs: 1240,
      endMs: 1580,
    );

    final restored = TranscriptWord.fromJson(word.toJson());

    expect(restored.word, 'home');
    expect(restored.startMs, 1240);
    expect(restored.endMs, 1580);
  });
}
