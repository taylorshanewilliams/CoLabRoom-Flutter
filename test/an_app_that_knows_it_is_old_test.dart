import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:colabroom/services/app_release.dart';
import 'package:flutter_test/flutter_test.dart';

/// Both iPhones in the band were on 0.4.0 for three days while the Android
/// phone beside them ran 0.4.1, and nothing anywhere said so. The server now
/// holds the oldest version that still matches everybody else; this is the
/// comparison, and the card it produces.
void main() {
  tearDown(AppRelease.reset);

  group('older than', () {
    test('reads dotted numbers as numbers, not as text', () {
      expect(AppRelease.isOlder('0.4.0', '0.4.1'), isTrue);
      expect(AppRelease.isOlder('0.4.1', '0.4.1'), isFalse);
      expect(AppRelease.isOlder('0.4.2', '0.4.1'), isFalse);
      // "0.4.10" sorts before "0.4.9" as text and after it as a version.
      expect(AppRelease.isOlder('0.4.10', '0.4.9'), isFalse);
      expect(AppRelease.isOlder('0.4.9', '0.4.10'), isTrue);
      // A missing segment is a zero.
      expect(AppRelease.isOlder('0.5', '0.4.9'), isFalse);
      expect(AppRelease.isOlder('0.4', '0.4.1'), isTrue);
    });

    test('ignores a build suffix and never nags over an unreadable string',
        () {
      expect(AppRelease.isOlder('0.4.1+9', '0.4.2'), isTrue);
      expect(AppRelease.isOlder('0.4.2 (c8ab890)', '0.4.2'), isFalse);
      expect(AppRelease.isOlder('local', '0.4.2'), isFalse);
      expect(AppRelease.isOlder('0.4.2', 'unknown'), isFalse);
    });
  });

  group('stale', () {
    test('is nothing until the server has answered', () {
      expect(AppRelease.minimum.value, isNull);
      expect(AppRelease.isStale, isFalse);
    });

    test('is true only below the minimum', () {
      AppRelease.minimum.value = '99.0.0';
      expect(AppRelease.isStale, isTrue);
      AppRelease.minimum.value = '0.0.1';
      expect(AppRelease.isStale, isFalse);
    });
  });

  group('the card', () {
    test('is a chore, not news, and sits ahead of the other chores', () {
      final update = WaitingItem(
        id: 'update-0.4.2',
        kind: WaitingKind.update,
        line: 'A newer CoLabRoom is waiting',
        actionLabel: 'How',
        onAction: () {},
      );
      final request = WaitingItem(
        id: 'r',
        kind: WaitingKind.request,
        who: 'Mara',
        line: 'Mara',
        actionLabel: 'See who',
        onAction: () {},
      );
      final sheet = WaitingItem(
        id: 's',
        kind: WaitingKind.sheet,
        line: 'Buried My Fears',
        actionLabel: 'Make it',
        onAction: () {},
      );
      expect(update.isNews, isFalse);
      expect(update.defaultEyebrow, 'Newer build');
      // A person waiting still outranks it; a song sheet never does.
      expect(update.rank, greaterThan(request.rank));
      expect(update.rank, lessThan(sheet.rank));
    });
  });
}
