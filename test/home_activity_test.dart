import 'package:colabroom/domain/activity.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sentences Home is made of.
///
/// Worth testing directly because they are the entire point of the surface:
/// "Dylan said something" costs a person a tap to find out what, which is the
/// exact cost this screen exists to remove.

ActivityItem _item({
  required ActivityKind kind,
  String? actorName = 'Dylan',
  String body = '',
}) {
  return ActivityItem(
    id: 'e1',
    projectId: 'p1',
    projectTitle: 'Ladder',
    kind: kind,
    at: DateTime(2026, 8, 26),
    actorName: actorName,
    body: body,
  );
}

void main() {
  test('a message says what was said, not that something was said', () {
    final item = _item(
      kind: ActivityKind.message,
      body: 'that chorus is the one',
    );

    expect(item.sentence, 'Dylan: that chorus is the one');
  });

  test('an empty message still reads as a sentence', () {
    expect(_item(kind: ActivityKind.message).sentence, 'Dylan said something');
  });

  test('every kind has words', () {
    expect(_item(kind: ActivityKind.edited).sentence, 'Dylan changed the words');
    expect(_item(kind: ActivityKind.analyzed).sentence,
        'Dylan made the song sheet');
    expect(_item(kind: ActivityKind.recording).sentence,
        'Dylan added a recording');
    expect(_item(kind: ActivityKind.joined).sentence, 'Dylan joined');
  });

  test('somebody whose account is gone still has their event read', () {
    // 0032 keeps their words on purpose. A null name must not erase the line.
    final item = _item(kind: ActivityKind.edited, actorName: null);
    expect(item.sentence, 'Somebody changed the words');
  });

  test('a kind the database learns later still renders', () {
    // A screen that only lists things must not crash on a value added to the
    // check constraint after this build shipped.
    expect(ActivityKind.parse('something_new'), ActivityKind.edited);
  });

  group('how long ago, at the resolution a person cares about', () {
    final now = DateTime(2026, 8, 26, 12);

    test('just now', () {
      expect(shortAgo(now.subtract(const Duration(seconds: 20)), now: now), 'now');
    });

    test('minutes, hours, days, weeks', () {
      expect(shortAgo(now.subtract(const Duration(minutes: 14)), now: now), '14m');
      expect(shortAgo(now.subtract(const Duration(hours: 2)), now: now), '2h');
      expect(shortAgo(now.subtract(const Duration(days: 3)), now: now), '3d');
      expect(shortAgo(now.subtract(const Duration(days: 21)), now: now), '3w');
    });
  });
}
