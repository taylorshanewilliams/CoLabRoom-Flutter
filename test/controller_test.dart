import 'dart:typed_data';

import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// A repository whose avatars are all missing, counting how often it is asked.
class _MissingAvatars extends InMemoryMusicRepository {
  _MissingAvatars(InMemoryMusicRepository source) : super.from(source);

  int avatarRequests = 0;

  @override
  Future<Uint8List> loadAvatar(String path) async {
    avatarRequests += 1;
    throw StateError('No object at $path');
  }
}

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

  test('a face that will not download is asked for once, not once a frame',
      () async {
    final repository = _MissingAvatars(InMemoryMusicRepository.seeded());
    final controller = MusicBetaController(repository);
    await controller.load();

    // Song lists rebuild constantly, and every rebuild asks again for the
    // pictures on them. A path whose object is gone has to stay asked-for
    // once, or a missing avatar becomes a 404 per row per frame.
    expect(controller.avatarBytesFor('someone/avatar.png'), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(controller.avatarBytesFor('someone/avatar.png'), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(controller.avatarBytesFor('someone/avatar.png'), isNull);

    expect(repository.avatarRequests, 1);
  });
}
