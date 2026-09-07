import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a profile is allowed to say about somebody.
///
/// The design rests on one rule: a record, a declaration and a link are three
/// different things and the page never averages them. That is easy to write
/// and easy to lose — a later tidy-up that merges "played here" and "also
/// plays" into one list of instruments would look like a simplification and
/// would quietly turn a counted fact into a claim. These tests are what makes
/// that a failure rather than a refactor.
///
/// It also mounts the screen at the size and text scale the layout suite uses,
/// because a new screen with two bottom sheets on it is exactly where an
/// overflow goes unnoticed.
Future<void> _boot(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(360, 690),
  double textScale = 1.3,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: screen,
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Scrolls until [finder] exists, then returns it.
///
/// The profile is a lazy ListView, so a section below the fold is not merely
/// out of view — it has not been built and is invisible to `find`, and to
/// anything else looking, including a screen reader. Three assertions in this
/// file have failed that way; scrolling is what a person does and what a test
/// has to do too.
Future<Finder> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return finder;
  await tester.scrollUntilVisible(finder, 220, maxScrolls: 12);
  await tester.pump(const Duration(milliseconds: 60));
  return finder;
}

void main() {
  testWidgets('somebody else’s page separates the record from the claim',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    const mara = Musician(
      id: 'preview-mara',
      displayName: 'Mara Ellison',
      city: 'Glasgow',
      plays: <String>['vocal', 'harmony'],
      partsRecorded: <String, int>{'vocal': 9, 'harmony': 4},
      songsPlayedOn: 7,
      peopleWorkedWith: 5,
    );

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: mara.id,
        repository: repository,
        initial: mara,
      ),
    );
    expect(tester.takeException(), isNull, reason: 'the profile did not draw');

    // Two sections, two different promises, both said out loud. The notes are
    // the whole design: a number nobody can inflate, beside a list anybody can
    // write, and the page saying which is which.
    expect(find.text('PLAYED HERE'), findsOneWidget);
    expect(find.text('counted, not claimed'), findsOneWidget);
    expect(await _reveal(tester, find.text('ALSO PLAYS')), findsOneWidget);
    expect(find.text('their own words'), findsOneWidget);

    // The count is shown per part rather than as a single score, because
    // "vocal · 9" is a fact somebody can check and a rating is not.
    expect(find.text('vocal · 9'), findsOneWidget);
    expect(find.text('7 songs · with 5 people'), findsOneWidget);
  });

  testWidgets('a link is shown with where it goes, and is never counted',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    const dev = Musician(
      id: 'preview-dev',
      displayName: 'Dev Okonjo',
      plays: <String>['drums'],
      partsRecorded: <String, int>{'drums': 12},
      songsPlayedOn: 11,
      peopleWorkedWith: 6,
    );

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: dev.id,
        repository: repository,
        initial: dev,
      ),
    );
    expect(tester.takeException(), isNull);

    // Said out loud because tapping one leaves the app. A row that showed only
    // a title would be a link to an unnamed destination under somebody's name.
    expect(await _reveal(tester, find.text('Spotify')), findsOneWidget);
    expect(find.text('Ladder Of Life'), findsOneWidget);
    expect(find.text('linked, not hosted'), findsOneWidget);

    // And it stays out of the record. Two links sit on this profile and the
    // counted line still names songs and people only — a showcase never adds
    // to a number, which is the point of keeping the two sections apart.
    expect(find.text('11 songs · with 6 people'), findsOneWidget);
  });

  testWidgets('your own page tells you nobody can see it', (tester) async {
    final repository = InMemoryMusicRepository.seeded();

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: repository.currentUserId,
        repository: repository,
      ),
    );
    expect(tester.takeException(), isNull, reason: 'your own profile did not draw');

    // The preview account is not discoverable, which is the default for
    // everybody. Somebody who does not know they are invisible concludes the
    // feature is broken, so the page says so before they have to wonder.
    expect(find.text('Only you can see this page'), findsOneWidget);
    expect(find.text('Open Mic settings'), findsWidgets);
  });

  testWidgets('the settings sheet draws at the largest text this app allows',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: repository.currentUserId,
        repository: repository,
      ),
    );

    await tester.tap(find.byTooltip('Open Mic settings'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull,
        reason: 'the Open Mic settings sheet did not draw');

    expect(find.text('List me in Open Mic'), findsOneWidget);
    // The three location settings are the part somebody has to understand
    // before they answer, so each says what it means rather than only naming
    // itself.
    expect(find.text('Keep it to myself'), findsOneWidget);
    expect(find.text('People I have made something with'), findsOneWidget);
    expect(find.text('Anybody in Open Mic'), findsOneWidget);
  });

  testWidgets('a stranger can be asked, and is told what it costs them',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    const mara = Musician(
      id: 'preview-mara',
      displayName: 'Mara Ellison',
      city: 'Glasgow',
      plays: <String>['vocal', 'harmony'],
      partsRecorded: <String, int>{'vocal': 9, 'harmony': 4},
      songsPlayedOn: 7,
      peopleWorkedWith: 5,
    );

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: mara.id,
        repository: repository,
        initial: mara,
      ),
    );

    // The verb this page did not have. Open Mic could find you a bass player
    // and then the app stopped.
    expect(find.text('Ask them to play on…'), findsOneWidget);
    // Two doors, deliberately different sizes: one song to meet somebody,
    // a whole room once you know them. The small one is the loud one.
    expect(find.text('Invite to a room'), findsOneWidget);
    // Said before the tap, because somebody about to contact a stranger about
    // an unfinished song wants to know what it costs them.
    expect(
      find.text('Either way, they hear about it and nothing of yours opens '
          'up unless they say yes.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Ask them to play on…'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull,
        reason: 'the ask sheet did not draw');

    expect(find.text('Ask Mara Ellison'), findsWidgets);
    expect(find.text('WHICH SONG'), findsOneWidget);
    expect(find.text('Midnight Signal'), findsOneWidget);

    // A song this person already has an open ask about is shown and disabled,
    // not hidden — a row quietly missing is somebody wondering where their
    // song went.
    expect(find.text('already asked'), findsOneWidget);

    // Naming a part is optional on purpose: not knowing what a song needs is
    // the normal case, and often the reason for asking at all.
    expect(find.text('optional'), findsWidgets);
    expect(
      find.text('Leave it blank if you would rather hear what they think '
          'it needs.'),
      findsOneWidget,
    );
  });

  testWidgets('a profile shows songs you can actually play', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    const mara = Musician(
      id: 'preview-mara',
      displayName: 'Mara Ellison',
      plays: <String>['vocal', 'harmony'],
      partsRecorded: <String, int>{'vocal': 9, 'harmony': 4},
      songsPlayedOn: 7,
      peopleWorkedWith: 5,
    );

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: mara.id,
        repository: repository,
        initial: mara,
      ),
    );
    expect(tester.takeException(), isNull);

    // The half the profile has been missing since the day it was built: a
    // counted part is evidence, a link is a claim, and a song is the sound —
    // which is what a musician was trying to judge all along.
    expect(await _reveal(tester, find.text('LISTEN')), findsOneWidget);
    expect(find.text('Ladder Of Life'), findsWidgets);

    // Owned and played-on read differently on purpose. Listing somebody
    // else's song without saying which part you played would be claiming it.
    expect(find.textContaining('Their song'), findsOneWidget);
    expect(
      await _reveal(
          tester, find.textContaining("Played harmony on Dev Okonjo's song")),
      findsOneWidget,
      reason: 'a song they only played on was shown as if it were theirs',
    );
  });

  testWidgets('your own page has neither door on it', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: repository.currentUserId,
        repository: repository,
      ),
    );
    expect(find.text('Ask them to play on…'), findsNothing);
    expect(find.text('Invite to a room'), findsNothing);
  });

  testWidgets('a room invitation says how big it is before you send it',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    const mara = Musician(
      id: 'preview-mara',
      displayName: 'Mara Ellison',
      plays: <String>['vocal'],
      partsRecorded: <String, int>{'vocal': 9},
      songsPlayedOn: 7,
      peopleWorkedWith: 5,
    );

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: mara.id,
        repository: repository,
        initial: mara,
      ),
    );

    await tester.tap(find.text('Invite to a room'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull,
        reason: 'the invite sheet did not draw');

    // The difference from an ask, stated before the choice rather than
    // discovered after it. This is the sheet where somebody hands over a
    // library rather than a track.
    expect(
      find.text('A room is everything in it, now and later. If you only '
          'want them on one song, ask them to play on it instead.'),
      findsOneWidget,
    );
    expect(find.text('WHICH ROOM'), findsOneWidget);
  });

  group('the preview refuses exactly what the server refuses', () {
    test('a host on the list is accepted', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.addShowcaseLink(
        url: 'https://soundcloud.com/somebody/a-song',
        title: 'A song',
      );
      final links = await repository.loadShowcase(repository.currentUserId);
      expect(links.last.platform, 'SoundCloud');
    });

    test('a host that merely mentions one is not', () async {
      final repository = InMemoryMusicRepository.seeded();
      // The reason `private.link_platform` matches on the host and not on the
      // URL: a profile is a page that renders a stranger's link under a
      // musician's name, and this is the shape every phishing link takes.
      await expectLater(
        repository.addShowcaseLink(
            url: 'https://evil.example/open.spotify.com/track/1'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repository.addShowcaseLink(
            url: 'https://open.spotify.com@evil.example/track/1'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repository.addShowcaseLink(url: 'http://soundcloud.com/somebody/song'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('turning yourself on is one call, and can be turned off again',
      () async {
    final repository = InMemoryMusicRepository.seeded();

    await repository.setOpenMicPresence(
      discoverable: true,
      city: 'Glasgow',
      locationVisibility: 'public',
      plays: <String>['bass'],
    );
    var me = await repository.loadMusician(repository.currentUserId);
    expect(me!.discoverable, isTrue);
    expect(me.city, 'Glasgow');
    expect(me.plays, <String>['bass']);

    // A setting you can turn on and not off is not a setting. An empty city
    // removes it; a null one would have left it alone.
    await repository.setOpenMicPresence(discoverable: false, city: '');
    me = await repository.loadMusician(repository.currentUserId);
    expect(me!.discoverable, isFalse);
    expect(me.city, isNull);
  });
}
