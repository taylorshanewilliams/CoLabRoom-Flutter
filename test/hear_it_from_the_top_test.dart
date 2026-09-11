import 'package:colabroom/domain/activity.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hearing it, rather than being told about it.
///
/// Checked in production on 2026-09-11: project_events held 13 `edited` rows
/// and 5 `message` rows, and **not one `recording`**. The kind has been
/// allowed since 0032 and nothing ever wrote it — so the single most exciting
/// thing that can happen here, somebody recording a part on your song while
/// you were asleep, had never appeared in "what happened" at all.
///
/// 0104 writes the event and carries where the audio is, so the strip at the
/// top of Your music can play it without opening anything. A feed that tells
/// you somebody added a bass part and a feed that plays you the bass part are
/// different products.
void main() {
  group('what the sentence says', () {
    ActivityItem recording({String part = ''}) => ActivityItem(
          id: 'e1',
          projectId: 'p1',
          projectTitle: 'Midnight Signal',
          kind: ActivityKind.recording,
          at: DateTime(2026, 9, 11),
          actorName: 'Dylan',
          body: part,
        );

    test('the part, when they named one', () {
      // "Dylan added bass" is a reason to listen. "Dylan added a recording"
      // is a fact about a database.
      expect(recording(part: 'bass').sentence, 'Dylan added bass');
    });

    test('and something true when they did not', () {
      expect(recording().sentence, 'Dylan added a recording');
    });
  });

  group('what can be heard', () {
    test('a recording with a path can be played where it is listed', () {
      const item = WaitingItem(
        id: 'n1',
        kind: WaitingKind.news,
        who: 'Dylan',
        line: 'Dylan added bass',
        actionLabel: 'Hear it',
        onAction: _nothing,
        audioPath: 'room/project/takes/abc.m4a',
      );
      expect(item.isPlayable, isTrue);
    });

    test('a recording whose take was un-shared cannot', () {
      // The query joins the layer only while it is still shared, so a take
      // somebody withdrew comes back with no path — the event stays true and
      // stops being playable, which is the right pair.
      const item = WaitingItem(
        id: 'n2',
        kind: WaitingKind.news,
        who: 'Dylan',
        line: 'Dylan added bass',
        actionLabel: 'Open',
        onAction: _nothing,
      );
      expect(item.isPlayable, isFalse);
    });

    test('an empty path is not a path', () {
      const item = WaitingItem(
        id: 'n3',
        kind: WaitingKind.news,
        who: 'Dylan',
        line: 'Dylan added bass',
        actionLabel: 'Open',
        onAction: _nothing,
        audioPath: '',
      );
      expect(item.isPlayable, isFalse,
          reason: 'a play button that plays nothing is worse than no button');
    });

    test('nothing else claims to be playable', () {
      const chore = WaitingItem(
        id: 's1',
        kind: WaitingKind.sheet,
        line: 'Make the song sheet',
        actionLabel: 'Make it',
        onAction: _nothing,
      );
      expect(chore.isPlayable, isFalse);
    });
  });
}

void _nothing() {}
