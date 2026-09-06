import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/services/song_search.dart';
import 'package:flutter_test/flutter_test.dart';

MusicRoom _room({
  required String id,
  required String name,
  required List<SongProject> projects,
}) {
  final now = DateTime(2026, 8, 23);
  return MusicRoom(
    id: id,
    accountId: 'user',
    name: name,
    icon: '♪',
    createdAt: now,
    updatedAt: now,
    projects: projects,
  );
}

SongProject _song({
  required String id,
  required String roomId,
  required String title,
  List<String> lines = const <String>[],
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime(2026, 8, 23);
  return SongProject(
    id: id,
    roomId: roomId,
    accountId: 'user',
    title: title,
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      for (var i = 0; i < lines.length; i += 1)
        Contribution(
          id: '$id-line-$i',
          projectId: id,
          authorId: 'user',
          authorName: 'Taylor',
          body: lines[i],
          colorValue: 0,
          createdAt: now,
          position: (i + 1) * 1024,
        ),
    ],
  );
}

void main() {
  final rooms = <MusicRoom>[
    _room(
      id: 'room-1',
      name: 'After Hours Studio',
      projects: <SongProject>[
        _song(
          id: 'song-1',
          roomId: 'room-1',
          title: 'Midnight Signal',
          lines: <String>['Streetlights blur like a warning in the rain'],
          updatedAt: DateTime(2026, 8, 22),
        ),
        _song(
          id: 'song-2',
          roomId: 'room-1',
          title: 'Paper Moon',
          lines: <String>['Counting every hour till the morning'],
          updatedAt: DateTime(2026, 8, 20),
        ),
      ],
    ),
    _room(
      id: 'room-2',
      name: 'Acoustic Ideas',
      projects: <SongProject>[
        _song(
          id: 'song-3',
          roomId: 'room-2',
          title: 'Signal Fire',
          updatedAt: DateTime(2026, 8, 23),
        ),
      ],
    ),
  ];

  test('finds songs by title across every room', () {
    final results = searchSongs(rooms, 'signal');
    expect(results.map((r) => r.project.id), <String>['song-1', 'song-3']);
    expect(results.every((r) => r.match == SongMatch.title), isTrue);
  });

  test('finds a song by a lyric and reports the matching line', () {
    final results = searchSongs(rooms, 'streetlights');
    expect(results, hasLength(1));
    expect(results.single.project.id, 'song-1');
    expect(results.single.match, SongMatch.lyric);
    expect(results.single.lyricLine, 'Streetlights blur like a warning in the rain');
  });

  test('finds every song in a room when the room name matches', () {
    final results = searchSongs(rooms, 'acoustic');
    expect(results.map((r) => r.project.id), <String>['song-3']);
    expect(results.single.match, SongMatch.room);
  });

  test('ranks title matches above lyric matches', () {
    // "morning" is a lyric in Paper Moon; "Moon" is in its title. Searching
    // a term that hits one song's title and another's lyric must put the
    // title first.
    final results = searchSongs(rooms, 'moon');
    expect(results.first.project.id, 'song-2');
    expect(results.first.match, SongMatch.title);
  });

  test('is case and whitespace insensitive', () {
    expect(searchSongs(rooms, '  MIDNIGHT  ').single.project.id, 'song-1');
  });

  test('an empty query returns nothing rather than everything', () {
    expect(searchSongs(rooms, ''), isEmpty);
    expect(searchSongs(rooms, '   '), isEmpty);
  });

  test('a song matches only once, on its strongest reason', () {
    // "Signal Fire" lives in a room whose name doesn't match, but the title
    // does — it must not also appear as a room match.
    final results = searchSongs(rooms, 'signal fire');
    expect(results, hasLength(1));
  });

  test('all songs are ordered most recently touched first', () {
    final results = allSongsByRecency(rooms);
    expect(results.map((r) => r.project.id), <String>['song-3', 'song-1', 'song-2']);
  });

  // The catalog screen, the set picker and the catalog list each had their
  // own `title.contains(...)` and none of them read a lyric. Somebody found
  // that from the outside: a line they could search for on the Songs tab
  // returned nothing once they were standing inside the catalog holding it.
  // These are what stop the app growing a sixth private definition of
  // "matches".
  group('one definition of a match, for every list', () {
    final song = rooms.first.projects.first; // Midnight Signal

    test('a title still matches', () {
      expect(songMatch(song, 'midnight'), SongMatch.title);
      expect(songMatch(song, '  MIDNIGHT '), SongMatch.title);
    });

    test('a lyric matches, which is the whole bug', () {
      expect(songMatch(song, 'streetlights'), SongMatch.lyric);
      expect(matchedLyricLine(song, 'streetlights'),
          'Streetlights blur like a warning in the rain');
    });

    test('a miss is a miss', () {
      expect(songMatch(song, 'trombone'), isNull);
      expect(matchedLyricLine(song, 'trombone'), isNull);
    });

    test('the catalog name only counts when the caller says it matched', () {
      expect(songMatch(song, 'after hours'), isNull);
      expect(songMatch(song, 'after hours', roomNameMatches: true),
          SongMatch.room);
    });

    test('an empty query keeps everything, because a filter nobody typed '
        'should not hide anything', () {
      expect(songMatch(song, ''), SongMatch.title);
      expect(songMatch(song, '   '), SongMatch.title);
    });

    test('it agrees with searchSongs, which is the point', () {
      for (final query in <String>['midnight', 'streetlights', 'trombone']) {
        final viaList = searchSongs(rooms, query)
            .where((r) => r.project.id == song.id)
            .map((r) => r.match)
            .firstOrNull;
        expect(songMatch(song, query), viaList,
            reason: 'the two disagreed about “$query”');
      }
    });
  });
}
