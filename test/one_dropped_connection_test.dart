import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One dropped connection should not cost somebody their songs.
///
/// Loading the library is five calls in a row, and only the first was
/// retried — on the reasoning that the rest carry the same token, which is
/// true of tokens and untrue of networks. A gateway timeout on the third
/// call took the whole library down and left an error where the songs go,
/// and it happened twice in the week of 15 September 2026.
class _FlakyOnce extends InMemoryMusicRepository {
  _FlakyOnce(this.failing) : super.from(InMemoryMusicRepository.seeded());

  /// Which call fails, once.
  final String failing;
  final List<String> calls = <String>[];

  Never _drop() => throw PostgrestException(
        message: 'Gateway Timeout',
        code: '504',
      );

  @override
  Future<List<BetaInvite>> loadInvites() async {
    calls.add('invites');
    if (failing == 'invites' && calls.where((c) => c == 'invites').length == 1) {
      _drop();
    }
    return super.loadInvites();
  }

  @override
  Future<List<Setlist>> loadSetlists() async {
    calls.add('setlists');
    if (failing == 'setlists' && calls.where((c) => c == 'setlists').length == 1) {
      _drop();
    }
    return super.loadSetlists();
  }
}

/// Fails every time, to prove a real failure is still a failure.
class _AlwaysDown extends InMemoryMusicRepository {
  _AlwaysDown() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<Setlist>> loadSetlists() async =>
      throw PostgrestException(message: 'Gateway Timeout', code: '504');
}

void main() {
  // The controller reaches for the binding as it is built.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a call that drops once is tried again, and the library loads', () async {
    for (final failing in <String>['invites', 'setlists']) {
      final repo = _FlakyOnce(failing);
      final controller = MusicBetaController(repo);
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.error, isNull, reason: '$failing dropped once, not forever');
      expect(controller.rooms, isNotEmpty);
      expect(repo.calls.where((c) => c == failing).length, greaterThan(1),
          reason: 'it was actually tried again');
    }
  });

  test('a call that never comes back is still reported', () async {
    final controller = MusicBetaController(_AlwaysDown());
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.error, isNotNull,
        reason: 'three tries and still nothing is worth telling somebody');
  });
}
