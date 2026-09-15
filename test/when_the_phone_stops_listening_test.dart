import 'package:colabroom/services/push_delivery_report.dart';
import 'package:colabroom/services/push_trouble.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card that would have saved a week.
///
/// 15 September 2026. Taylor's phone had CoLabRoom deep sleeping with its
/// notifications switched off, having said yes in the app weeks earlier.
/// Firebase accepted push after push to it and nothing was ever drawn. The
/// app knew the whole time and said so on a settings screen he had no reason
/// to open, which is the same as not saying it.
///
/// He asked how to make this work for everyone without sending people into
/// their phone settings. No app can turn those restrictions off by itself.
/// What it can do is notice with no taps at all, and these pin the rule for
/// when it does.
void main() {
  PushDeliveryReport report({required int sent, required int arrived}) =>
      PushDeliveryReport(sent: sent, arrived: arrived, arrivedClosed: 0);

  test('somebody who never turned them on is never nagged', () {
    // The offer belongs at a moment that earns it, which is not here. A card
    // about losing something you never had is an advert.
    expect(
      pushTrouble(allowed: false, everEnabled: false),
      isNull,
    );
    expect(
      pushTrouble(
        allowed: true,
        everEnabled: false,
        report: report(sent: 9, arrived: 0),
      ),
      isNull,
    );
  });

  test('switched off is said plainly, and blames the phone not the person', () {
    final trouble = pushTrouble(allowed: false, everEnabled: true);
    expect(trouble, isNotNull);
    expect(trouble!.kind, PushTroubleKind.switchedOff);
    expect(trouble.line, contains('switched notifications off'));
    // He said yes. The card must not imply he did not.
    expect(trouble.detail, contains('whatever you said in here'));
    expect(trouble.actionLabel, 'Turn on');
  });

  test('allowed and arriving is nothing to say', () {
    expect(
      pushTrouble(
        allowed: true,
        everEnabled: true,
        report: report(sent: 6, arrived: 6),
      ),
      isNull,
    );
    // Even one confirmed arrival means the phone can draw them.
    expect(
      pushTrouble(
        allowed: true,
        everEnabled: true,
        report: report(sent: 9, arrived: 1),
      ),
      isNull,
    );
  });

  test('one unconfirmed push is not a verdict', () {
    // A phone can be off, or out of signal, and a notification can be swiped
    // away before the receipt lands. Telling somebody their phone is broken
    // on that evidence is worse than saying nothing.
    for (var sent = 1; sent < kUnconfirmedBeforeSaying; sent++) {
      expect(
        pushTrouble(
          allowed: true,
          everEnabled: true,
          report: report(sent: sent, arrived: 0),
        ),
        isNull,
        reason: '$sent sent and none confirmed is not yet a pattern',
      );
    }
  });

  test('sent repeatedly and never drawn names the battery setting', () {
    final trouble = pushTrouble(
      allowed: true,
      everEnabled: true,
      report: report(sent: kUnconfirmedBeforeSaying, arrived: 0),
    );
    expect(trouble, isNotNull);
    expect(trouble!.kind, PushTroubleKind.notDrawing);
    expect(trouble.line, contains('not showing notifications'));
    expect(trouble.detail, contains('unrestricted'));
    // The number matters: it is the evidence, and it is what makes the claim
    // something other than a guess.
    expect(trouble.detail, contains('$kUnconfirmedBeforeSaying were sent'));
  });

  test('not knowing says nothing', () {
    // A null permission means the check could not run, and a null report
    // means the server could not be asked. A screen that cries about what it
    // does not know is worse than a quiet one.
    expect(pushTrouble(allowed: null, everEnabled: true), isNull);
    expect(
      pushTrouble(allowed: true, everEnabled: true, report: null),
      isNull,
    );
  });
}
