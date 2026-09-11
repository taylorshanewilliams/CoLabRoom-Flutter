import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:flutter_test/flutter_test.dart';

/// One place, and not one shape.
///
/// Taylor: "lets find a way to have all suggestions, notifications, continue
/// working, friend requests etc all in one place" — and then, on the first
/// version: "one bar might be to limiting, what can we do to make it feel
/// exciting and fun and helpful above all, intuitive and seamless without
/// being intrusive and annoying."
///
/// The flaw was flattening. "Jess added a bass take at midnight" and "make
/// the song sheet" are not two instances of one category: the first is a
/// person doing something for your song while you were asleep, and the second
/// is a chore that will be equally true tomorrow.
WaitingItem _news({DateTime? at}) => WaitingItem(
      id: 'n1',
      kind: WaitingKind.news,
      who: 'Jess',
      about: 'Midnight Signal',
      at: at,
      line: 'Jess added a recording',
      actionLabel: 'Hear it',
      onAction: () {},
    );

WaitingItem _chore() => WaitingItem(
      id: 's1',
      kind: WaitingKind.sheet,
      line: 'Make the song sheet for Buried My Fears',
      actionLabel: 'Make it',
      onAction: () {},
      onDismiss: () {},
    );

void main() {
  test('a person doing something is news; a chore never is', () {
    // The whole distinction the first version threw away.
    expect(_news().isNews, isTrue);
    expect(_chore().isNews, isFalse);
  });

  test('a chore with somebody attached is still a chore', () {
    // Guard against the obvious future mistake: the sheet suggestion knowing
    // who recorded the audio does not make "make the song sheet" exciting.
    const sheetWithPerson = WaitingItem(
      id: 's2',
      kind: WaitingKind.sheet,
      who: 'Jess',
      line: 'Make the song sheet',
      actionLabel: 'Make it',
      onAction: _nothing,
    );
    expect(sheetWithPerson.isNews, isFalse);
  });

  group('when, said the way somebody would say it', () {
    // "Overnight" is the one worth having. It is the whole promise of an app
    // for people who are never free at the same time, and no number says it.
    final morning = DateTime(2026, 9, 11, 8);

    test('overnight, read in the morning', () {
      expect(
        _LeadWhen.of(morning.subtract(const Duration(hours: 9)), now: morning),
        'overnight',
      );
    });

    test('not overnight when read in the evening', () {
      final evening = DateTime(2026, 9, 11, 21);
      expect(
        _LeadWhen.of(evening.subtract(const Duration(hours: 9)), now: evening),
        isNot('overnight'),
      );
    });

    test('minutes stay minutes', () {
      expect(
        _LeadWhen.of(morning.subtract(const Duration(minutes: 20)),
            now: morning),
        '20 minutes ago',
      );
    });

    test('anything old enough stops being counted', () {
      // "You left this 63 weeks ago" is a statistic. Nobody needs the number.
      expect(
        _LeadWhen.of(morning.subtract(const Duration(days: 400)), now: morning),
        'a while back',
      );
    });
  });
}

void _nothing() {}

/// Reaches the private lead card's formatter through the public surface the
/// widget exposes for exactly this.
abstract final class _LeadWhen {
  static String of(DateTime at, {DateTime? now}) =>
      leadCardWhen(at, now: now);
}
