import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/lyric_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cleans bullets, numbering, headings, and section labels', () {
    final draft = LyricImportService.fromText(
      sourceName: 'notes.txt',
      text: '''
Lyrics
VERSE 1:
• First line
2. Second line
Chorus
- Sing it again
12
''',
    );

    expect(draft.lines.map((line) => line.body), <String>[
      '[Verse 1]',
      'First line',
      'Second line',
      '[Chorus]',
      'Sing it again',
    ]);
    expect(draft.lines.first.kind, ContributionKind.section);
    expect(draft.lines[1].kind, ContributionKind.lyric);
  });

  test('flattens a CSV into lyric lines for review', () {
    final draft = LyricImportService.fromCsv(
      sourceName: 'song.csv',
      csvText: 'Section,Lyric\nVerse 1,"Hold, the note"\nChorus,Bring it home',
    );

    expect(draft.lines.map((line) => line.body), <String>[
      '[Verse 1]',
      'Hold, the note',
      '[Chorus]',
      'Bring it home',
    ]);
  });
}
