import '../../domain/music_models.dart';
import '../../domain/name_policy.dart';

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
