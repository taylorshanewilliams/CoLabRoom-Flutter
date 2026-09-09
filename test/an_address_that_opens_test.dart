import 'package:colabroom/app/deep_link.dart';
import 'package:colabroom/app/routes.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:colabroom/features/rooms/room_detail_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An address that opens the place it names.
///
/// [AppRoutes] made the address bar say where you are. This is the half
/// somebody notices: paste a link to a song and land on the song, refresh and
/// still be there, send somebody a profile and have it open for them.
///
/// The rule that shapes all of it: **the shell goes underneath.** A link that
/// replaces the app leaves somebody on a song with nowhere to go back to,
/// which is the phone-in-a-browser problem wearing a different hat.
List<Route<dynamic>> _stack(String path) => DeepLink.stackFor(
      path: path,
      shell: (tab) => SizedBox(key: ValueKey<int>(tab)),
      repository: InMemoryMusicRepository.seeded(),
    );

Widget _widgetOf(Route<dynamic> route, WidgetTester tester) {
  final page = route as MaterialPageRoute<dynamic>;
  return page.builder(tester.element(find.byType(MaterialApp)));
}

void main() {
  test('an unknown address is just the app', () {
    expect(_stack('/').length, 1);
    expect(_stack('/nowhere').length, 1,
        reason: 'a wrong address should open the app, not an error page');
  });

  test('a song address opens the shell with the song on top', () {
    final stack = _stack(AppRoutes.song('ladder'));

    expect(stack.length, 2,
        reason: 'the shell underneath is what gives a pasted link a back '
            'button');
    expect(stack.last.settings.name, AppRoutes.song('ladder'));
  });

  test('the open mic address opens the app on that tab', () {
    final stack = _stack(AppRoutes.openMic);

    expect(stack.length, 1);
    expect((stack.single as MaterialPageRoute<dynamic>).settings.name,
        AppRoutes.openMic);
  });

  test('a song sub-page falls back to the song', () {
    // SongAnalysisScreen and the rest take a loaded SongProject rather than
    // an id, so /song/x/sheet cannot be opened cold without a loader that
    // does not exist. The song is where somebody would have to go first
    // anyway, and the sheet is one tap from it.
    final stack = _stack(AppRoutes.songSheet('ladder'));

    expect(stack.length, 2);
    expect(stack.last.settings.name, AppRoutes.song('ladder'),
        reason: 'better to land one tap away than to invent a loader here');
  });

  testWidgets('each address builds the screen it names', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    final cases = <String, Type>{
      AppRoutes.song('a'): SongWorkspaceScreen,
      AppRoutes.heard('a'): OpenMicSongScreen,
      AppRoutes.musician('a'): MusicianProfileScreen,
      AppRoutes.room('a'): RoomDetailScreen,
    };

    for (final entry in cases.entries) {
      final stack = _stack(entry.key);
      expect(stack.length, 2, reason: '${entry.key} built no screen');
      expect(_widgetOf(stack.last, tester).runtimeType, entry.value,
          reason: '${entry.key} built the wrong screen');
    }
  });
}
