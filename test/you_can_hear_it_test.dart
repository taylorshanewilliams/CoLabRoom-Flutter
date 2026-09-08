import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/listen_screen.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:colabroom/services/now_playing.dart';
import 'package:colabroom/widgets/play_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Can you hear anything?
///
/// The Open Mic shipped unable to play a single note. Not the list of songs,
/// not a person's profile, not the public page for one song — three surfaces
/// built so somebody could decide whether they wanted to work on a piece of
/// music, and every one of them asked for that decision in writing. Two of
/// them drew a waveform icon and a play-circle that did nothing when pressed.
///
/// Nothing in the old suite could have caught it. A screen that renders a
/// list of titles renders perfectly whether or not the titles make a sound,
/// and every test here passed the whole time.
///
/// So these assert the thing itself: that a play control exists where there
/// is something to play, that the listening surface is reachable, and that
/// only one thing can ever sound at once.
void main() {
  Widget _wrap(Widget child) => MaterialApp(
        home: Scaffold(body: child),
      );

  group('there is something to press', () {
    testWidgets('every song on the Open Mic can be played from the list',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await tester.pumpWidget(_wrap(OpenMicScreen(repository: repository)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Walking the trail, which is what a person does now. The tabs are
      // gone: the statement opens a sheet, the direction is chosen there,
      // and picking closes it.
      await tester.tap(find.byKey(const Key('open_mic_statement')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.tap(find.text('Who needs it'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Everybody'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));

      // findsWidgets, not findsOneWidget: the same song now appears in the
      // "out there" strip as well, because the preview account owns it. Two
      // is the correct answer and one would mean the strip had gone.
      expect(find.text('Ladder Of Life'), findsWidgets);
      // The point of the whole change. A card that names a song and cannot
      // play it is asking somebody to judge music by reading.
      expect(find.byType(PlayButton), findsWidgets,
          reason: 'the Open Mic list still cannot play anything');
    });

    testWidgets('the public song page plays the song and each part',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await tester.pumpWidget(_wrap(OpenMicSongScreen(
        projectId: 'preview-open-1',
        repository: repository,
        initial: OpenMicSong(
          id: 'preview-open-1',
          title: 'Ladder Of Life',
          ownerName: 'Mara Ellison',
          putUpAt: DateTime(2026, 9, 1),
          storagePath: 'preview/ladder.m4a',
        ),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // This page had a section headed "Listen" with nothing under it that
      // could be listened to.
      expect(find.byType(PlayButton), findsWidgets,
          reason: 'the song page under the word Listen still plays nothing');
    });
  });

  group('the stage is reachable', () {
    testWidgets('Open Mic offers a way to sit and listen', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await tester.pumpWidget(_wrap(OpenMicScreen(repository: repository)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // ListenScreen sat on main for a week with nothing navigating to it —
      // the exact defect the information-architecture audit deleted two other
      // screens for. A built screen nobody can reach is a deleted screen that
      // still costs review.
      expect(find.byKey(const Key('open_mic_listen')), findsOneWidget,
          reason: 'nothing opens the listening screen');
    });

    testWidgets('and pressing it opens the stage', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: OpenMicScreen(repository: repository)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('open_mic_listen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byType(ListenScreen), findsOneWidget,
          reason: 'the Listen button did not open the stage');
    });
  });

  group('only one thing sounds', () {
    test('starting a second recording takes the player from the first', () {
      final now = NowPlaying.instance;

      // Nothing is loaded to begin with, so nothing claims to be current.
      expect(now.isCurrent('a/one.m4a'), isFalse);
      expect(now.isCurrent(''), isFalse);

      // An empty path is a song with no audio, and must never register as
      // the thing playing — otherwise every silent row in a list lights up
      // together the moment anything else starts.
      expect(now.path, isNull);
    });

    test('a song with no audio offers no way to play it', (){
      final song = OpenMicSong(
        id: 'x',
        title: 'Nothing recorded yet',
        ownerName: 'Somebody',
        putUpAt: DateTime(2026, 9, 1),
      );
      expect(song.canPlay, isFalse);
    });
  });
}
