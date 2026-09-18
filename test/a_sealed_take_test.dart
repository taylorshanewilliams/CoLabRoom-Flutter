import 'dart:async';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/sealed_take.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/sealing_a_take.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/take_lane.dart';
import 'package:colabroom/features/songs/sealed_take_card.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Seal a take for later.
///
/// Every Musician, Same Song, 17 September 2026, from the big swings worth
/// keeping, kept small: "A year ago tonight you sealed this. Play it now?"
/// Somebody records an idea and seals it. Sealing hides it: it is not among
/// the song's takes until its day. The day brings it back once, as one quiet
/// card. And "Not now" is final: the card does not come again, nothing is
/// counted, and the take is simply back among their takes.

/// The evening somebody sealed an idea, and the same evening a year on.
final DateTime _sealedOn = DateTime(2025, 9, 18, 21, 40);
final DateTime _theDay = DateTime(2026, 9, 18, 21, 40);

/// A repository with one draft on Midnight Signal that nobody has heard,
/// and its id.
(InMemoryMusicRepository, String) _withADraft() {
  final repository = InMemoryMusicRepository.seeded()..clock = () => _sealedOn;
  final id = repository.recordTake('song-1', part: 'vocal', shared: false);
  return (repository, id);
}

/// The same, sealed a year ago tonight, with the clock moved to tonight.
Future<(InMemoryMusicRepository, String)> _sealedAYearAgoTonight() async {
  final (repository, id) = _withADraft();
  await repository.sealTake(id, until: aYearOn(_sealedOn));
  repository.clock = () => _theDay;
  return (repository, id);
}

/// The takes list, which is SongLayerService's and not the repository's. It
/// leaves out what the database would not hand back: a take that is put
/// away.
class _TakesOf extends SongLayerService {
  _TakesOf(this.repository, this.layers) : super(client: null);

  final InMemoryMusicRepository repository;
  final List<SharedLayer> layers;

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => <SharedLayer>[
        for (final layer in layers)
          if (!repository.isPutAway(layer.id)) layer,
      ];

  @override
  Future<String> ensureLocal(SharedLayer layer) async => '/tmp/${layer.id}.m4a';

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _NoAnalysis extends SongAnalysisService {
  _NoAnalysis() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
}

SharedLayer _mine(String id, {String label = 'Bridge idea', bool shared = false}) {
  return SharedLayer(
    id: id,
    projectId: 'song-1',
    recordedBy: 'preview-user',
    storagePath: 'room-1/song-1/layers/$id.m4a',
    label: label,
    part: TakePart.vocal,
    durationMs: 42000,
    createdAt: _sealedOn,
    sharedAt: shared ? _sealedOn : null,
  );
}

Future<MusicBetaController> _openTakes(
  WidgetTester tester,
  InMemoryMusicRepository repository,
  List<SharedLayer> layers,
) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongLayersScreen(
        roomId: 'room-1',
        projectId: 'song-1',
        songTitle: 'Midnight Signal',
        layerService: _TakesOf(repository, layers),
        analysisService: _NoAnalysis(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return controller;
}

Future<MusicBetaController> _openHome(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  Future<bool> Function(SealedTake take)? hear,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await SetAside.load();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: SongsScreen(
          displayName: 'Taylor',
          onOpenAccount: () {},
          onOpenNotifications: () {},
          hearSealedTake: hear,
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 200));
  return controller;
}

/// What Home's row is given, rather than what a lazy list has built so far:
/// a card past the edge of a phone is not built until scrolled to.
List<WaitingItem> _sealedCards(WidgetTester tester) => tester
    .widget<WaitingOnYou>(find.byType(WaitingOnYou))
    .items
    .where((item) => item.kind == WaitingKind.sealed)
    .toList();

void main() {
  group('sealing hides it', () {
    test('a sealed take is put away, and is not offered before its day',
        () async {
      final (repository, id) = _withADraft();

      final opens = await repository.sealTake(id, until: aYearOn(_sealedOn));

      expect(opens, _theDay);
      expect(repository.isPutAway(id), isTrue);
      expect(await repository.sealedTakesDue(), isEmpty);

      // Nor the day before.
      repository.clock = () => _theDay.subtract(const Duration(days: 1));
      expect(await repository.sealedTakesDue(), isEmpty);
    });

    test('the rows of a song leave out the ones that are put away', () {
      final rows = <dynamic>[
        <String, dynamic>{'id': 'ordinary', 'sealed_until': null},
        <String, dynamic>{'id': 'put-away', 'sealed_until': '2027-09-18T21:40:00Z'},
        // A database the migration has not reached yet hands back rows with
        // no such key, and none of them is sealed.
        <String, dynamic>{'id': 'older-database'},
      ];
      expect(
        SongLayerService.takesNotPutAway(rows).map((row) => row['id']),
        <String>['ordinary', 'older-database'],
      );
    });

    test('only a take nobody else has heard can be sealed', () async {
      final (repository, _) = _withADraft();
      final heard = repository.recordTake('song-1', part: 'vocal');
      final theirs = repository.recordTake('song-1',
          part: 'bass', by: 'preview-jess', shared: false);

      await expectLater(
        repository.sealTake(heard, until: aYearOn(_sealedOn)),
        throwsA(isA<PostgrestException>().having((error) => error.message,
            'message', 'Only a take nobody else has heard can be sealed.')),
      );
      // Somebody else's draft is not there to be sealed, in the same words
      // as a take that does not exist.
      await expectLater(
        repository.sealTake(theirs, until: aYearOn(_sealedOn)),
        throwsA(isA<PostgrestException>()
            .having((error) => error.message, 'message', 'No such take.')),
      );
      expect(repository.isPutAway(heard), isFalse);
      expect(repository.isPutAway(theirs), isFalse);
    });

    test('the day has not come yet, and is no more than ten years off',
        () async {
      final (repository, id) = _withADraft();

      await expectLater(
        repository.sealTake(id, until: _sealedOn),
        throwsA(isA<PostgrestException>()),
      );
      await expectLater(
        repository.sealTake(id, until: DateTime(2036, 1, 1)),
        throwsA(isA<PostgrestException>()),
      );
      expect(repository.isPutAway(id), isFalse);

      // The furthest day the picker offers is one the repository takes.
      final furthest = opensOn(latestSealDay(_sealedOn), _sealedOn);
      expect(await repository.sealTake(id, until: furthest), furthest);
    });

    test('the nearest day the picker offers has not come yet either',
        () async {
      // A picked day opens when it starts, so tomorrow is the tightest case:
      // sealed at 21:40, it opens two hours and twenty minutes later.
      final (repository, id) = _withADraft();

      final nearest = opensOn(earliestSealDay(_sealedOn), _sealedOn);

      expect(nearest, DateTime(2025, 9, 19));
      expect(await repository.sealTake(id, until: nearest), nearest);
    });

    test('a day they pick opens when that day starts', () {
      // "Opens 20 December 2026" promises the date and nothing else. Sealed
      // at ten to midnight and opened at that hour, the card was not there
      // at nine in the morning or six in the evening of the 20th.
      final lateOneNight = DateTime(2025, 9, 18, 23, 50);

      expect(opensOn(DateTime(2026, 12, 20), lateOneNight),
          DateTime(2026, 12, 20));

      // The year that is offered keeps its evening, and opening the picker
      // and closing it on that same day changes nothing.
      expect(opensOn(DateTime(2026, 9, 18), lateOneNight),
          aYearOn(lateOneNight));
    });

    test('sealing a sealed take keeps the day it already had', () async {
      final (repository, id) = _withADraft();
      await repository.sealTake(id, until: aYearOn(_sealedOn));

      final again = await repository.sealTake(id,
          until: _sealedOn.add(const Duration(days: 30)));

      expect(again, _theDay);
    });

    testWidgets('one action on the take, and it leaves the list',
        (tester) async {
      final (repository, id) = _withADraft();
      // Sealed by the real clock from here on: the screen asks for a year
      // from now, and the repository has to agree about when now is.
      repository.clock = DateTime.now;
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);
      expect(find.byType(TakeLane), findsOneWidget);

      final before = aYearOn(DateTime.now());
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(sealItLabel));
      await tester.pumpAndSettle();

      // Asked first, in words that say what is about to happen.
      expect(find.text('Seal this take?'), findsOneWidget);
      expect(find.textContaining('Nobody else can see it'), findsOneWidget);
      expect(find.textContaining('it is not deleted'), findsOneWidget);

      await tester.tap(find.byKey(const Key('seal_it')));
      await tester.pumpAndSettle();
      final after = aYearOn(DateTime.now());

      expect(repository.isPutAway(id), isTrue);
      expect(find.byType(TakeLane), findsNothing,
          reason: 'a sealed take is not in the ordinary take list');

      // A year by default. Sealing it again answers with the day it has,
      // which is how this reads it back; bracketed rather than equal, so a
      // run that straddles a minute is still a year.
      final opens = await repository.sealTake(id,
          until: after.add(const Duration(days: 40)));
      expect(opens.isBefore(before), isFalse);
      expect(opens.isAfter(after), isFalse);
      expect(find.text(sealedUntilWords(opens)), findsOneWidget);
    });

    testWidgets('or on a day they choose', (tester) async {
      final (repository, id) = _withADraft();
      repository.clock = DateTime.now;
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(sealItLabel));
      await tester.pumpAndSettle();
      // Read off the dialog rather than worked out again, for the same
      // reason as above.
      final offered = tester
          .widget<Text>(find.byKey(const Key('seal_opens_on')))
          .data!;
      final aYear = aYearOn(DateTime.now());
      expect(offered, startsWith('Opens '));
      expect(offered, endsWith('${aYear.year}'));

      await tester.tap(find.byKey(const Key('seal_another_day')));
      await tester.pumpAndSettle();
      // Any other day of the month the picker opens on.
      final day = offered.startsWith('Opens 15 ') ? 16 : 15;
      await tester.tap(find.text('$day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final chosen = tester
          .widget<Text>(find.byKey(const Key('seal_opens_on')))
          .data!;
      expect(chosen, startsWith('Opens $day '));

      await tester.tap(find.byKey(const Key('seal_it')));
      await tester.pumpAndSettle();

      final opens = await repository.sealTake(id,
          until: DateTime.now().add(const Duration(days: 40)));
      expect(opens.day, day);
      expect(opens, DateTime(opens.year, opens.month, opens.day),
          reason: 'a picked day opens when it starts');
      expect('Opens ${dayInWords(opens)}', chosen);
      expect(find.text(sealedUntilWords(opens)), findsOneWidget);
    });

    testWidgets('a moment to take it back, and then none', (tester) async {
      final (repository, id) = _withADraft();
      repository.clock = DateTime.now;
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(sealItLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('seal_it')));
      await tester.pumpAndSettle();
      expect(find.byType(TakeLane), findsNothing);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(repository.isPutAway(id), isFalse);
      expect(find.byType(TakeLane), findsOneWidget);
    });

    testWidgets('thinking better of it seals nothing', (tester) async {
      final (repository, id) = _withADraft();
      repository.clock = DateTime.now;
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(sealItLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();

      expect(repository.isPutAway(id), isFalse);
      expect(find.byType(TakeLane), findsOneWidget);
    });

    testWidgets('a take the room has heard is not offered the seal',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final heard = repository.recordTake('song-1', part: 'vocal');
      await _openTakes(
          tester, repository, <SharedLayer>[_mine(heard, shared: true)]);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Volume'), findsOneWidget);
      expect(find.text(sealItLabel), findsNothing);
    });

    testWidgets('a note of their own on it is put away with it',
        (tester) async {
      final (repository, id) = _withADraft();
      repository.draftLayerIds.add(id);
      await repository.addMomentNote(
        projectId: 'song-1',
        layerId: id,
        atMs: 0,
        body: 'this is the hook, slow it down',
      );
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);
      expect(find.text('this is the hook, slow it down'), findsOneWidget);

      await repository.sealTake(id, until: aYearOn(_sealedOn));
      // Closed and opened again, so the screen loads rather than rebuilds.
      await tester.pumpWidget(const SizedBox());
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);

      // Not left behind pointing at "a take" nobody can find.
      expect(find.byType(TakeLane), findsNothing);
      expect(find.text('this is the hook, slow it down'), findsNothing);
      expect(find.textContaining('Note at'), findsNothing);
    });

    testWidgets('the take\'s sheet still fits a small phone with the seal on it',
        (tester) async {
      final (repository, id) = _withADraft();
      await _openTakes(tester, repository, <SharedLayer>[_mine(id)]);
      tester.view.physicalSize = const Size(360, 640);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(sealItLabel));
      await tester.pumpAndSettle();
      expect(find.text(sealItLabel).hitTestable(), findsOneWidget);
    });

    testWidgets('a year on, the same evening, unless they say otherwise',
        (tester) async {
      // A small phone at the largest text: three sentences and a date have
      // to scroll rather than overflow.
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      DateTime? answered;
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  answered = await askWhenToOpen(context, now: _sealedOn),
              child: const Text('go'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Opens 18 September 2026'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('seal_it')));
      await tester.tap(find.byKey(const Key('seal_it')));
      await tester.pumpAndSettle();

      expect(answered, _theDay);
    });
  });

  group('the date brings it back once', () {
    test('on the day it is offered, with the song it is on', () async {
      final (repository, id) = await _sealedAYearAgoTonight();

      final due = await repository.sealedTakesDue();

      expect(due, hasLength(1));
      expect(due.single.id, id);
      expect(due.single.songTitle, 'Midnight Signal');
      expect(due.single.sealedAt, _sealedOn);
      expect(due.single.storagePath, isNotEmpty);
    });

    test('to the person who sealed it and nobody else', () async {
      final (repository, _) = await _sealedAYearAgoTonight();

      repository.currentUserId = 'preview-jess';

      expect(await repository.sealedTakesDue(), isEmpty);
    });

    test('the words are the plan\'s', () {
      final take = SealedTake(
        id: 'take-1',
        projectId: 'song-1',
        songTitle: 'Midnight Signal',
        storagePath: 'room-1/song-1/layers/take-1.m4a',
        sealedAt: _sealedOn,
        opensAt: _theDay,
      );
      final card = sealedTakeCard(take,
          now: _theDay, onPlay: () {}, onNotNow: () {});

      // "A year ago tonight you sealed this. Play it now?", split where the
      // card splits everything: when above, the rest as the title.
      expect('${card.eyebrow} ${card.line}'.replaceFirst(' You', ' you'),
          'A year ago tonight you sealed this. Play it now?');
      expect(card.about, 'Midnight Signal');
      expect(card.dismissLabel, 'Not now');
      // Quiet: nobody did this, so no face and no filled button.
      expect(card.isNews, isFalse);
      expect(card.isPlayable, isFalse);
    });

    test('how long ago, said the way somebody would say it', () {
      final evening = DateTime(2026, 9, 18, 21, 40);
      final morning = DateTime(2026, 9, 18, 9, 5);

      expect(sealedAgo(DateTime(2025, 9, 18, 21, 40), evening),
          'A year ago tonight');
      expect(sealedAgo(DateTime(2025, 9, 18, 21, 40), morning),
          'A year ago today');
      expect(sealedAgo(DateTime(2023, 9, 18, 8), evening),
          'Three years ago tonight');
      // Opened four days late: still a year ago, no longer tonight.
      expect(sealedAgo(DateTime(2025, 9, 14, 21, 40), evening), 'A year ago');
      expect(sealedAgo(DateTime(2025, 4, 2), evening), 'Over a year ago');
      expect(sealedAgo(DateTime(2026, 6, 18, 23), evening),
          'Three months ago tonight');
      expect(sealedAgo(DateTime(2026, 8, 3), evening), 'A month ago');
      expect(sealedAgo(DateTime(2026, 9, 4, 22), evening),
          'Two weeks ago tonight');
      expect(sealedAgo(DateTime(2026, 9, 15), evening), 'Three days ago');
      expect(sealedAgo(DateTime(2026, 9, 17, 23, 50), evening), 'Yesterday');
    });

    test('a year on is the same evening, and 29 February carries to March',
        () {
      expect(aYearOn(DateTime(2026, 9, 18, 21, 40)),
          DateTime(2027, 9, 18, 21, 40));
      expect(aYearOn(DateTime(2028, 2, 29, 7)), DateTime(2029, 3, 1, 7));
      expect(dayInWords(DateTime(2027, 9, 18)), '18 September 2027');
    });

    testWidgets('one quiet card on Home, and none before the day',
        (tester) async {
      final (repository, id) = await _sealedAYearAgoTonight();
      repository.clock = () => _theDay.subtract(const Duration(days: 1));
      final controller = await _openHome(tester, repository);
      expect(_sealedCards(tester), isEmpty);

      repository.clock = () => _theDay;
      await controller.load();
      await tester.pump(const Duration(milliseconds: 200));

      final cards = _sealedCards(tester);
      expect(cards, hasLength(1));
      expect(cards.single.id, 'sealed-$id');
      expect(cards.single.line, 'You sealed this. Play it now?');
      expect(cards.single.about, 'Midnight Signal');
    });

    testWidgets('the card reads as the sentence, with Not now on its x',
        (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final take = SealedTake(
        id: 'take-1',
        projectId: 'song-1',
        songTitle: 'Midnight Signal',
        storagePath: 'room-1/song-1/layers/take-1.m4a',
        sealedAt: _sealedOn,
        opensAt: _theDay,
      );

      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(
            body: Column(children: <Widget>[
              WaitingOnYou(items: <WaitingItem>[
                sealedTakeCard(take,
                    now: _theDay, onPlay: () {}, onNotNow: () {}),
              ]),
            ]),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('A year ago tonight'), findsOneWidget);
      expect(find.text('You sealed this. Play it now?'), findsOneWidget);
      expect(find.text('Play it'), findsOneWidget);
      expect(find.byTooltip('Not now'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('playing it is an answer: it plays, and the take is back',
        (tester) async {
      final (repository, id) = await _sealedAYearAgoTonight();
      final heard = <String>[];
      final controller = await _openHome(
        tester,
        repository,
        hear: (take) async {
          heard.add(take.id);
          return true;
        },
      );

      _sealedCards(tester).single.onAction();
      await tester.pump(const Duration(milliseconds: 200));

      expect(heard, <String>[id]);
      expect(find.byType(SnackBar), findsNothing,
          reason: 'the bar at the bottom says where it went');
      expect(_sealedCards(tester), isEmpty);
      expect(repository.isPutAway(id), isFalse,
          reason: 'it is back among the song\'s takes');

      // Once. Coming back to the app does not offer it again.
      await controller.load();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_sealedCards(tester), isEmpty);
      expect(await repository.sealedTakesDue(), isEmpty);
    });

    testWidgets('a take that will not play still says where it went',
        (tester) async {
      // A weak connection on the one evening it is offered. The player fails
      // quietly by design, so without this the card went, no sound came, and
      // nothing said what had become of an idea kept for a year.
      final (repository, id) = await _sealedAYearAgoTonight();
      final sealed = (await repository.sealedTakesDue()).single;
      await _openHome(tester, repository, hear: (take) async => false);

      _sealedCards(tester).single.onAction();
      await tester.pump(const Duration(milliseconds: 200));

      expect(sealedTakeIsBackWords(sealed),
          'It is back among the takes on Midnight Signal.');
      expect(find.text(sealedTakeIsBackWords(sealed)), findsOneWidget);
      // Playing it was still an answer.
      expect(_sealedCards(tester), isEmpty);
      expect(repository.isPutAway(id), isFalse);
    });

    testWidgets('and so does a player that falls over', (tester) async {
      final (repository, id) = await _sealedAYearAgoTonight();
      await _openHome(
        tester,
        repository,
        hear: (take) async => throw StateError('no audio device'),
      );

      _sealedCards(tester).single.onAction();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('It is back among the takes on Midnight Signal.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(repository.isPutAway(id), isFalse);
    });

    testWidgets('with no signal at all it does not say the take is back',
        (tester) async {
      // Neither the sound nor the end of the seal got through. The take is
      // still put away, so the words must not send them to look for it.
      final (source, id) = await _sealedAYearAgoTonight();
      await _openHome(
        tester,
        _CannotBeReached(source),
        hear: (take) async => false,
      );

      _sealedCards(tester).single.onAction();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(sealedTakeWillBeOfferedAgainWords), findsOneWidget);
      expect(find.text('It is back among the takes on Midnight Signal.'),
          findsNothing);
      expect(source.isPutAway(id), isTrue);
      // Not while they are looking, all the same.
      expect(_sealedCards(tester), isEmpty);
    });
  });

  group('"Not now" is final', () {
    testWidgets('the card goes, and does not come again', (tester) async {
      final (repository, id) = await _sealedAYearAgoTonight();
      final heard = <String>[];
      final controller = await _openHome(
        tester,
        repository,
        hear: (take) async {
          heard.add(take.id);
          return true;
        },
      );

      _sealedCards(tester).single.onDismiss!();
      await tester.pump(const Duration(milliseconds: 200));

      expect(_sealedCards(tester), isEmpty);
      expect(heard, isEmpty, reason: 'Not now plays nothing');

      // Not the next time the app loads, and not a year later either.
      await controller.load();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_sealedCards(tester), isEmpty);
      repository.clock = () => DateTime(2027, 9, 18, 21, 40);
      await controller.load();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_sealedCards(tester), isEmpty);
      expect(await repository.sealedTakesDue(), isEmpty);

      // And the take is not lost to it: it is back among their takes.
      expect(repository.isPutAway(id), isFalse);
    });

    test('a reload that lands before the server has heard does not bring it back',
        () async {
      final (source, _) = await _sealedAYearAgoTonight();
      final repository = _SlowToHear(source);
      final controller = MusicBetaController(repository);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.sealedTakesDue, hasLength(1));

      final ending = controller.endSeal(controller.sealedTakesDue.single);
      // Still sealed as far as the server knows, and fetched as due again.
      await controller.load();

      expect(controller.sealedTakesDue, isEmpty);
      repository.hear();
      await ending;
      expect(controller.sealedTakesDue, isEmpty);
    });

    test('sealing it again the same evening does not bring the old card back',
        () async {
      // They answer the card, think again, find the take back in the song
      // and put it away for another year. The answered card was still in the
      // list the app had fetched, hidden only by its id, and sealing forgot
      // the id: "A year ago tonight" came back for a take sealed a minute
      // ago, and either answer on it would have undone the new seal.
      final (repository, id) = await _sealedAYearAgoTonight();
      final controller = MusicBetaController(repository);
      addTearDown(controller.dispose);
      await controller.load();
      await controller.endSeal(controller.sealedTakesDue.single);

      final opens = await controller.sealTake(id, until: aYearOn(_theDay));

      expect(opens, DateTime(2027, 9, 18, 21, 40));
      expect(controller.sealedTakesDue, isEmpty);
      expect(repository.isPutAway(id), isTrue);
      await controller.load();
      expect(controller.sealedTakesDue, isEmpty);

      // Its own day, a year on, is a new offer and is made.
      repository.clock = () => DateTime(2027, 9, 18, 21, 40);
      await controller.load();
      expect(controller.sealedTakesDue.single.id, id);
    });

    test('nothing is kept about a seal that has ended', () async {
      final (repository, id) = await _sealedAYearAgoTonight();

      await repository.unsealTake(id);
      // Quiet the second time.
      await repository.unsealTake(id);

      expect(repository.isPutAway(id), isFalse);
      expect(await repository.sealedTakesDue(), isEmpty);
      // It can be sealed again like any other draft, which is their own
      // doing and not the card repeating itself.
      final again = await repository.sealTake(id, until: aYearOn(_theDay));
      expect(again, DateTime(2027, 9, 18, 21, 40));
    });

    test('somebody else cannot end it', () async {
      final (repository, id) = await _sealedAYearAgoTonight();

      repository.currentUserId = 'preview-jess';
      await repository.unsealTake(id);

      expect(repository.isPutAway(id), isTrue);
    });
  });
}

/// A server that cannot be reached on the evening the card is answered.
class _CannotBeReached extends InMemoryMusicRepository {
  _CannotBeReached(this._source) : super.from(_source);

  final InMemoryMusicRepository _source;

  @override
  Future<List<SealedTake>> sealedTakesDue() => _source.sealedTakesDue();

  @override
  Future<void> unsealTake(String layerId) async =>
      throw StateError('No signal.');
}

/// A server that has not answered "Not now" yet.
///
/// The fixture's rooms are shared with [_source] but its takes and seals are
/// not, so everything about a seal is asked of the repository that holds one.
class _SlowToHear extends InMemoryMusicRepository {
  _SlowToHear(this._source) : super.from(_source);

  final InMemoryMusicRepository _source;
  final Completer<void> _heard = Completer<void>();

  @override
  Future<List<SealedTake>> sealedTakesDue() => _source.sealedTakesDue();

  @override
  Future<void> unsealTake(String layerId) async {
    await _heard.future;
    await _source.unsealTake(layerId);
  }

  void hear() => _heard.complete();
}
