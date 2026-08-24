import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pasting lyrics used to wedge the editor permanently.
///
/// Text copied out of a browser, a Notes app or a Word document carries
/// whitespace the writer cannot see: a non-breaking space where a verse break
/// looks blank, a stray indent, a carriage return left by CRLF line endings.
/// None of those lines are `isEmpty`, so they were sent to the repository
/// as-is — and the repository trims before it checks for emptiness, sees '',
/// and rejects them. Every retry then failed identically, forever, which the
/// editor reported as "Saving / Save retrying" with no way out.
void main() {
  // The shapes a real paste produces.
  const invisible = <String, String>{
    'a non-breaking space from a web page': ' ',
    'an indented blank line': '   ',
    'a tab': '\t',
    'the remains of a CRLF line ending': '\r',
    'a line the writer left empty': '',
  };

  group('a pasted line that only looks blank', () {
    invisible.forEach((description, line) {
      test('$description is stored as a blank line', () async {
        final repository = InMemoryMusicRepository.seeded();
        final rooms = await repository.loadRooms();
        final project = await repository.createSong(
          room: rooms.first,
          title: 'Paste target ${description.hashCode}',
        );

        final saved = await repository.addContribution(
          project: project,
          body: storedLineFor(line),
        );
        expect(saved.body, blankStoredLine);
      });

      test('$description is what the repository rejects untouched', () async {
        final repository = InMemoryMusicRepository.seeded();
        final rooms = await repository.loadRooms();
        final project = await repository.createSong(
          room: rooms.first,
          title: 'Reject target ${description.hashCode}',
        );

        // Guards the reason storedLineFor exists: this is the throw that
        // used to be retried every 700ms for as long as the screen was open.
        await expectLater(
          repository.addContribution(project: project, body: line),
          throwsA(isA<NameConflict>()),
        );
      });
    });

    test('a line with real words is passed through untouched', () {
      expect(
        storedLineFor('  and I thought about you  '),
        '  and I thought about you  ',
      );
      expect(storedLineFor('I went down to the river'), 'I went down to the river');
    });

    test('the blank marker is already blank and stays itself', () {
      expect(storedLineFor(blankStoredLine), blankStoredLine);
    });
  });
}
