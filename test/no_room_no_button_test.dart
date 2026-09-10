import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A button is not offered to somebody who cannot use it.
///
/// "Invite to a room" sits on every stranger's page. Tapped by somebody who
/// owns no room, it opens a sheet that says *"You do not own a room yet. Only
/// an owner can invite somebody into one."* — a control whose entire job is to
/// explain that it has no job, on the profile of the first musician a new
/// person ever opens.
class _NoRooms extends InMemoryMusicRepository {
  _NoRooms() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<MusicRoom>> loadRooms() async => const <MusicRoom>[];
}

Future<void> _open(WidgetTester tester, MusicBetaController controller,
    InMemoryMusicRepository repository) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: MusicianProfileScreen(
        profileId: 'preview-mara',
        repository: repository,
      ),
    ),
  ));
  for (var i = 0; i < 5; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  testWidgets('somebody with a room of their own is offered it',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);

    await _open(tester, controller, repository);
    expect(find.text('Invite to a room'), findsOneWidget);
  });

  testWidgets('somebody with none is not', (tester) async {
    final repository = _NoRooms();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);

    await _open(tester, controller, repository);

    expect(
      find.text('Invite to a room'),
      findsNothing,
      reason: 'the only thing this button could do for them is explain that '
          'it cannot do anything for them',
    );
    // The other two ways to reach somebody do not depend on owning anything,
    // and both stay.
    expect(find.text('Start something together'), findsOneWidget);
    expect(find.textContaining('Ask them to play on'), findsOneWidget);
  });
}
