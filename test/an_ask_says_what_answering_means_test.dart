import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/workspace/ask_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An ask says whether answering means playing or writing.
///
/// Every Musician, Same Song, 17 September 2026: co-writing fights are two
/// honest memories of a session nobody wrote down. Somebody plays a line into
/// a stranger's chorus, the song gets used, and a year later one of them
/// remembers a favour and the other remembers a co-write. Neither is lying.
/// The disagreement was made the moment the ask was sent, because the ask
/// never said what answering it meant.
///
/// Playing is the default and shows nothing. Writing shows one sentence, in
/// the same words, everywhere the ask is read.
const String _theLine = "Writing on it: if your part is used, you're a writer.";

AskForMe _asked({AskTerms terms = AskTerms.play}) => AskForMe(
      id: 'ask-1',
      projectId: 'preview-project-1',
      songTitle: 'Ladder Of Life',
      askedByName: 'Mara Ellison',
      askedById: 'preview-mara',
      part: 'bass',
      createdAt: DateTime(2026, 9, 17),
      terms: terms,
    );

class _Asked extends InMemoryMusicRepository {
  _Asked(this.terms) : super.from(InMemoryMusicRepository.seeded());

  final AskTerms terms;

  @override
  Future<List<AskForMe>> asksForMe() async => <AskForMe>[_asked(terms: terms)];
}

/// A song with one open ask on it, and a note of what the bar asked for.
class _Asking extends InMemoryMusicRepository {
  _Asking(this.terms) : super.from(InMemoryMusicRepository.seeded());

  final AskTerms terms;
  final List<AskTerms> sent = <AskTerms>[];

  @override
  Future<List<SongAsk>> loadAsks(String projectId) async => <SongAsk>[
        SongAsk(
          id: 'ask-1',
          projectId: projectId,
          askedBy: currentUserId,
          createdAt: DateTime(2026, 9, 17),
          part: 'bass',
          terms: terms,
        ),
      ];

  @override
  Future<SongAsk> askFor({
    required String projectId,
    String? part,
    String note = '',
    AskTerms terms = AskTerms.play,
    String sungIn = '',
  }) async {
    sent.add(terms);
    return super.askFor(
        projectId: projectId,
        part: part,
        note: note,
        terms: terms,
        sungIn: sungIn);
  }
}

/// A song asking for two different things on two different terms.
///
/// This is allowed: 0049 forbids only two open asks for the same part, so a
/// song can want bass played and a topline written at the same time.
class _AskingTwoWays extends InMemoryMusicRepository {
  _AskingTwoWays() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<SongAsk>> loadAsks(String projectId) async => <SongAsk>[
        SongAsk(
          id: 'play',
          projectId: projectId,
          askedBy: currentUserId,
          createdAt: DateTime(2026, 9, 17),
          part: 'bass',
        ),
        SongAsk(
          id: 'write',
          projectId: projectId,
          askedBy: currentUserId,
          createdAt: DateTime(2026, 9, 17),
          part: 'a topline',
          terms: AskTerms.write,
        ),
      ];
}

Future<void> _openInbox(WidgetTester tester, AskTerms terms) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(_Asked(terms));
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

Future<_Asking> _openSongBar(WidgetTester tester, AskTerms terms) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final repository = _Asking(terms);
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: AskBar(projectId: 'preview-project-1', repository: repository),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 500));
  return repository;
}

void main() {
  test('playing is what an ask means unless somebody says otherwise', () {
    expect(_asked().terms, AskTerms.play);
    expect(
      SongAsk(
        id: 'a',
        projectId: 's',
        askedBy: 'me',
        createdAt: DateTime(2026, 9, 17),
      ).terms,
      AskTerms.play,
    );
    // Anything the app does not recognise is playing, which is what every ask
    // made before the column existed was.
    expect(AskTerms.fromWireName(null), AskTerms.play);
    expect(AskTerms.fromWireName('play'), AskTerms.play);
    expect(AskTerms.fromWireName('something else'), AskTerms.play);
    expect(AskTerms.fromWireName('write'), AskTerms.write);
  });

  test('playing says nothing, and writing says one sentence', () {
    expect(AskTerms.play.notice, isNull);
    expect(AskTerms.write.notice, _theLine);
  });

  testWidgets('an ask to play on it shows nothing extra to the person asked',
      (tester) async {
    await _openInbox(tester, AskTerms.play);
    expect(find.text('Mara Ellison asked you to play bass on Ladder Of Life'),
        findsOneWidget);
    expect(find.byKey(const Key('ask_card_terms')), findsNothing);
    expect(find.textContaining('writer'), findsNothing);
  });

  testWidgets('an ask to write on it says so on the card, before answering',
      (tester) async {
    await _openInbox(tester, AskTerms.write);
    expect(find.byKey(const Key('ask_card_terms')), findsOneWidget);
    expect(find.text(_theLine), findsOneWidget);
  });

  testWidgets('an ask to play on it says nothing on the song either',
      (tester) async {
    await _openSongBar(tester, AskTerms.play);
    expect(find.text('needs bass'), findsOneWidget);
    expect(find.byKey(const Key('ask_chip_writing_ask-1')), findsNothing);
    expect(find.byKey(const Key('ask_bar_writing_terms')), findsNothing);
  });

  testWidgets('the song says it too when it is a writing ask', (tester) async {
    await _openSongBar(tester, AskTerms.write);
    expect(find.text('needs bass'), findsOneWidget);
    expect(find.byKey(const Key('ask_chip_writing_ask-1')), findsOneWidget);
    expect(find.byKey(const Key('ask_bar_writing_terms')), findsOneWidget);
    expect(find.text(_theLine), findsOneWidget);
  });

  testWidgets('a song asking two ways says which ask the writing one is',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body:
            AskBar(projectId: 'preview-project-1', repository: _AskingTwoWays()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    // The sentence is said once, but it cannot be read as covering the bass.
    // Somebody who records bass here must not walk away believing they are a
    // writer on the song -- that is the argument this slice exists to
    // prevent, and the bar is where it would be made.
    expect(find.text('needs bass'), findsOneWidget);
    expect(find.text('needs a topline'), findsOneWidget);
    expect(find.byKey(const Key('ask_chip_writing_write')), findsOneWidget);
    expect(find.byKey(const Key('ask_chip_writing_play')), findsNothing);
    expect(find.text(_theLine), findsOneWidget);
  });

  testWidgets('the asker picks, playing is already picked, and they read it '
      'before they send it', (tester) async {
    final repository = await _openSongBar(tester, AskTerms.play);

    await tester.tap(find.text('Ask for something else'));
    await tester.pumpAndSettle();

    // Both offered, playing chosen, and nothing said about it.
    expect(find.text('Play on it'), findsOneWidget);
    expect(find.text('Write on it'), findsOneWidget);
    expect(find.byKey(const Key('ask_terms_notice')), findsNothing);

    // The sentence appears the moment it is chosen, so nobody sends words
    // they have not seen.
    await tester.tap(find.text('Write on it'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ask_terms_notice')), findsOneWidget);
    expect(find.text(_theLine), findsOneWidget);

    // And the part that gets tapped carries it.
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();
    expect(repository.sent, <AskTerms>[AskTerms.write]);
  });

  test('what an ask means does not change after it has gone', () async {
    final repository = InMemoryMusicRepository.seeded();
    final posted = await repository.askFor(
      projectId: 'preview-project-1',
      part: 'bass',
      terms: AskTerms.write,
    );
    expect(posted.terms, AskTerms.write);

    // Everything the app can still do to an ask leaves the terms alone.
    // copyWith takes no terms — 0145 refuses the update in the database, and
    // a model that could hand back a different answer would be the argument
    // again with an audit trail.
    expect(posted.copyWith(opinionsOpened: true).terms, AskTerms.write);
    expect(posted.copyWith(closed: true).terms, AskTerms.write);

    final open = await repository.loadAsks('preview-project-1');
    expect(open.single.terms, AskTerms.write);
  });
}
