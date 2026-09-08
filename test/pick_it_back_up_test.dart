import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/songs/pick_it_back_up.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One idea you left, brought back.
///
/// The app has two tabs and neither is a reason to open it on a quiet
/// Tuesday: one is a filing cabinet, the other needs other people to have
/// done something. This is the first thing that answers "what did *you*
/// leave", and the rules it picks by are the whole design — get them wrong
/// and a warm reminder becomes a chore list about your own abandoned work.
DateTime _today = DateTime(2026, 9, 8);

SongProject _song(
  String title, {
  required int daysAgo,
  bool audio = true,
  SongStatus status = SongStatus.active,
  SongAnalysisState? analysis,
}) {
  final when = _today.subtract(Duration(days: daysAgo));
  return SongProject(
    id: title,
    roomId: 'room',
    accountId: 'account',
    title: title,
    createdAt: when,
    updatedAt: when,
    status: status,
    hasAudioReference: audio,
    analysisState: analysis,
  );
}

void main() {
  test('a library nobody has abandoned shows nothing', () {
    final picked = PickItBackUp.choose(
      <SongProject>[_song('Yesterday’s idea', daysAgo: 2)],
      now: _today,
    );
    // Announcing that you have no forgotten songs is worse than saying
    // nothing, and a song touched on Sunday is in progress, not forgotten.
    expect(picked, isNull);
  });

  test('nothing to hear is nothing to come back to', () {
    final picked = PickItBackUp.choose(
      <SongProject>[_song('Just a title', daysAgo: 400, audio: false)],
      now: _today,
    );
    expect(picked, isNull,
        reason: 'handing somebody an empty song is the app admitting it '
            'knows nothing about it');
  });

  test('a finished song is not an abandoned one', () {
    final picked = PickItBackUp.choose(
      <SongProject>[
        _song('Done', daysAgo: 400, status: SongStatus.completed),
      ],
      now: _today,
    );
    expect(picked, isNull);
  });

  test('the pile takes turns, and holds still within a day', () {
    final songs = <SongProject>[
      _song('One', daysAgo: 100),
      _song('Two', daysAgo: 200),
      _song('Three', daysAgo: 300),
    ];

    final today = PickItBackUp.choose(songs, now: _today)!.song.title;
    expect(PickItBackUp.choose(songs, now: _today)!.song.title, today,
        reason: 'a card that reshuffles on every rebuild is a card nobody '
            'trusts');

    final picks = <String>{
      for (var day = 0; day < 3; day++)
        PickItBackUp.choose(songs,
            now: _today.add(Duration(days: day)))!.song.title,
    };
    expect(picks.length, 3,
        reason: 'the same dead song every morning stops being an invitation');
  });

  test('it says what it knows, which is the reason to come back', () {
    final withSheet = PickItBackUp.choose(
      <SongProject>[
        _song('Weathervane',
            daysAgo: 300, analysis: SongAnalysisState.ready),
      ],
      now: _today,
    )!;
    expect(withSheet.known, contains('song sheet'));
    expect(withSheet.when, contains('You left this in'));

    final recent = PickItBackUp.choose(
      <SongProject>[_song('Newer', daysAgo: 21)],
      now: _today,
    )!;
    // Weeks while it still feels like a thread you could pick up; the month
    // once the number has stopped meaning anything.
    expect(recent.when, 'You left this 3 weeks ago');
  });

  testWidgets('it draws the song, and draws nothing when there is none',
      (tester) async {
    Future<void> pump(List<SongProject> songs) async {
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: PickItBackUp(songs: songs, onOpen: (_) {}),
        ),
      ));
      await tester.pump();
    }

    await pump(<SongProject>[]);
    expect(find.byKey(const Key('pick_it_back_up')), findsNothing);

    await pump(<SongProject>[_song('Ladder Of Life', daysAgo: 90)]);
    expect(find.text('Ladder Of Life'), findsOneWidget);
  });
}
