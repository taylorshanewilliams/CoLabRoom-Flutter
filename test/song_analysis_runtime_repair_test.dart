import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Was written against splitTranscriptIntoLyricLines(String), which no
  // longer exists — grouping moved onto SongAnalysisService and works from
  // timed words so it can break lines on real pauses rather than word count.
  // The test never failed during that change because nothing in CI ran it.
  test('transcript words are grouped into lines on pauses', () {
    // A clear gap after "rain" — larger than the 650ms pause threshold —
    // should start a new line; the words either side of it should not.
    final lines = groupTranscriptWordsIntoLines(const <TranscriptWord>[
      TranscriptWord(word: 'We', startMs: 0, endMs: 200),
      TranscriptWord(word: 'drove', startMs: 210, endMs: 420),
      TranscriptWord(word: 'through', startMs: 430, endMs: 640),
      TranscriptWord(word: 'the', startMs: 650, endMs: 760),
      TranscriptWord(word: 'rain', startMs: 770, endMs: 1000),
      TranscriptWord(word: 'nobody', startMs: 2000, endMs: 2300),
      TranscriptWord(word: 'said', startMs: 2310, endMs: 2500),
    ]);

    expect(lines, hasLength(2));
    expect(lines.first.map((w) => w.word).join(' '), 'We drove through the rain');
    expect(lines.last.map((w) => w.word).join(' '), 'nobody said');
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
