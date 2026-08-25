import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two people writing the same song at once used to destroy each other's work.
///
/// The save path maps lines to contributions by position, and the editor
/// deliberately refuses to accept incoming changes while somebody is typing —
/// nobody wants text replaced mid-sentence. Those two reasonable decisions
/// combine into an unreasonable one: a stale document written over a fresh one
/// by index, which deletes lines that arrived in between and shifts every body
/// onto the wrong contribution when a line is inserted above.
///
/// The guard needs the editor to remember what it was actually shown. These
/// cover that memory, since it is the part everything else reasons from.
SongProject _projectWith(List<String> ids) {
  final now = DateTime(2026, 8, 25);
  return SongProject(
    id: 'project-1',
    roomId: 'room-1',
    accountId: 'account-1',
    title: 'Test song',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      for (final id in ids)
        Contribution(
          id: id,
          projectId: 'project-1',
          authorId: 'author-1',
          authorName: 'Writer',
          body: 'line $id',
          colorValue: 0xFFFF8A4C,
          createdAt: now,
          position: ids.indexOf(id).toDouble(),
        ),
    ],
  );
}

void main() {
  group("what the editor remembers being shown", () {
    test('is empty before it has ever hydrated', () {
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);

      // Empty has to mean "unknown", never "the song has no lines" — the
      // save path skips its check on this rather than refusing a first save.
      expect(controller.viewOfServer, isEmpty);
    });

    test('is the order of the lines it was hydrated with', () {
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);

      controller.syncProject(_projectWith(<String>['a', 'b', 'c']), force: true);

      expect(controller.viewOfServer, <String>['a', 'b', 'c']);
    });

    test('does not change while somebody is typing', () {
      // The case the whole guard exists for. A bandmate adds a line; the
      // editor must not silently adopt it as something it has seen, because
      // the text on screen still does not contain it.
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);

      controller.syncProject(_projectWith(<String>['a', 'b']), force: true);
      controller.text.text = 'a locally edited document';

      controller.syncProject(_projectWith(<String>['a', 'b', 'c']));

      expect(controller.viewOfServer, <String>['a', 'b'],
          reason: 'adopting the new id would make the stale document look current');
    });

    test('is re-recorded after a save, so the next one is not refused', () {
      // A save creates and deletes rows. Comparing the next save against
      // pre-save ids would block somebody from their own second edit.
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);

      controller.syncProject(_projectWith(<String>['a', 'b']), force: true);
      controller.noteServerOrder(<String>['a', 'b', 'new-line']);

      expect(controller.viewOfServer, <String>['a', 'b', 'new-line']);
    });

    test('hands back a list callers cannot corrupt', () {
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);

      controller.syncProject(_projectWith(<String>['a']), force: true);

      expect(() => controller.viewOfServer.add('b'), throwsUnsupportedError);
    });
  });

  group('a conflict is reported as something the writer can act on', () {
    test('it is permanent, because retrying cannot resolve it', () {
      // Retrying a stale document produces the same stale document. The chip
      // says "Not saved — why?" and stops, rather than promising an attempt
      // that would fail identically.
      const failure = SongSaveFailure(
        'Someone else changed this song while you were writing.',
        permanent: true,
      );

      expect(failure.permanent, isTrue);
      expect('$failure', contains('changed this song'));
    });
  });
}
