import '../domain/music_models.dart';
import '../domain/name_policy.dart';

/// Why a song matched, so results can show the reason rather than just the
/// title. Ranked in the order below: a title hit is what someone usually
/// means, a lyric hit is the one that feels like magic ("the song where I
/// wrote 'streetlights'").
enum SongMatch { title, lyric, room }

class SongSearchResult {
  const SongSearchResult({
    required this.project,
    required this.room,
    required this.match,
    this.lyricLine,
  });

  final SongProject project;
  final MusicRoom room;
  final SongMatch match;

  /// The contribution line that matched, when [match] is [SongMatch.lyric].
  /// Shown under the title so the result explains itself.
  final String? lyricLine;
}

/// Whether one song answers a query, and why — null when it does not.
///
/// The single definition of "does this song match", so that every list in the
/// app agrees. It did not used to: the room, the set and the room list
/// each filtered on `title.contains(...)` of their own, so a lyric you could
/// find from the Songs tab vanished the moment you were standing inside the
/// room that held it. Somebody hit exactly that during testing, and the
/// honest description of the bug is not "lyric search is missing here" — it
/// is that there were five searches pretending to be one.
///
/// [roomNameMatches] is passed in rather than computed, because a caller
/// filtering one room usually knows the answer already and a caller
/// filtering a hundred should not recompute it per song.
/// The line that matched, so a search result can show where in the song it is.
///
/// The whole appeal of searching a lyric is "the song where I sang about the
/// harbour" — and a result that only says the title has answered a different
/// question. `searchSongs` has carried this since it shipped and the room
/// screen never asked for it, so inside a room you could find the song and
/// not see why.
///
/// Null when the match was on the title or the room name, because there is
/// no line to show and the title is already on the tile.
String? songMatchLine(SongProject project, String query) {
  final needle = NamePolicy.normalized(query);
  if (needle.isEmpty) return null;
  if (NamePolicy.normalized(project.title).contains(needle)) return null;
  return _firstLyricMatch(project, needle);
}

SongMatch? songMatch(
  SongProject project,
  String query, {
  bool roomNameMatches = false,
}) {
  final needle = NamePolicy.normalized(query);
  if (needle.isEmpty) return SongMatch.title;
  if (NamePolicy.normalized(project.title).contains(needle)) {
    return SongMatch.title;
  }
  if (_firstLyricMatch(project, needle) != null) return SongMatch.lyric;
  return roomNameMatches ? SongMatch.room : null;
}

/// The line that matched, for a list that wants to show why.
String? matchedLyricLine(SongProject project, String query) {
  final needle = NamePolicy.normalized(query);
  if (needle.isEmpty) return null;
  return _firstLyricMatch(project, needle);
}

/// Searches every song the user can reach, by title, by lyric text, and by
/// the name of the Room it lives in.
///
/// Runs entirely against data already in memory — rooms come loaded with
/// their projects and each project with its contributions, so lyric search
/// needs no extra query and works offline. If a Room ever grows past a few
/// thousand lines this should move server-side, but at that point the app
/// has other problems.
///
/// Pure so it can be tested without a widget tree.
List<SongSearchResult> searchSongs(List<MusicRoom> rooms, String query) {
  final needle = NamePolicy.normalized(query);
  if (needle.isEmpty) return const <SongSearchResult>[];

  final results = <SongSearchResult>[];
  for (final room in rooms) {
    final roomMatches = NamePolicy.normalized(room.name).contains(needle);
    for (final project in room.projects) {
      if (NamePolicy.normalized(project.title).contains(needle)) {
        results.add(SongSearchResult(project: project, room: room, match: SongMatch.title));
        continue;
      }

      final line = _firstLyricMatch(project, needle);
      if (line != null) {
        results.add(SongSearchResult(
          project: project,
          room: room,
          match: SongMatch.lyric,
          lyricLine: line,
        ));
        continue;
      }

      if (roomMatches) {
        results.add(SongSearchResult(project: project, room: room, match: SongMatch.room));
      }
    }
  }

  // Title hits first, then lyric, then room — and alphabetical within each
  // band so the order is stable between keystrokes rather than jumping
  // around as results are added.
  results.sort((left, right) {
    final byMatch = left.match.index.compareTo(right.match.index);
    if (byMatch != 0) return byMatch;
    return left.project.title.toLowerCase().compareTo(right.project.title.toLowerCase());
  });
  return List<SongSearchResult>.unmodifiable(results);
}

String? _firstLyricMatch(SongProject project, String needle) {
  for (final contribution in project.contributions) {
    if (NamePolicy.normalized(contribution.body).contains(needle)) {
      return contribution.body.trim();
    }
  }
  return null;
}

/// Every song across every Room, most recently touched first — the default
/// ordering when nothing is being searched, because "what was I just working
/// on" is the question this screen exists to answer.
List<SongSearchResult> allSongsByRecency(List<MusicRoom> rooms) {
  final results = <SongSearchResult>[
    for (final room in rooms)
      for (final project in room.projects)
        SongSearchResult(project: project, room: room, match: SongMatch.title),
  ];
  results.sort((left, right) => right.project.updatedAt.compareTo(left.project.updatedAt));
  return List<SongSearchResult>.unmodifiable(results);
}
