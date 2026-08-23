import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The controller registers a lifecycle observer so it can close the live
  // socket when the app is backgrounded, and that needs a binding to register
  // with.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller refreshes the Room hierarchy after creating a song', () async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    final room = controller.rooms.last;

    final project = await controller.createSong(room, 'Open Window');

    expect(controller.projectById(project.id)?.title, 'Open Window');
    expect(controller.roomForProject(project.id)?.id, room.id);
  });
}
