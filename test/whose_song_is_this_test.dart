import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/audience_dial.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/services/project_export_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whose song is this?
///
/// Every Musician, Same Song, 17 September 2026 calls this one of the two
/// gates. Almost everything the plan wants for schools, worship teams and
/// cover bands is safe on a song the room wrote and is not safe on a song
/// somebody else wrote — and until the app can tell the two apart it has to
/// treat every song as the risky kind, which is what blocks the work behind
/// it.
///
/// Three things have to hold. The question is asked once, at the moment it
/// means something, and never again. A song the room did not write cannot
/// reach the Open Mic. And its words do not leave in an export.
Future<MusicBetaController> _openSong(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: const SongWorkspaceScreen(projectId: 'song-1'),
    ),
  ));
  await _settle(tester);
  return controller;
}

/// Pumped rather than settled: the workspace joins a cowork stream when it
/// opens, and the other tests on this screen pump for the same reason.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Opens the dial and presses the one move at the top of it.
Future<void> _reachForTheOpenMic(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('song_audience_dial')));
  await _settle(tester);
  await tester.tap(find.byKey(const Key('audience_open_mic_toggle')));
  await _settle(tester);
}

/// Opens the dial and presses the other way out of the room — the one that
/// publishes furthest, onto a page `public_songs` (0096) serves to anybody.
Future<void> _reachForTheShowcase(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('song_audience_dial')));
  await _settle(tester);
  await tester.tap(find.byKey(const Key('audience_show_finished')));
  await _settle(tester);
}

SongAudience _audience(
  SongReach reach, {
  bool onOpenMic = false,
  bool onShowcase = false,
}) =>
    SongAudience(
      reach: reach,
      listeners: const <SongListener>[],
      onOpenMic: onOpenMic,
      onShowcase: onShowcase,
      roomName: 'The Basement',
      roomIcon: '🎸',
    );

Future<void> _openDial(
  WidgetTester tester, {
  required SongAudience audience,
  SongOrigin? origin,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showAudienceSheet(
            context,
            audience: audience,
            songTitle: 'Ladder Of Life',
            origin: origin,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

SongProject _songWith(SongOrigin? origin) {
  final now = DateTime(2026, 9, 17);
  return SongProject(
    id: 'song-x',
    roomId: 'room-1',
    accountId: 'account-1',
    title: 'Ladder Of Life',
    description: 'Somebody else wrote it, we play it.',
    createdAt: now,
    updatedAt: now,
    songOrigin: origin,
    contributions: <Contribution>[
      Contribution(
        id: 'c-1',
        projectId: 'song-x',
        authorId: 'a',
        authorName: 'Taylor',
        body: 'Verse',
        colorValue: 0,
        createdAt: now,
        position: 1,
        kind: ContributionKind.section,
      ),
      Contribution(
        id: 'c-2',
        projectId: 'song-x',
        authorId: 'a',
        authorName: 'Taylor',
        body: 'Streetlights blur like a warning in the rain',
        colorValue: 0,
        createdAt: now,
        position: 2,
      ),
      Contribution(
        id: 'c-3',
        projectId: 'song-x',
        authorId: 'a',
        authorName: 'Taylor',
        body: 'Capo on 2',
        colorValue: 0,
        createdAt: now,
        position: 3,
        kind: ContributionKind.note,
      ),
    ],
  );
}

void main() {
  group('the question is asked once', () {
    testWidgets('the first move out of the room asks, and the next does not',
        (tester) async {
      final controller = await _openSong(tester);
      expect(controller.projectById('song-1')!.songOrigin, isNull);

      await _reachForTheOpenMic(tester);

      // Asked where it means something: on the way out of the room, about
      // the thing they just pressed. Not on a form when the song was made.
      expect(find.text('Who wrote this song?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('whose_song_ours')));
      await _settle(tester);

      // And then the move they actually came for, not instead of it.
      expect(find.text('Put Midnight Signal on the Open Mic?'), findsOneWidget);
      expect(controller.projectById('song-1')!.songOrigin, SongOrigin.ours);
      await tester.tap(find.text('Not yet'));
      await _settle(tester);

      await _reachForTheOpenMic(tester);
      expect(find.text('Who wrote this song?'), findsNothing);
      expect(find.text('Put Midnight Signal on the Open Mic?'), findsOneWidget);
      await tester.tap(find.text('Not yet'));
      await _settle(tester);
    });

    testWidgets('answering somebody else stops the move it was asked before',
        (tester) async {
      final controller = await _openSong(tester);
      await _reachForTheOpenMic(tester);

      await tester.tap(find.byKey(const Key('whose_song_cover')));
      await _settle(tester);

      // The one move that cannot happen, refused in the sentence the dial
      // uses rather than by a dialog that then fails.
      expect(find.text('Put Midnight Signal on the Open Mic?'), findsNothing);
      expect(find.text(whyCoversStayHome), findsOneWidget);
      expect(controller.projectById('song-1')!.songOrigin, SongOrigin.cover);
      expect(
        (await controller.repository.songAudience('song-1'))!.onOpenMic,
        isFalse,
      );
    });

    testWidgets('answering somebody else stops the showcase too',
        (tester) async {
      final controller = await _openSong(tester);
      await _reachForTheShowcase(tester);

      // The same question, asked by the other way out of the room — and the
      // one that publishes furthest. `show_song` (0088) makes a page
      // `public_songs` (0096) serves to anon, so an answer that only
      // governed the Open Mic would let the sheet ask about somebody else's
      // song and then publish it wider than the move it just refused.
      expect(find.text('Who wrote this song?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('whose_song_cover')));
      await _settle(tester);

      expect(find.text('Show Midnight Signal as finished?'), findsNothing);
      expect(find.text(whyCoversStayHome), findsOneWidget);
      expect(controller.projectById('song-1')!.songOrigin, SongOrigin.cover);
    });

    testWidgets('our own finished song is still shown', (tester) async {
      await _openSong(tester);
      await _reachForTheShowcase(tester);

      await tester.tap(find.byKey(const Key('whose_song_ours')));
      await _settle(tester);

      // The gate is about somebody else's song and nothing else. A song the
      // room wrote goes where finished work is played, as before.
      expect(find.text('Show Midnight Signal as finished?'), findsOneWidget);
      expect(find.text(whyCoversStayHome), findsNothing);
      await tester.tap(find.text('Not yet'));
      await _settle(tester);
    });
  });

  group('the dial closes both ways out for somebody else\'s song', () {
    testWidgets('the top of the gradient is closed, with the reason',
        (tester) async {
      await _openDial(
        tester,
        audience: _audience(SongReach.room),
        origin: SongOrigin.cover,
      );

      // The whole gradient still shows, so the closed end is visible as an
      // end rather than missing.
      expect(find.text('Only you'), findsOneWidget);
      expect(find.text('Anyone'), findsOneWidget);
      expect(find.text(whyCoversStayHome), findsOneWidget);
      // Nothing to press. A dead button is a thing to press twice.
      expect(find.byKey(const Key('audience_open_mic_toggle')), findsNothing);
      // Both ways out, not only the Open Mic. This one is the wider of the
      // two, and it sat eleven lines under the sentence above.
      expect(find.byKey(const Key('audience_show_finished')), findsNothing);
      // The way somebody invites a person they chose is untouched, because
      // that is the thing the sentence says still works.
      expect(find.byKey(const Key('audience_invite')), findsOneWidget);
    });

    testWidgets('our own song is still offered both', (tester) async {
      await _openDial(
        tester,
        audience: _audience(SongReach.room),
        origin: SongOrigin.ours,
      );
      expect(find.text('Put it on the Open Mic'), findsOneWidget);
      expect(find.text('It is finished — show it'), findsOneWidget);
      expect(find.text(whyCoversStayHome), findsNothing);
    });

    testWidgets('an unanswered song is offered both', (tester) async {
      await _openDial(tester, audience: _audience(SongReach.room));
      // Null is "nobody has been asked", not "somebody else". Closing the
      // dial before the question is asked would close it for every song in
      // the database, all of which are null today.
      expect(find.text('Put it on the Open Mic'), findsOneWidget);
      expect(find.text('It is finished — show it'), findsOneWidget);
    });

    testWidgets('a cover already up can still come down', (tester) async {
      await _openDial(
        tester,
        audience: _audience(SongReach.anyone, onOpenMic: true),
        origin: SongOrigin.cover,
      );
      // The refusal covers the way up only. Somebody looking at a song that
      // should not be up needs the way down more than anybody.
      expect(find.text('Take it off the Open Mic'), findsOneWidget);
      expect(find.byKey(const Key('audience_show_finished')), findsNothing);
    });

    testWidgets('a cover already on the showcase can still come down',
        (tester) async {
      await _openDial(
        tester,
        audience: _audience(SongReach.anyone, onShowcase: true),
        origin: SongOrigin.cover,
      );
      expect(find.text('Take it off the showcase'), findsOneWidget);
      expect(find.byKey(const Key('audience_open_mic_toggle')), findsNothing);
      // And "Anyone" is not struck through while the song is sitting in it.
      // The strike is about a move being closed, and on this row the dial
      // would otherwise draw the song's own position as unreachable.
      expect(find.text(whyCoversStayHome), findsNothing);
    });
  });

  group('a cover\'s words stay in the room', () {
    test('the export carries the structure and not the lines', () {
      final text = ProjectExportService.songText(_songWith(SongOrigin.cover));
      expect(text, contains('Ladder Of Life'));
      expect(text, contains('VERSE'));
      expect(text, contains('Capo on 2'));
      expect(text, isNot(contains('Streetlights blur')));
      // Said, not silently dropped: an export missing every line reads as
      // the app having lost somebody's work.
      expect(text, contains(ProjectExportService.wordsStayHome));
    });

    test('our own song exports whole, and so does an unanswered one', () {
      for (final origin in <SongOrigin?>[
        null,
        SongOrigin.ours,
        SongOrigin.publicDomain,
      ]) {
        final text = ProjectExportService.songText(_songWith(origin));
        expect(text, contains('Streetlights blur'), reason: '$origin');
        expect(text, isNot(contains(ProjectExportService.wordsStayHome)),
            reason: '$origin');
      }
    });
  });

  group('the origin makes the round trip', () {
    test('the column spelling is the one the enum writes', () {
      expect(SongOrigin.publicDomain.wireName, 'public_domain');
      for (final origin in SongOrigin.values) {
        expect(SongOrigin.fromWireName(origin.wireName), origin);
      }
      // Never asked, and a value shipped by a later migration than this
      // build knows about, both read as never asked rather than throwing.
      expect(SongOrigin.fromWireName(null), isNull);
      expect(SongOrigin.fromWireName('traditional'), isNull);
    });

    test('a song remembers the answer, and a cover comes off the Open Mic',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.putOnOpenMic('song-1');
      expect((await repository.songAudience('song-1'))!.onOpenMic, isTrue);

      await repository.setSongOrigin('song-1', SongOrigin.publicDomain);
      expect(
        (await repository.loadProject('song-1'))!.songOrigin,
        SongOrigin.publicDomain,
      );
      expect((await repository.songAudience('song-1'))!.onOpenMic, isTrue);

      await repository.setSongOrigin('song-1', SongOrigin.cover);
      expect(
        (await repository.loadProject('song-1'))!.songOrigin,
        SongOrigin.cover,
      );
      expect((await repository.songAudience('song-1'))!.onOpenMic, isFalse);
    });
  });
}
