import 'package:colabroom/domain/tonight_models.dart';
import 'package:colabroom/features/songs/tonight.dart';
import 'package:flutter_test/flutter_test.dart';

/// Something new every time you come back.
///
/// The card draws from three places in a fixed order and never shows a
/// thing twice once it has been closed. These pin the order, the arithmetic
/// behind the chord move, and what "seen" means.
void main() {
  final even = DateTime(2026, 9, 16); // day 258 of the year -> even
  final odd = DateTime(2026, 9, 17);
  const song = TonightSong(
    projectId: 'song-1',
    title: 'Divide',
    key: 'D major',
    chords: <String>['D:maj', 'G:maj', 'A:maj', 'Bm'],
  );
  const prompt = TonightPrompt(
    id: 7,
    kind: 'first_line',
    title: 'Write the first line',
    body: 'The thing you should have said in the car.',
    cta: 'Record',
  );

  test('the chord move names a chord of the key the song has not used', () {
    // D major: D Em F#m G A Bm C#dim. Used: D G A Bm. First untouched: Em.
    expect(untouchedChordFor(song), 'Em');
    const all = TonightSong(
      projectId: 'x', title: 'x', key: 'D major',
      chords: <String>['D', 'Em', 'F#m', 'G', 'A', 'Bm', 'C#dim'],
    );
    expect(untouchedChordFor(all), isNull);
    const unknownKey = TonightSong(projectId: 'x', title: 'x', key: '', chords: <String>[]);
    expect(untouchedChordFor(unknownKey), isNull);
  });

  test('a release you have not seen comes first, for a week, once', () {
    final release = ReleaseNote(
      sha: 'abc1234',
      title: 'The band talks in the room',
      body: 'Every room is a thread now.',
      mergedAt: even.subtract(const Duration(days: 2)),
    );
    final card = composeTonight(
      today: even,
      releases: <ReleaseNote>[release],
      song: song,
      prompt: prompt,
      seen: (_) => false,
    );
    expect(card!.kind, TonightKind.whatChanged);
    expect(card.title, 'The band talks in the room');

    final closed = composeTonight(
      today: even,
      releases: <ReleaseNote>[release],
      song: song,
      prompt: prompt,
      seen: (id) => id == 'release-abc1234',
    );
    expect(closed!.kind, TonightKind.chordMove);

    final old = ReleaseNote(sha: 'old', title: 'Old', body: '', mergedAt: even.subtract(const Duration(days: 9)));
    final stale = composeTonight(today: even, releases: <ReleaseNote>[old], song: null, prompt: prompt, seen: (_) => false);
    expect(stale!.kind, TonightKind.firstLine, reason: 'a week-old release is no longer news');
  });

  test('a chord move on even days, a prompt on odd ones', () {
    final move = composeTonight(today: even, releases: const <ReleaseNote>[], song: song, prompt: prompt, seen: (_) => false);
    expect(move!.kind, TonightKind.chordMove);
    expect(move.title, 'Try Em on Divide');
    expect(move.body, contains('D major'));
    expect(move.projectId, 'song-1');

    final line = composeTonight(today: odd, releases: const <ReleaseNote>[], song: song, prompt: prompt, seen: (_) => false);
    expect(line!.kind, TonightKind.firstLine);
    expect(line.cta, 'Record');
  });

  test('closed means closed, and nothing means nothing', () {
    final none = composeTonight(
      today: even,
      releases: const <ReleaseNote>[],
      song: song,
      prompt: prompt,
      seen: (_) => true,
    );
    expect(none, isNull);
    final empty = composeTonight(today: odd, releases: const <ReleaseNote>[], song: null, prompt: null, seen: (_) => false);
    expect(empty, isNull);
  });

  test('a challenge is its own kind', () {
    const challenge = TonightPrompt(id: 9, kind: 'challenge', title: 'Eight bars, one take', body: 'Loop the bridge.', cta: 'Open');
    final card = composeTonight(today: odd, releases: const <ReleaseNote>[], song: null, prompt: challenge, seen: (_) => false);
    expect(card!.kind, TonightKind.challenge);
  });
}
