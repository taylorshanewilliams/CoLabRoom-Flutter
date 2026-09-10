import 'package:colabroom/features/songs/song_sheet_queue.dart';
import 'package:colabroom/services/set_aside.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/app/music_beta_controller.dart';

/// A suggestion you can say no to.
///
/// Taylor, on two cards at the top of Your music: "I've had this notification
/// of sorts at the top of my screen for awhlie, it says i left this 2 weeks
/// ago, and its a project, when i click it it just opens the song, no way of
/// removing this notification... its just a neucance at this point. same with
/// just below that where your music is, it says make the song shee for...and
/// it just goes to a song with no option to accept or deny."
///
/// And the sentence that settles the design: "i like the notifications and
/// app asking if you wanna do something, but this should be able to do, or
/// close out of."
///
/// The difference between a suggestion and a nag is entirely whether "no" is
/// a thing you can say. Both cards had one verb — open the song — so a song
/// somebody had deliberately stopped working on sat at the top of the app
/// asking again every time they opened it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SetAside.resetForTesting();
  });

  test('nothing is set aside until somebody says so', () {
    expect(SetAside.has(SetAside.pickItBackUp, 'song-1'), isFalse);
    expect(SetAside.of(SetAside.songSheet), isEmpty);
  });

  test('saying no is remembered', () async {
    await SetAside.add(SetAside.pickItBackUp, 'song-1');
    expect(SetAside.has(SetAside.pickItBackUp, 'song-1'), isTrue);

    // And survives a reload, which is the whole point: a dismissal that
    // lasted until the next launch is the same nag with a delay on it.
    SetAside.resetForTesting();
    await SetAside.load();
    expect(SetAside.has(SetAside.pickItBackUp, 'song-1'), isTrue);
  });

  test('the two cards keep their own answers', () async {
    // Saying "stop offering to analyse this" is not saying "stop reminding me
    // this song exists". They are different questions about the same song.
    await SetAside.add(SetAside.songSheet, 'song-1');
    expect(SetAside.has(SetAside.songSheet, 'song-1'), isTrue);
    expect(SetAside.has(SetAside.pickItBackUp, 'song-1'), isFalse);
  });

  test('a set-aside song leaves the sheet queue', () async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    final queue = SongSheetQueue.from(controller.rooms);
    final lead = queue.lead;
    if (lead == null) return; // nothing to analyse in the seed

    final without = queue.without(<String>{lead.project.id});
    expect(without.lead?.project.id, isNot(lead.project.id),
        reason: 'the card must stop offering the thing that was refused');
  });

  test('the counts stay true to the pile, not to one persons patience',
      () async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    final queue = SongSheetQueue.from(controller.rooms);
    // `working` is what the server is doing right now. Hiding a card must not
    // rewrite what the room is busy with — a song set aside on one phone is
    // not a song hidden from the band.
    expect(queue.without(<String>{'anything'}).working.length,
        queue.working.length);
  });
}
