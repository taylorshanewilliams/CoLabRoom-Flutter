import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

SongProject _project(List<Contribution> contributions) {
  final now = DateTime(2026, 8, 23);
  return SongProject(
    id: 'song-1',
    roomId: 'room-1',
    accountId: 'user',
    title: 'Long Lines',
    createdAt: now,
    updatedAt: now,
    contributions: contributions,
  );
}

Contribution _line(String body, {ContributionKind kind = ContributionKind.lyric}) {
  return Contribution(
    id: body.hashCode.toString(),
    projectId: 'song-1',
    authorId: 'user',
    authorName: 'Taylor',
    body: body,
    kind: kind,
    colorValue: 0,
    createdAt: DateTime(2026, 8, 23),
    position: 1024,
  );
}

void main() {
  test('builds a prompt from the song\'s typed lyrics', () {
    final prompt = lyricsPromptFor(_project(<Contribution>[
      _line('We wait in long lines'),
      _line('Nobody moves at all'),
    ]));
    expect(prompt, 'We wait in long lines Nobody moves at all');
  });

  test('leaves out sections and notes, which nobody sang', () {
    final prompt = lyricsPromptFor(_project(<Contribution>[
      _line('[Verse 1]', kind: ContributionKind.section),
      _line('We wait in long lines'),
      _line('fix this bridge later', kind: ContributionKind.note),
    ]));
    expect(prompt, 'We wait in long lines');
  });

  test('collapses whitespace so the prompt spends no tokens on layout', () {
    final prompt = lyricsPromptFor(_project(<Contribution>[
      _line('  We   wait \n in long lines  '),
    ]));
    expect(prompt, 'We wait in long lines');
  });

  test('returns null when there are no typed lyrics to prime with', () {
    expect(lyricsPromptFor(_project(<Contribution>[])), isNull);
    expect(
      lyricsPromptFor(_project(<Contribution>[
        _line('[Chorus]', kind: ContributionKind.section),
      ])),
      isNull,
    );
    expect(lyricsPromptFor(_project(<Contribution>[_line('   ')])), isNull);
  });

  test('truncates past what Whisper will read, rather than being dropped', () {
    final long = List<Contribution>.generate(200, (i) => _line('line number $i here'));
    final prompt = lyricsPromptFor(_project(long));
    expect(prompt, isNotNull);
    expect(prompt!.length, maxLyricsPromptChars);
  });
}
