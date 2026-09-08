import 'package:colabroom/domain/music_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// What arrives with an ask.
///
/// An ask used to be a title, a name, the word "bass" and a sentence. You
/// could not hear the song, and you did not know the key, the tempo, how long
/// it was, or what was already on it — so the only honest answer was "let me
/// go and look", and the number of people who go and look is the number of
/// collaborations this app can ever have.
///
/// Every one of those facts already existed. The app worked them out when it
/// made the song sheet; the ask was never told to carry them.
AskForMe _ask({
  int? durationMs,
  String? key,
  double? bpm,
  bool sheet = false,
}) {
  return AskForMe(
    id: 'ask',
    projectId: 'song',
    songTitle: 'Weathervane',
    askedByName: 'Dev',
    createdAt: DateTime(2026, 9, 8),
    part: 'bass',
    durationMs: durationMs,
    musicalKey: key,
    bpm: bpm,
    hasSongSheet: sheet,
  );
}

void main() {
  test('the brief reads the way somebody deciding would want it', () {
    final full = _ask(durationMs: 134000, key: 'G', bpm: 96.4, sheet: true);
    expect(full.brief, '2:14 · in G · 96 bpm · chords and words worked out');
  });

  test('it leaves out what the app does not know', () {
    expect(_ask(durationMs: 134000).brief, '2:14');
    expect(_ask(key: 'Bm').brief, 'in Bm');
    // Not an empty row of separators. A song with no recording has nothing
    // to say about itself, and saying it badly is worse than the old card.
    expect(_ask().brief, isNull);
  });

  test('the clock is a clock, not a number of milliseconds', () {
    expect(_ask(durationMs: 65000).brief, '1:05');
    expect(_ask(durationMs: 600000).brief, '10:00');
    // Rounded, not truncated: 59.6 seconds is a minute to a person.
    expect(_ask(durationMs: 59600).brief, '1:00');
  });

  test('nothing here is a count of somebody’s work', () {
    final ask = AskForMe(
      id: 'a',
      projectId: 's',
      songTitle: 'T',
      askedByName: 'D',
      partsOnIt: const <String>['vocal', 'lead'],
      createdAt: DateTime(2026, 9, 8),
    );
    expect(ask.partsOnIt, <String>['vocal', 'lead'],
        reason: 'what is on the song is words — a tally of takes tells the '
            'person answering nothing about whether there is a hole shaped '
            'like them');
  });
}
