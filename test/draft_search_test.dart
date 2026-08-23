import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/domain/studio_draft_models.dart';
import 'package:colabroom/features/studio/draft_search.dart';
import 'package:flutter_test/flutter_test.dart';

StudioDraft _draft({
  required String id,
  required String name,
  String? transcript,
  String? key,
}) {
  return StudioDraft(
    id: id,
    accountId: 'user',
    displayName: name,
    storagePath: 'user/$id/reference.mp3',
    state: SongAnalysisState.ready,
    createdAt: DateTime(2026, 8, 23),
    transcriptText: transcript,
    musicalKey: key,
  );
}

void main() {
  final drafts = <StudioDraft>[
    _draft(
      id: 'a',
      name: 'Long Lines',
      transcript: 'we wait in long lines nobody moves at all',
      key: 'A minor',
    ),
    _draft(
      id: 'b',
      name: 'Recording 8/23 11:40',
      transcript: 'streetlights blur like a warning in the rain tonight',
      key: 'C major',
    ),
    _draft(id: 'c', name: 'Bridge idea', key: 'A minor'),
  ];

  test('an empty query returns everything, in order', () {
    final results = searchDrafts(drafts, '');
    expect(results.map((r) => r.draft.id), <String>['a', 'b', 'c']);
  });

  test('finds an idea by a line that was sung in it', () {
    // The whole point: an unnamed take is findable by a half-remembered word.
    final results = searchDrafts(drafts, 'streetlights');
    expect(results, hasLength(1));
    expect(results.single.draft.id, 'b');
    expect(results.single.match, DraftMatch.lyric);
    expect(results.single.lyricSnippet, contains('streetlights'));
  });

  test('name matches rank above lyric matches', () {
    // "lines" is in one title and another's lyrics.
    final results = searchDrafts(drafts, 'lines');
    expect(results.first.draft.id, 'a');
    expect(results.first.match, DraftMatch.name);
  });

  test('a draft matches once, on its strongest reason', () {
    final results = searchDrafts(drafts, 'long lines');
    expect(results.where((r) => r.draft.id == 'a'), hasLength(1));
  });

  group('lyricSnippetAround', () {
    test('windows around the match rather than starting from the top', () {
      final long = 'aaa ${'filler ' * 20}needle ${'more ' * 20}zzz';
      final snippet = lyricSnippetAround(long, 'needle');
      expect(snippet, contains('needle'));
      expect(snippet, startsWith('…'));
      expect(snippet, endsWith('…'));
      expect(snippet!.length, lessThan(120));
    });

    test('no ellipsis when the whole transcript already fits', () {
      final snippet = lyricSnippetAround('short and sweet', 'sweet');
      expect(snippet, 'short and sweet');
    });

    test('returns null when the word is not there', () {
      expect(lyricSnippetAround('nothing here', 'absent'), isNull);
      expect(lyricSnippetAround(null, 'absent'), isNull);
      expect(lyricSnippetAround('something', ''), isNull);
    });
  });

  test('offers only keys that actually occur, sorted and deduplicated', () {
    expect(availableKeys(drafts), <String>['A minor', 'C major']);
  });
}
