import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an empty shelf offers.
///
/// Somebody arrives as one of three people and the app cannot tell which:
/// working alone, working with a band, or looking for somebody to play with.
/// Two tabs holding songs serve the first two and abandon the third, who has
/// nothing to put in either — and the old landing rule sent exactly that
/// person to the Open Mic, on the reasoning that it is "a room with music in
/// it". True against seventy-five seeded musicians. False against four real
/// accounts with one findable and no songs on the mic.
///
/// So the empty shelf stops being empty. This is not a mode picker and not a
/// tour: it is an empty state, which is the one place saying what is possible
/// is unambiguously right — and the rule that keeps it honest is that it is
/// gone the moment there is a song to show instead.
class _NoSongs extends InMemoryMusicRepository {
  _NoSongs() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<MusicRoom>> loadRooms() async => const <MusicRoom>[];
}

Future<void> _boot(
  WidgetTester tester,
  InMemoryMusicRepository repository,
  Widget screen,
) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    // Scaffold because the shell provides one and the screen does not, so
    // an InkResponse in here would otherwise have no Material to paint on.
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(body: screen),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('an empty shelf offers all three ways in', (tester) async {
    var recorded = 0;
    var searched = 0;

    await _boot(
      tester,
      _NoSongs(),
      SongsScreen(
        displayName: 'Taylor',
        onOpenAccount: () {},
        onOpenNotifications: () {},
        onRecord: () => recorded += 1,
        onFindMusicians: () => searched += 1,
      ),
    );

    expect(find.byKey(const Key('door_record')), findsOneWidget);
    expect(find.byKey(const Key('door_band')), findsOneWidget);
    expect(find.byKey(const Key('door_find')), findsOneWidget,
        reason: 'the person with nothing of their own is the one both tabs '
            'used to abandon');

    // Each door goes somewhere, rather than describing something.
    await tester.tap(find.byKey(const Key('door_record')));
    await tester.pump();
    expect(recorded, 1);

    await tester.tap(find.byKey(const Key('door_find')));
    await tester.pump();
    expect(searched, 1);
  });

  testWidgets('and disappears once there is a song to show', (tester) async {
    await _boot(
      tester,
      InMemoryMusicRepository.seeded(),
      SongsScreen(
        displayName: 'Taylor',
        onOpenAccount: () {},
        onOpenNotifications: () {},
        onRecord: () {},
        onFindMusicians: () {},
      ),
    );

    expect(find.byKey(const Key('door_record')), findsNothing,
        reason: 'an empty state that survives having content is an advert');
  });
}
