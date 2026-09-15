import '../../domain/tonight_models.dart';
import 'firsts.dart';
import '../../services/chord_names.dart';
import '../../services/music_reference.dart';

/// Something new every time you come back.
///
/// Taylor, 15 Sep: a welcome that is "consistently new and fresh, so every
/// time you come back to the app, you see something new". The wrong way is
/// streaks and badges, which this app has ruled out. The right way is that
/// the novelty comes from content and from your own work, so it is there on
/// day one with four users and still true at a million. This is that card:
/// one a day, drawn from three places, in this order --
///
///   1. **What changed.** A release from the last week you have not seen.
///      The app announcing itself, from the pull request title, once.
///   2. **A chord move on your own song.** The arithmetic the app already
///      does: a chord of the key this song has never reached for.
///   3. **A prompt.** A first line to record in one breath, or a practice
///      challenge, from a table with ninety days in it.
///
/// Pure, so the rule can be tested: give it the day and what the app knows,
/// get the card. Nothing here is a lesson and nothing here is a score.
enum TonightKind { whatChanged, firstStep, chordMove, firstLine, challenge }

class TonightCard {
  const TonightCard({
    required this.kind,
    required this.id,
    required this.title,
    required this.body,
    required this.cta,
    this.projectId,
    this.go,
  });

  final TonightKind kind;

  /// Stable for the thing being shown, so "not now" hides exactly this one:
  /// the release's sha, the song and chord, or the prompt's id and the day.
  final String id;
  final String title;
  final String body;
  final String cta;
  final String? projectId;

  /// Where a first step leads. Null for every other kind.
  final FirstGo? go;
}

/// The note a chord label starts on: "F#m7" -> "F#", "A:min7" -> "A".
String? chordRootOf(String label) {
  final match = RegExp(r'^([A-Ga-g][#b]?)').firstMatch(label.trim());
  if (match == null) return null;
  final root = match.group(1)!;
  return root[0].toUpperCase() + root.substring(1);
}

/// The chord of the key this song has not used yet, or null when the song
/// has used them all or the key is not one the app knows.
String? untouchedChordFor(TonightSong song) {
  final key = keyReference(song.key);
  if (key == null) return null;
  final used = <String>[
    for (final label in song.chords)
      if (chordRootOf(label) case final root?) root,
  ];
  for (final chord in key.diatonic) {
    final root = chordRootOf(chord);
    if (root == null) continue;
    if (!used.any((u) => samePitch(u, root))) return chord;
  }
  return null;
}

/// Today's card.
///
/// [seen] is what the person has closed -- release shas, song-and-chord
/// ids, prompt ids -- so nothing comes back once it has been dismissed.
TonightCard? composeTonight({
  required DateTime today,
  required List<ReleaseNote> releases,
  required TonightSong? song,
  required TonightPrompt? prompt,
  required bool Function(String id) seen,
  List<First> firsts = const <First>[],
}) {
  // 1. What changed, once per release, for a week.
  for (final release in releases) {
    final age = today.difference(release.mergedAt);
    if (age.inDays > 7 || age.isNegative) continue;
    final id = 'release-${release.sha}';
    if (seen(id)) continue;
    return TonightCard(
      kind: TonightKind.whatChanged,
      id: id,
      title: release.title,
      body: release.body.isEmpty ? 'New in this build.' : release.body,
      cta: 'Got it',
    );
  }

  // 2. Something you can now do, unlocked by what you have done, once.
  for (final first in firsts) {
    if (seen(first.id)) continue;
    return TonightCard(
      kind: TonightKind.firstStep,
      id: first.id,
      title: first.title,
      body: first.body,
      cta: first.cta,
      projectId: first.projectId,
      go: first.go,
    );
  }

  // 3. A chord move on your own song, on even days, when there is one.
  // Counted in UTC dates: a local difference across a clock change is a
  // day short, and an odd day would silently become an even one.
  final dayOfYear = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(today.year))
      .inDays;
  if (song != null && dayOfYear.isEven) {
    final chord = untouchedChordFor(song);
    if (chord != null) {
      final id = 'move-${song.projectId}-$chord';
      if (!seen(id)) {
        final key = keyReference(song.key);
        final written = chordDisplay(chord);
        return TonightCard(
          kind: TonightKind.chordMove,
          id: id,
          title: 'Try $written on ${song.title}',
          body: '${song.title} is in ${key?.display ?? song.key} and has never '
              'touched $written. Put it on the line before the chorus and '
              'hear what it does.',
          cta: 'Open ${song.title}',
          projectId: song.projectId,
        );
      }
    }
  }

  // 4. A prompt from the table.
  if (prompt != null) {
    final id = 'prompt-${prompt.id}-${today.year}-${today.month}-${today.day}';
    if (!seen(id)) {
      return TonightCard(
        kind: prompt.kind == 'challenge'
            ? TonightKind.challenge
            : TonightKind.firstLine,
        id: id,
        title: prompt.title,
        body: prompt.body,
        cta: prompt.cta,
      );
    }
  }
  return null;
}
