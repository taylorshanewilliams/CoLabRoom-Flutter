import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/sung_in.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/workspace/ask_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Say what you sing in.
///
/// Every Musician, Same Song, 17 September 2026, from the world-traditions
/// research. The languages somebody sings in and the traditions they work in
/// are declared by the person and never inferred, and a word two people both
/// wrote becomes a sentence the Open Mic can say: "Also sings in Portuguese".
/// It is never a filter and never an order. Nobody is hidden by it, nobody
/// is moved by it, and somebody who declares nothing is exactly where they
/// were.
///
/// Asks carry it too, as one free line ("Sa = C#, Rupak, Hindi"), so
/// somebody answering knows what they are joining.
const String _theLine = 'Sa = C#, Rupak, Hindi';

/// About sixty characters as a person counts them, which is how the ask
/// sheet's field counts them, and about a hundred and forty as Postgres
/// does. A column checked at eighty code points refused a line like this
/// and lost the whole ask.
final String _inDevanagari = List<String>.filled(20, 'हिन्दी').join(' ');

/// Notes what the ask bar sent, and otherwise is the seeded preview.
class _Asking extends InMemoryMusicRepository {
  _Asking() : super.from(InMemoryMusicRepository.seeded());

  final List<String> sent = <String>[];

  @override
  Future<SongAsk> askFor({
    required String projectId,
    String? part,
    String note = '',
    AskTerms terms = AskTerms.play,
    String sungIn = '',
  }) async {
    sent.add(sungIn);
    return super.askFor(
        projectId: projectId,
        part: part,
        note: note,
        terms: terms,
        sungIn: sungIn);
  }
}

/// An inbox with one ask in it, which may or may not say what it is in.
class _Asked extends InMemoryMusicRepository {
  _Asked(this.sungIn) : super.from(InMemoryMusicRepository.seeded());

  final String sungIn;

  @override
  Future<List<AskForMe>> asksForMe() async => <AskForMe>[
        AskForMe(
          id: 'ask-1',
          projectId: 'preview-project-1',
          songTitle: 'Ladder Of Life',
          askedByName: 'Mara Ellison',
          askedById: 'preview-mara',
          part: 'vocal',
          createdAt: DateTime(2026, 9, 17),
          sungIn: sungIn,
        ),
      ];
}

Future<void> _pumpAWhile(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _openProfile(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  String? profileId,
  Musician? initial,
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: MusicianProfileScreen(
      profileId: profileId ?? repository.currentUserId,
      repository: repository,
      initial: initial,
    ),
  ));
  await _pumpAWhile(tester);
}

/// Scrolls the page until [finder] is built. The profile is a lazy list, so
/// a section below the fold does not exist yet as far as `find` can tell.
Future<Finder> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return finder;
  await tester.scrollUntilVisible(
    finder,
    220,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 16,
  );
  await tester.pump(const Duration(milliseconds: 60));
  return finder;
}

Future<void> _openInbox(WidgetTester tester, String sungIn) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(_Asked(sungIn));
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: const NotificationsScreen(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('one spelling for one word', () {
    test('what people type folds to the word that is kept', () {
      expect(sungInWord('Português'), 'portuguese');
      expect(sungInWord('  PORTUGUESE '), 'portuguese');
      expect(sungInWord('Español'), 'spanish');
      expect(sungInWord('Hindustani   Classical'), 'hindustani');
      expect(sungInWord('Karnatic'), 'carnatic');
      // Anything the table has never heard of is kept as it was typed, only
      // lower-cased and single-spaced. The list is not a vocabulary.
      expect(sungInWord('Yorùbá'), 'yorùbá');
      expect(sungInWord('qawwali'), 'qawwali');
    });

    test('a variety somebody wrote is theirs, and is kept', () {
      // Spellings fold. "Brazilian Portuguese" is not a spelling of
      // "Portuguese": the person meant it, and it stays.
      expect(sungInWord('Brazilian Portuguese'), 'brazilian portuguese');
    });

    test('white space of any kind around a word is not part of it', () {
      // Pasted, with a tab in front and a line end behind. The server
      // collapses before it trims for the same reason (0156): a word kept
      // as " portuguese" never matches anybody's.
      expect(sungInWord('\tPortuguês\n'), 'portuguese');
      expect(sungInWord('north\tindian\n classical'), 'hindustani');
      expect(sungInWord(' \n\t '), '');
    });

    test('a kept word folds to itself', () {
      for (final word in <String>['portuguese', 'hindustani', 'carnatic']) {
        expect(sungInWord(word), word);
      }
    });

    test('a kept word is read with its first letter up', () {
      expect(sungInShown('portuguese'), 'Portuguese');
      expect(sungInShown('brazilian portuguese'), 'Brazilian portuguese');
      expect(sungInShown('   '), '');
    });
  });

  group('declaring', () {
    test('it is kept folded, once each, in the order chosen, five at most',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      expect((await repository.loadMusician(repository.currentUserId))!.singsIn,
          isEmpty);

      await repository.setOpenMicPresence(
        discoverable: false,
        singsIn: <String>[
          'Português',
          'portuguese',
          ' Hindi ',
          'Carnatic classical',
          'fado',
          'Yorùbá',
          'English',
          'Urdu',
        ],
      );
      final me = await repository.loadMusician(repository.currentUserId);
      expect(me!.singsIn,
          <String>['portuguese', 'hindi', 'carnatic', 'fado', 'yorùbá']);
    });

    test('a save that does not mention it leaves it alone', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Hindi']);
      // What the first-run tour sends, and what editing a bio sends: neither
      // knows about this field, and neither may clear it.
      await repository.setOpenMicPresence(
          discoverable: true, soundsLike: <String>['folk']);
      await repository.setBio('Sing mostly.');
      await repository.claimPart('bass');

      final me = await repository.loadMusician(repository.currentUserId);
      expect(me!.singsIn, <String>['hindi']);
      expect(me.soundsLike, <String>['folk']);
    });

    test('it can be taken off again', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Hindi']);
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: const <String>[]);
      expect((await repository.loadMusician(repository.currentUserId))!.singsIn,
          isEmpty);
    });

    testWidgets('somebody types it in Open Mic settings and it is on their page',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await _openProfile(tester, repository);

      await tester.tap(find.byTooltip('Open Mic settings'));
      await _pumpAWhile(tester);
      expect(tester.takeException(), isNull);

      // Typed, never picked. Nothing is offered until they say it: a row of
      // suggested languages would be a choice about which languages count.
      final field = find.byKey(const Key('sings_in_field'));
      await tester.ensureVisible(field);
      await tester.pump();
      expect(find.text('What you sing in'.toUpperCase()), findsOneWidget);
      expect(find.byKey(const Key('sings_in_chip_portuguese')), findsNothing);

      await tester.enterText(field, 'Português');
      await tester.tap(find.byKey(const Key('sings_in_add')));
      await tester.pump();

      // Folded to the word that is kept, and read with its first letter up.
      expect(find.byKey(const Key('sings_in_chip_portuguese')), findsOneWidget);
      expect(find.text('Portuguese'), findsOneWidget);

      // The same word again is the same word.
      await tester.enterText(field, 'portuguese');
      await tester.tap(find.byKey(const Key('sings_in_add')));
      await tester.pump();
      expect(find.byKey(const Key('sings_in_chip_portuguese')), findsOneWidget);

      await tester.ensureVisible(find.text('Save'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await _pumpAWhile(tester);

      final me = await repository.loadMusician(repository.currentUserId);
      expect(me!.singsIn, <String>['portuguese']);

      expect(await _reveal(tester, find.text('SINGS IN')), findsOneWidget);
      expect(find.byKey(const Key('profile_sings_in')), findsOneWidget);
      expect(find.text('Portuguese'), findsOneWidget);
    });

    test('white space alone is not a word', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>[' \n ', '\tHindi\n', '']);
      expect((await repository.loadMusician(repository.currentUserId))!.singsIn,
          <String>['hindi']);
    });

    testWidgets('a word typed and never added is still kept by Save',
        (tester) async {
      // There are no chips to tap under "What you sing in", on purpose, so
      // typing and then Save is the likeliest way through it. The sheet used
      // to close, the save used to succeed, and nothing was kept.
      final repository = InMemoryMusicRepository.seeded();
      await _openProfile(tester, repository);

      await tester.tap(find.byTooltip('Open Mic settings'));
      await _pumpAWhile(tester);

      final field = find.byKey(const Key('sings_in_field'));
      await tester.ensureVisible(field);
      await tester.pump();
      await tester.enterText(field, 'Português');

      final save = find.byKey(const Key('presence_save'));
      await tester.ensureVisible(save);
      await tester.pump();
      await tester.tap(save);
      await _pumpAWhile(tester);
      expect(tester.takeException(), isNull);

      final me = await repository.loadMusician(repository.currentUserId);
      expect(me!.singsIn, <String>['portuguese']);
      expect(await _reveal(tester, find.text('SINGS IN')), findsOneWidget);
      expect(find.text('Portuguese'), findsOneWidget);
    });

    testWidgets('an empty field adds nothing when Save is tapped',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final before = await repository.loadMusician(repository.currentUserId);
      await _openProfile(tester, repository);

      await tester.tap(find.byTooltip('Open Mic settings'));
      await _pumpAWhile(tester);
      final save = find.byKey(const Key('presence_save'));
      await tester.ensureVisible(save);
      await tester.pump();
      await tester.tap(save);
      await _pumpAWhile(tester);

      final me = await repository.loadMusician(repository.currentUserId);
      expect(me!.singsIn, isEmpty);
      expect(me.soundsLike, before!.soundsLike);
      expect(me.plays, before.plays);
    });

    testWidgets('a page says it in their words and their order',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      // Dev wrote two down. The page reads them back in his order.
      await _openProfile(tester, repository, profileId: 'preview-dev');
      expect(await _reveal(tester, find.text('SINGS IN')), findsOneWidget);
      expect(find.text('Portuguese · English'), findsOneWidget);
    });

    testWidgets('somebody who has not said has no empty section to apologise '
        'for', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await _openProfile(tester, repository, profileId: 'preview-mara');
      await _reveal(tester, find.text('ALSO PLAYS'));
      expect(find.text('SINGS IN'), findsNothing);
      expect(find.byKey(const Key('profile_sings_in')), findsNothing);
    });
  });

  group('the reason line', () {
    test('says the sentence the feed says', () {
      expect(alsoSingsIn('portuguese'), 'Also sings in Portuguese');
      expect(alsoSingsIn('Português'), 'Also sings in Portuguese');
      expect(alsoSingsIn(''), '');
    });

    test('a word you both wrote is said on their song', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Português']);

      final feed = await repository.openMicFeed();
      final kitchen = feed.firstWhere((t) => t.id == 'preview-open-2');
      expect(kitchen.reason, 'Also sings in Portuguese');
    });

    test('a song that needs you still says that first', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Portuguese', 'English']);
      final feed = await repository.openMicFeed();
      expect(feed.first.reason, 'Needs a bass');
    });

    test('a word nobody else wrote changes nothing', () async {
      final repository = InMemoryMusicRepository.seeded();
      final before = await repository.openMicFeed();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Zulu']);
      final after = await repository.openMicFeed();
      expect(after.map((t) => t.reason), before.map((t) => t.reason));
    });
  });

  group('never a filter', () {
    test('with nothing declared the feed is the feed it always was', () async {
      final repository = InMemoryMusicRepository.seeded();
      final feed = await repository.openMicFeed();
      expect(feed.map((t) => t.id),
          <String>['preview-open-1', 'preview-open-2']);
      expect(feed.map((t) => t.reason),
          <String>['Needs a bass', 'Nothing like what you play']);
    });

    test('declaring moves nobody and hides nobody', () async {
      final repository = InMemoryMusicRepository.seeded();
      final before = await repository.openMicFeed();
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Portuguese']);
      final after = await repository.openMicFeed();

      // Mara declared nothing. Her song is where it was, saying what it said.
      expect(after.map((t) => t.id), before.map((t) => t.id));
      expect(after.first.ownerId, 'preview-mara');
      expect(after.first.reason, before.first.reason);

      // And narrowing to a part is still only about the part.
      final harmony = await repository.openMicFeed(part: 'harmony');
      expect(harmony.map((t) => t.id), <String>['preview-open-2']);
    });
  });

  group('an ask says what it is in', () {
    test('as the asker typed it, and nothing when they did not', () async {
      final repository = InMemoryMusicRepository.seeded();
      final said = await repository.askFor(
        projectId: 'preview-project-1',
        part: 'tabla',
        sungIn: '  $_theLine ',
      );
      expect(said.sungIn, _theLine);
      // Whatever else happens to the ask, the line goes with it.
      expect(said.copyWith(closed: true).sungIn, _theLine);
      expect(said.copyWith(opinionsOpened: true).sungIn, _theLine);

      // Never filled in for them: not from the song, and not from a profile
      // that has declared a language.
      await repository.setOpenMicPresence(
          discoverable: false, singsIn: <String>['Hindi']);
      final silent = await repository.askFor(
          projectId: 'preview-project-1', part: 'bass');
      expect(silent.sungIn, isEmpty);
      expect(
        AskForMe(
          id: 'a',
          projectId: 's',
          songTitle: 'T',
          askedByName: 'D',
          createdAt: DateTime(2026, 9, 17),
        ).sungIn,
        isEmpty,
      );
      expect(
        FeedTrack(
          id: 'f',
          title: 'T',
          ownerName: 'D',
          storagePath: 'p',
          putUpAt: DateTime(2026, 9, 17),
        ).askSungIn,
        isEmpty,
      );
    });

    test('a line in Devanagari is kept whole', () async {
      // The field stops at eighty written characters and the column counts
      // code points, which in this script is two or three times as many.
      expect(_inDevanagari.characters.length,
          lessThanOrEqualTo(sungInLineLength));
      expect(_inDevanagari.runes.length, greaterThan(sungInLineLength));
      expect(_inDevanagari.runes.length,
          lessThanOrEqualTo(sungInLineCodePoints));
      expect(sungInLine('  $_inDevanagari '), _inDevanagari);

      final repository = InMemoryMusicRepository.seeded();
      final said = await repository.askFor(
        projectId: 'preview-project-1',
        part: 'tabla',
        sungIn: _inDevanagari,
      );
      expect(said.sungIn, _inDevanagari);
    });

    test('a line longer than the column is cut, never refused', () {
      // Eighty of a character that is seven code points each: the field
      // takes it and the column cannot. It is cut to what the column holds,
      // between code points and never inside a pair, and the ask still goes.
      final family = String.fromCharCodes(<int>[
        0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466,
      ]);
      final long = List<String>.filled(sungInLineLength, family).join();
      expect(long.characters.length, sungInLineLength);

      final sent = sungInLine(long);
      expect(sent.runes.length, lessThanOrEqualTo(sungInLineCodePoints));
      expect(sent, isNotEmpty);
      expect(long.startsWith(sent), isTrue);
      // Half of a surrogate pair reads back as a code point of its own, in
      // the range no whole character lives in.
      expect(sent.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);

      // And an ordinary line is only trimmed.
      expect(sungInLine('  $_theLine '), _theLine);
      expect(sungInLine('   '), '');
    });

    testWidgets('a bandmate reads the line where they answer the ask',
        (tester) async {
      // The room's own ask, on a song that is not on the Open Mic. The
      // thread is where somebody in the room reads an ask before answering
      // it, and it is the only place this line is read at all.
      final repository = InMemoryMusicRepository.seeded();
      final ask = await repository.askFor(
          projectId: 'song-1', part: 'tabla', sungIn: _theLine);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AskBar(projectId: 'song-1', repository: repository),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('ask_chip_${ask.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask_thread_headline')), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_detail')), findsOneWidget);
      expect(find.text(_theLine), findsOneWidget);
    });

    testWidgets('an ask that did not say has no empty line in its thread',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final ask = await repository.askFor(projectId: 'song-1', part: 'drums');

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AskBar(projectId: 'song-1', repository: repository),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('ask_chip_${ask.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask_thread_headline')), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_detail')), findsNothing);
    });

    testWidgets('the person asked reads it in the thread as well as the card',
        (tester) async {
      await _openInbox(tester, _theLine);
      await tester.tap(find.byKey(const Key('ask_card_reply')).first);
      await _pumpAWhile(tester);
      expect(find.byKey(const Key('ask_thread_detail')), findsOneWidget);
    });

    testWidgets('the room\'s ask carries the line typed above the parts',
        (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = _Asking();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AskBar(projectId: 'preview-project-1', repository: repository),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Ask the room'));
      await tester.pumpAndSettle();

      // Above the parts, because tapping a part sends the ask.
      final line = find.byKey(const Key('ask_sung_in'));
      expect(line, findsOneWidget);
      expect(tester.getTopLeft(line).dy,
          lessThan(tester.getTopLeft(find.text('Keys')).dy));

      await tester.enterText(line, _theLine);
      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();

      expect(repository.sent, <String>[_theLine]);
      final asks = await repository.loadAsks('preview-project-1');
      expect(asks.single.sungIn, _theLine);
    });

    testWidgets('an ask that does not say is still one tap', (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = _Asking();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AskBar(projectId: 'preview-project-1', repository: repository),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Ask the room'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();

      expect(repository.sent, <String>['']);
    });

    testWidgets('the person asked reads it before they answer', (tester) async {
      await _openInbox(tester, _theLine);
      expect(find.byKey(const Key('ask_card_sung_in')), findsOneWidget);
      expect(find.text(_theLine), findsOneWidget);
    });

    testWidgets('an ask that did not say shows no empty line', (tester) async {
      await _openInbox(tester, '');
      expect(find.text('Mara Ellison asked you to play vocal on Ladder Of Life'),
          findsOneWidget);
      expect(find.byKey(const Key('ask_card_sung_in')), findsNothing);
    });
  });
}
