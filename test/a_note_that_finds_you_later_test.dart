import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/musical_roles.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:colabroom/features/openmic/what_are_you_after.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A note that finds you later.
///
/// The shallowest ask there is -- "I'd like to meet singers" -- had nowhere
/// to live. These pin what leaving one does, what the words for a part are
/// when they are about a person, where the offer appears, and the other
/// direction: what a newcomer is told about who is looking.
class _NobodyMatches extends InMemoryMusicRepository {
  _NobodyMatches() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<Musician>> findMusicians({
    List<String>? parts,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async =>
      const <Musician>[];
}

class _TwoPeopleWantBass extends _NobodyMatches {
  @override
  Future<List<WantAround>> wantsAround() async => const <WantAround>[
        WantAround(part: 'bass', label: 'a bass player', people: 2),
      ];
}

Future<void> _open(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  OpenMicQuery? query,
}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: OpenMicScreen(repository: repository, initialQuery: query),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('the words', () {
    test('a part becomes a person', () {
      expect(someoneWhoPlays('vocal'), 'a singer');
      expect(someoneWhoPlays('bass'), 'a bass player');
      expect(someoneWhoPlays('drums'), 'a drummer');
      expect(someoneWhoPlays('engineer'), 'an engineer');
      expect(someoneWhoPlays('sitar'), 'somebody who plays sitar');
    });

    test('the server word for a match is known to this build', () {
      expect(notificationTypeFromSql('want_matched'),
          NotificationType.wantMatched);
    });
  });

  group('the repository', () {
    test('a note lasts a month, renews in place, and can be dropped',
        () async {
      final repo = InMemoryMusicRepository.seeded();
      expect(await repo.myWants(), isEmpty);

      final left = await repo.leaveWant(part: 'vocal', label: 'a singer');
      expect(left.part, 'vocal');
      expect(left.label, 'a singer');
      expect(left.note, isNull);
      final days = left.expiresAt.difference(DateTime.now()).inDays;
      expect(days, inInclusiveRange(29, 30));

      final renewed = await repo.leaveWant(
          part: 'vocal', label: 'a singer', note: 'harmonies mostly');
      expect((await repo.myWants()).length, 1,
          reason: 'the same note twice is one note, renewed');
      expect(renewed.note, 'harmonies mostly');

      await repo.dropWant(renewed.id);
      expect(await repo.myWants(), isEmpty);
    });
  });

  group('the Open Mic', () {
    testWidgets('a narrow search that finds nobody offers to leave a note',
        (tester) async {
      final repo = _NobodyMatches();
      await repo.setOpenMicPresence(discoverable: true);
      await _open(tester, repo,
          query: const OpenMicQuery(parts: <String>{'vocal'}));

      expect(find.byKey(const Key('open_mic_leave_want')), findsOneWidget);
      expect(find.textContaining('a singer'), findsWidgets);

      await tester.tap(find.byKey(const Key('open_mic_leave_want')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leave_want_send')), findsOneWidget);

      await tester.tap(find.byKey(const Key('leave_want_send')));
      await tester.pumpAndSettle();

      final wants = await repo.myWants();
      expect(wants.single.part, 'vocal');
      expect(wants.single.label, 'a singer');
    });

    testWidgets('a room with nobody in it does not offer a note',
        (tester) async {
      final repo = _NobodyMatches();
      await repo.setOpenMicPresence(discoverable: true);
      await _open(tester, repo);
      expect(find.byKey(const Key('open_mic_leave_want')), findsNothing,
          reason: 'nothing was asked for, so there is nothing to note');
    });

    testWidgets('somebody listed is told who is looking for what they play',
        (tester) async {
      final repo = _TwoPeopleWantBass();
      await repo.setOpenMicPresence(discoverable: true);
      await _open(tester, repo);

      expect(find.byKey(const Key('open_mic_wants_around')), findsOneWidget);
      expect(
        find.textContaining('2 people around here are looking for a bass player'),
        findsOneWidget,
      );
    });
  });
}
