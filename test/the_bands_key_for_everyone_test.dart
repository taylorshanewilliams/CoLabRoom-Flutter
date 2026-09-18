import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The band's key, for everybody.
///
/// Every Musician, Same Song, 17 September 2026. The band can say what key a
/// song is in (0144), and everything inside the room reads it. The pages a
/// stranger reads went on naming the analyser's key until 0160 put the
/// band's in front of it on the server: the song's page on the Open Mic, the
/// feed card, the showcase, colabroom.com's list and the brief an ask
/// carries. A stranger is the one reader who cannot ask the band.
///
/// The app's half of that is to do nothing: show the key it is handed, as it
/// is handed it, and never work one out again. These pin that. They also pin
/// the server's half the only way a machine without Postgres can, by reading
/// the newest definition of each function, so a later restatement copied
/// from an older migration fails here in seconds instead of quietly putting
/// the detected key back in front of strangers.
class _SaidByTheBand extends InMemoryMusicRepository {
  _SaidByTheBand() : super.from(InMemoryMusicRepository.seeded());

  /// A bare root, which is a key the band may say (0144) and one the
  /// analyser never writes, so it can only have come from the band.
  @override
  Future<OpenMicSong?> openMicSong(String projectId) async => OpenMicSong(
        id: projectId,
        title: 'Called By The Wrong Chord',
        ownerName: 'Mara Ellison',
        ownerId: 'preview-mara',
        putUpAt: DateTime(2026, 9, 17),
        musicalKey: 'Bb',
        bpm: 96,
      );

  @override
  Future<List<AskForMe>> asksForMe() async => <AskForMe>[
        AskForMe(
          id: 'ask-1',
          projectId: 'preview-project-1',
          songTitle: 'Called By The Wrong Chord',
          askedByName: 'Mara Ellison',
          askedById: 'preview-mara',
          part: 'bass',
          createdAt: DateTime(2026, 9, 17),
          durationMs: 134000,
          musicalKey: 'A major',
          bpm: 96,
        ),
      ];
}

/// The five functions that hand a key to somebody outside the room.
const List<String> _readers = <String>[
  'open_mic_song',
  'open_mic_feed',
  'asks_for_me',
  'showcase',
  'public_songs',
];

/// The newest definition of `public.<name>`, from its `create` to the grant
/// that closes every function in this repo.
String _latestDefinition(String name) {
  final files = Directory('supabase/migrations')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final opening =
      RegExp('create (or replace )?function public[.]$name[(]');
  for (final file in files.reversed) {
    final sql = file.readAsStringSync();
    final found = opening.allMatches(sql).toList();
    if (found.isEmpty) continue;
    final from = found.last.start;
    final to = sql.indexOf('grant execute on function public.$name(', from);
    return sql.substring(from, to < 0 ? sql.length : to);
  }
  fail('no migration defines public.$name');
}

void main() {
  group('the server', () {
    for (final name in _readers) {
      test('$name puts the band\'s key in front of the analysed one', () {
        final definition = _latestDefinition(name);
        expect(
          definition,
          contains('coalesce(p.key_override, r.musical_key)'),
          reason: 'restate public.$name from its latest definition, which '
              'reads the band\'s key since 0160',
        );
        expect(
          RegExp(r'^\s*r[.]musical_key,', multiLine: true)
              .hasMatch(definition),
          isFalse,
          reason: 'public.$name still returns the analysed key on its own',
        );
      });
    }
  });

  group('the app shows the key it is given', () {
    testWidgets('on the song\'s page on the Open Mic', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: OpenMicSongScreen(
          projectId: 'preview-open-1',
          repository: _SaidByTheBand(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('KEY'), findsOneWidget);
      expect(find.text('Bb'), findsOneWidget,
          reason: 'as the band said it: not respelled, and not "Bb major"');
    });

    testWidgets('in the brief on an ask', (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = MusicBetaController(_SaidByTheBand());
      await controller.load();
      addTearDown(controller.dispose);

      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: const NotificationsScreen(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('2:14 · in A major · 96 bpm'), findsOneWidget);
    });
  });
}
