import 'dart:math' as math;

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';
import 'package:colabroom/features/workspace/line_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A line of a song keeps its contribution for as long as its words do.
///
/// Audit, 17 September 2026: the save mapped lines to contributions by index.
/// One new line near the top of a band's song moved every later line's words
/// into the contribution above, so each line after it was credited to the
/// wrong writer and sat beside the wrong voice note, and deleting a line
/// deleted the last contribution instead of that one. These cover the diff
/// that replaced it, one kind of edit at a time.

/// What an editor saw: contribution c0 holds the first body, c1 the second.
List<SeenLine> _seen(List<String> bodies) => <SeenLine>[
      for (var i = 0; i < bodies.length; i += 1) SeenLine(contributionId: 'c$i', body: bodies[i]),
    ];

/// The contribution behind each line, '+' for a new one.
List<String> _ids(LineReconciliation plan) =>
    plan.lines.map((line) => line.contributionId ?? '+').toList(growable: false);

List<LineChange> _changes(LineReconciliation plan) =>
    plan.lines.map((line) => line.change).toList(growable: false);

const _blank = blankStoredLine;
const _kept = LineChange.kept;
const _added = LineChange.added;
const _rewritten = LineChange.rewritten;
const _moved = LineChange.moved;

void main() {
  group('lines that did not change', () {
    test('keep their contributions and write nothing', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['A', 'B', 'C']);

      expect(_ids(plan), <String>['c0', 'c1', 'c2']);
      expect(_changes(plan), <LineChange>[_kept, _kept, _kept]);
      expect(plan.deleted, isEmpty);
      expect(plan.changesNothing, isTrue);
    });

    test('a song with nothing in it yet adds every line', () {
      final plan = reconcileLines(const <SeenLine>[], <String>['A', 'B']);

      expect(_changes(plan), <LineChange>[_added, _added]);
      expect(plan.deleted, isEmpty);
    });
  });

  group('inserting a line', () {
    test('at the top moves nobody else\'s words', () {
      // The reported case. Before, c0 took "New", c1 took "A", c2 took "B"
      // and a new contribution took "C" in the name of whoever typed.
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['New', 'A', 'B', 'C']);

      expect(_ids(plan), <String>['+', 'c0', 'c1', 'c2']);
      expect(_changes(plan), <LineChange>[_added, _kept, _kept, _kept]);
      expect(plan.deleted, isEmpty);
    });

    test('in the middle', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['A', 'New', 'B', 'C']);

      expect(_ids(plan), <String>['c0', '+', 'c1', 'c2']);
      expect(plan.deleted, isEmpty);
    });

    test('at the end', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['A', 'B', 'C', 'New']);

      expect(_ids(plan), <String>['c0', 'c1', 'c2', '+']);
      expect(plan.deleted, isEmpty);
    });

    test('several at once, a whole verse pasted in', () {
      final plan = reconcileLines(
        _seen(<String>['A', 'B']),
        <String>['A', 'One', 'Two', 'Three', 'B'],
      );

      expect(_ids(plan), <String>['c0', '+', '+', '+', 'c1']);
      expect(plan.lines.map((line) => line.body), <String>['A', 'One', 'Two', 'Three', 'B']);
    });
  });

  group('deleting a line', () {
    test('in the middle deletes exactly that contribution', () {
      // Before, c1 took "C" and c2 — the last line — was deleted.
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['A', 'C']);

      expect(_ids(plan), <String>['c0', 'c2']);
      expect(_changes(plan), <LineChange>[_kept, _kept]);
      expect(plan.deleted, <String>['c1']);
    });

    test('at the top', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['B', 'C']);

      expect(_ids(plan), <String>['c1', 'c2']);
      expect(plan.deleted, <String>['c0']);
    });

    test('several, not next to each other', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C', 'D', 'E']), <String>['A', 'C', 'E']);

      expect(_ids(plan), <String>['c0', 'c2', 'c4']);
      expect(plan.deleted, <String>['c1', 'c3']);
    });
  });

  group('replacing a line', () {
    test('keeps its contribution and takes the new words', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['A', 'B, rewritten', 'C']);

      expect(plan.lines[1], const PlannedLine(_rewritten, 'B, rewritten', contributionId: 'c1'));
      expect(_changes(plan), <LineChange>[_kept, _rewritten, _kept]);
      expect(plan.deleted, isEmpty);
    });

    test('a run of lines rewritten in place pairs first with first', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C', 'D']), <String>['A', 'X', 'Y', 'D']);

      expect(_ids(plan), <String>['c0', 'c1', 'c2', 'c3']);
      expect(_changes(plan), <LineChange>[_kept, _rewritten, _rewritten, _kept]);
    });

    test('splitting a line keeps the contribution on its first half', () {
      final plan = reconcileLines(
        _seen(<String>['Hello world', 'After']),
        <String>['Hello', 'world', 'After'],
      );

      expect(_ids(plan), <String>['c0', '+', 'c1']);
      expect(_changes(plan), <LineChange>[_rewritten, _added, _kept]);
    });

    test('joining two lines keeps the first and deletes the second', () {
      final plan = reconcileLines(_seen(<String>['Hello', 'world']), <String>['Hello world']);

      expect(_ids(plan), <String>['c0']);
      expect(plan.deleted, <String>['c1']);
    });

    test('a new line typed above one being edited does not take the edited line\'s place', () {
      // One save covers a whole burst of typing, so both edits arrive
      // together. Pairing by order alone would hand Jess's contribution to
      // the new words and make her edited line somebody else's.
      final plan = reconcileLines(
        _seen(<String>['Streetlights blur', 'Your frequency keeps calling']),
        <String>['Streetlights blur', 'Something new', 'Your frequency keeps calling out my name'],
      );

      expect(_ids(plan), <String>['c0', '+', 'c1']);
      expect(_changes(plan), <LineChange>[_kept, _added, _rewritten]);
    });

    test('a line deleted next to one being edited deletes the right one', () {
      final plan = reconcileLines(
        _seen(<String>['A', 'Gone for good', 'Keep me close']),
        <String>['A', 'Keep me closer'],
      );

      expect(_ids(plan), <String>['c0', 'c2']);
      expect(plan.deleted, <String>['c1']);
    });
  });

  group('two identical lines', () {
    test('deleting the second deletes the second', () {
      final plan = reconcileLines(_seen(<String>['Chorus', 'Verse', 'Chorus']), <String>['Chorus', 'Verse']);

      expect(_ids(plan), <String>['c0', 'c1']);
      expect(plan.deleted, <String>['c2']);
    });

    test('deleting the first deletes the first', () {
      final plan = reconcileLines(_seen(<String>['Chorus', 'Verse', 'Chorus']), <String>['Verse', 'Chorus']);

      expect(_ids(plan), <String>['c1', 'c2']);
      expect(plan.deleted, <String>['c0']);
    });

    test('duplicating a line keeps the original and adds one copy', () {
      final plan = reconcileLines(_seen(<String>['Chorus', 'Verse']), <String>['Chorus', 'Chorus', 'Verse']);

      expect(_ids(plan), <String>['c0', '+', 'c1']);
      expect(plan.deleted, isEmpty);
    });
  });

  group('blank lines', () {
    test('a new blank line between verses is a new line, not a shift', () {
      final plan = reconcileLines(
        _seen(<String>['A', _blank, 'B', 'C']),
        <String>['A', _blank, 'B', _blank, 'C'],
      );

      expect(_ids(plan), <String>['c0', 'c1', 'c2', '+', 'c3']);
    });

    test('deleting one of several blank lines deletes one', () {
      final plan = reconcileLines(
        _seen(<String>['A', _blank, 'B', _blank, 'C']),
        <String>['A', 'B', _blank, 'C'],
      );

      expect(_ids(plan), <String>['c0', 'c2', 'c3', 'c4']);
      expect(plan.deleted, <String>['c1']);
    });

    test('an empty line on screen is the stored-blank marker it was loaded from', () {
      // The body column refuses '', so a blank line is stored as U+200B and
      // shown as ''. Comparing the two raw would rewrite every blank line in
      // the song on every save.
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);
      controller.syncProject(_song(<String>['A', blankStoredLine, 'B']), force: true);

      expect(controller.text.text, 'A\n\nB');
      final plan = controller.reconcile(<String>['A', '', 'B']);
      expect(plan.changesNothing, isTrue);

      // Whitespace is blank too, the way storedLineFor stores it.
      expect(controller.reconcile(<String>['A', '  \t', 'B']).changesNothing, isTrue);
    });

    test('words typed on a blank line rewrite that blank line', () {
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);
      controller.syncProject(_song(<String>['A', blankStoredLine, 'B']), force: true);

      final plan = controller.reconcile(<String>['A', 'Now there are words', 'B']);

      expect(plan.lines[1], const PlannedLine(_rewritten, 'Now there are words', contributionId: 'line-1'));
      expect(plan.deleted, isEmpty);
    });

    test('a trailing space is not an edit', () {
      final controller = ContinuousSongEditorController();
      addTearDown(controller.dispose);
      controller.syncProject(_song(<String>['Hello', 'There']), force: true);

      expect(controller.reconcile(<String>['Hello ', 'There']).changesNothing, isTrue);
    });
  });

  group('moving a line', () {
    test('down: the line takes its contribution with it', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C', 'D']), <String>['B', 'C', 'D', 'A']);

      expect(_ids(plan), <String>['c1', 'c2', 'c3', 'c0']);
      expect(_changes(plan), <LineChange>[_kept, _kept, _kept, _moved]);
      expect(plan.deleted, isEmpty, reason: 'deleting it would delete its voice note');
    });

    test('up', () {
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C', 'D']), <String>['A', 'D', 'B', 'C']);

      expect(_ids(plan), <String>['c0', 'c3', 'c1', 'c2']);
      expect(_changes(plan), <LineChange>[_kept, _moved, _kept, _kept]);
    });

    test('two lines swapped', () {
      final plan = reconcileLines(_seen(<String>['A', 'B']), <String>['B', 'A']);

      expect(_ids(plan), <String>['c1', 'c0']);
      expect(plan.deleted, isEmpty);
    });

    test('a move and an edit in one save do not trade contributions', () {
      // Pairing before finding the move would rewrite A's contribution with
      // B's new words and write A again as somebody else's line.
      final plan = reconcileLines(_seen(<String>['A', 'B', 'C']), <String>['B, edited', 'C', 'A']);

      expect(_ids(plan), <String>['c1', 'c2', 'c0']);
      expect(_changes(plan), <LineChange>[_rewritten, _kept, _moved]);
      expect(plan.deleted, isEmpty);
    });
  });

  group('a document too large to compare line by line', () {
    test('still keeps every line whose words are still there', () {
      // Past the comparison cap the middle is not diffed, so a whole song
      // pasted back in reverse arrives as one hunk. Matching equal words is
      // what stops that turning into 1,500 deletes and 1,500 new lines in
      // somebody else's name.
      final bodies = <String>[for (var i = 0; i < 1500; i += 1) 'line number $i'];
      final lines = <String>['a new top line', ...bodies.reversed];

      final plan = reconcileLines(_seen(bodies), lines);

      expect(plan.lines.first.change, _added);
      expect(plan.lines.skip(1).map((line) => line.contributionId),
          <String>[for (var i = 1499; i >= 0; i -= 1) 'c$i']);
      expect(plan.deleted, isEmpty);
    });
  });

  group('whatever the edit', () {
    test('every line the editor saw ends up in exactly one place', () {
      // Random edits against random songs: a line is kept, rewritten, moved
      // or deleted — never two of those, never lost, never invented.
      final random = math.Random(20260917);
      const words = <String>['oh', 'la', 'love', 'rain', blankStoredLine, 'night', 'home'];
      for (var round = 0; round < 400; round += 1) {
        final bodies = <String>[
          for (var i = random.nextInt(12); i > 0; i -= 1) words[random.nextInt(words.length)],
        ];
        final lines = List<String>.of(bodies);
        for (var edit = random.nextInt(5); edit > 0; edit -= 1) {
          final at = lines.isEmpty ? 0 : random.nextInt(lines.length);
          switch (random.nextInt(4)) {
            case 0:
              lines.insert(at, words[random.nextInt(words.length)]);
            case 1:
              if (lines.isNotEmpty) lines.removeAt(at);
            case 2:
              if (lines.isNotEmpty) lines[at] = '${lines[at]} again';
            default:
              if (lines.isNotEmpty) lines.insert(random.nextInt(lines.length), lines.removeAt(at));
          }
        }
        final seen = _seen(bodies);
        final plan = reconcileLines(seen, lines);
        final context = 'from $bodies to $lines';

        expect(plan.lines.map((line) => line.body), lines, reason: context);
        final placed = plan.lines.map((line) => line.contributionId).whereType<String>().toList();
        expect(<String>[...placed, ...plan.deleted]..sort(), seen.map((line) => line.contributionId).toList()..sort(),
            reason: context);

        var lastKept = -1;
        for (final line in plan.lines) {
          final id = line.contributionId;
          if (line.change == _added) {
            expect(id, isNull, reason: context);
            continue;
          }
          final index = int.parse(id!.substring(1));
          if (line.change == _kept || line.change == _moved) {
            expect(line.body, bodies[index], reason: context);
          }
          if (line.change == _kept) {
            expect(index, greaterThan(lastKept), reason: 'kept lines stay in order, $context');
            lastKept = index;
          }
        }

        // And the plan can always be placed, with every line between its
        // neighbours.
        final positions = planPositions(<double?>[
          for (final line in plan.lines)
            line.change == _kept || line.change == _rewritten
                ? (int.parse(line.contributionId!.substring(1)) + 1) * linePositionStep
                : null,
        ]).positions;
        for (var i = 1; i < positions.length; i += 1) {
          expect(positions[i], greaterThan(positions[i - 1]), reason: context);
        }
      }
    });
  });

  group('where a line goes', () {
    test('a new line between two goes halfway', () {
      final plan = planPositions(<double?>[1024, null, 2048]);

      expect(plan.positions, <double>[1024, 1536, 2048]);
      expect(plan.renumbered, isFalse);
    });

    test('several new lines between two are spaced evenly', () {
      final plan = planPositions(<double?>[1024, null, null, null, 2048]);

      expect(plan.positions, <double>[1024, 1280, 1536, 1792, 2048]);
    });

    test('above the first line, a step before it', () {
      expect(planPositions(<double?>[null, null, 1024]).positions, <double>[-1024, 0, 1024]);
    });

    test('after the last line, a step after it', () {
      expect(planPositions(<double?>[1024, null]).positions, <double>[1024, 2048]);
    });

    test('in an empty song, from the first step', () {
      expect(planPositions(<double?>[null, null]).positions, <double>[1024, 2048]);
    });

    test('after the last line this editor saw, still before a line it never saw', () {
      final plan = planPositions(<double?>[1024, null], before: 2048);

      expect(plan.positions, <double>[1024, 1536]);
    });

    test('lines that already share a position are left alone', () {
      final plan = planPositions(<double?>[1024, 1024, 2048]);

      expect(plan.positions, <double>[1024, 1024, 2048]);
      expect(plan.renumbered, isFalse);
    });

    test('with no room between two lines, the song is spaced out again', () {
      final plan = planPositions(<double?>[1024, null, 1024]);

      expect(plan.renumbered, isTrue);
      expect(plan.positions, <double>[1024, 2048, 3072]);
    });

    test('spacing out stays below a line this editor never saw', () {
      final plan = planPositions(<double?>[1024, null, 1024], before: 1024);

      expect(plan.renumbered, isTrue);
      expect(plan.positions, <double>[-2048, -1024, 0]);
    });

    test('halving runs out, and when it does the song is spaced out again', () {
      // A writer adding line after line in the same place halves the same
      // gap each time. A double cannot do that forever.
      var lower = 1024.0;
      const upper = 2048.0;
      var saves = 0;
      PositionPlan plan;
      do {
        plan = planPositions(<double?>[lower, null, upper]);
        saves += 1;
        if (!plan.renumbered) {
          expect(plan.positions[1], greaterThan(lower));
          expect(plan.positions[1], lessThan(upper));
          lower = plan.positions[1];
        }
      } while (!plan.renumbered && saves < 200);

      expect(plan.renumbered, isTrue, reason: 'there has to be a way out');
      expect(saves, greaterThan(40), reason: 'renumbering is for when there is truly no room');
      expect(plan.positions, <double>[1024, 2048, 3072]);
    });
  });
}

SongProject _song(List<String> bodies) {
  final now = DateTime(2026, 9, 17);
  return SongProject(
    id: 'song-1',
    roomId: 'room-1',
    accountId: 'account-1',
    title: 'A song',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      for (var i = 0; i < bodies.length; i += 1)
        Contribution(
          id: 'line-$i',
          projectId: 'song-1',
          authorId: i.isEven ? 'taylor' : 'jess',
          authorName: i.isEven ? 'Taylor' : 'Jess',
          body: bodies[i],
          colorValue: i.isEven ? 0xFFFF8A4C : 0xFF3AD3FF,
          createdAt: now,
          position: (i + 1) * 1024,
        ),
    ],
  );
}
