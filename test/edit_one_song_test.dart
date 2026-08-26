import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Editing a line must cost one song, not the library.
///
/// loadRooms fetches every Room, every song, every lyric line and every file
/// in one query. Typing a line ran that twice — once because the mutation
/// asked for a reload, and again when the realtime channel reported the same
/// write back to the phone that had just made it. On a real account that is
/// hundreds of kilobytes of somebody's own words, per line, over mobile data.

class _CountingRepository extends InMemoryMusicRepository {
  int roomLoads = 0;
  int projectLoads = 0;

  @override
  Future<List<MusicRoom>> loadRooms() {
    roomLoads += 1;
    return super.loadRooms();
  }

  @override
  Future<SongProject?> loadProject(String projectId) {
    projectLoads += 1;
    return super.loadProject(projectId);
  }
}

void main() {
  late _CountingRepository repository;
  late MusicBetaController controller;

  setUp(() async {
    repository = _CountingRepository();
    controller = MusicBetaController(repository);
    await controller.load();
  });

  tearDown(() => controller.dispose());

  test('editing a line reads one song and not the library', () async {
    final project = controller.rooms
        .expand((room) => room.projects)
        .firstWhere((project) => project.contributions.isNotEmpty);
    final before = repository.roomLoads;

    await controller.updateContribution(
      project.contributions.first,
      'a line that was rewritten',
    );

    expect(repository.roomLoads, before,
        reason: 'the whole library was re-read for one edited line');
    expect(repository.projectLoads, 1);
  });

  test('adding a line reads one song and not the library', () async {
    final project = controller.rooms.expand((room) => room.projects).first;
    final before = repository.roomLoads;

    await controller.addContribution(project, 'a new line');

    expect(repository.roomLoads, before);
    expect(repository.projectLoads, 1);
  });

  test('a song that is not held locally falls back to a full read', () async {
    // An invitation accepted on another device: there is nothing to splice
    // into, so reading the library properly is the correct answer once.
    final before = repository.roomLoads;

    await controller.refreshProject('a-song-this-device-has-never-seen');

    expect(repository.roomLoads, before + 1);
  });
}
