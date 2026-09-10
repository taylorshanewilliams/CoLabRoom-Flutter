import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/widgets/missed_on_your_phone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The offer that can come back.
///
/// Taylor: "can we not add this to the onboarding? and have it open the
/// prompt from the phone like alot of apps do".
///
/// It was already in the onboarding, and correctly — the welcome flow asks in
/// the app's own words and spends the iOS dialog only on somebody who has
/// already said yes, because iOS shows that dialog once per install and there
/// is no second chance.
///
/// What it is not is repeatable. `welcome_flow_seen_v2` survives every app
/// update, so anybody who tapped "Not now", or who was shown nothing because
/// Firebase had not started, is never asked again — and production has zero
/// device tokens against 184 notifications.
///
/// This is the second door. The rule that keeps it from being a nag is that
/// it can only appear when it has something true to say: there are things in
/// this inbox, and none of them reached the phone.
AppNotification _notification(DateTime at) => AppNotification(
      id: at.toIso8601String(),
      type: NotificationType.projectUpdate,
      title: 'Something happened',
      body: 'While you were away',
      createdAt: at,
    );

Future<void> _pump(
  WidgetTester tester,
  List<AppNotification> notifications,
) async {
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: MissedOnYourPhone(notifications: notifications),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('an empty inbox is never asked anything', (tester) async {
    // The whole honesty of this line is that it reports a cost already paid.
    // With nothing in the inbox there is no cost, and a prompt would just be
    // a campaign for notifications.
    await _pump(tester, const <AppNotification>[]);

    expect(find.byKey(const Key('missed_turn_on')), findsNothing);
  });

  testWidgets('a build with no Firebase does not imply you did something wrong',
      (tester) async {
    // PushRegistration.isAvailable is false here — Firebase never started in
    // a test binary — so there is nothing to offer and the line stays away.
    await _pump(tester, <AppNotification>[
      _notification(DateTime.now().subtract(const Duration(hours: 1))),
    ]);

    expect(find.byKey(const Key('missed_turn_on')), findsNothing,
        reason: 'a switch that cannot do anything is worse than no switch');
  });

  group('the rule', () {
    final newest = DateTime(2026, 9, 8, 12);

    test('an empty inbox has no cost to report', () {
      expect(
        shouldOfferPhoneNotifications(
          newest: null,
          available: true,
          reachable: false,
          dismissedAt: null,
        ),
        isFalse,
      );
    });

    test('a build without push must not imply you did something wrong', () {
      expect(
        shouldOfferPhoneNotifications(
          newest: newest,
          available: false,
          reachable: false,
          dismissedAt: null,
        ),
        isFalse,
      );
    });

    test('a registered phone missed nothing', () {
      expect(
        shouldOfferPhoneNotifications(
          newest: newest,
          available: true,
          reachable: true,
          dismissedAt: null,
        ),
        isFalse,
      );
    });

    test('a real cost, never dismissed, speaks', () {
      expect(
        shouldOfferPhoneNotifications(
          newest: newest,
          available: true,
          reachable: false,
          dismissedAt: null,
        ),
        isTrue,
      );
    });

    test('dismissing the newest thing silences that thing', () {
      // Strictly after, or "Not now" would survive exactly one rebuild.
      expect(
        shouldOfferPhoneNotifications(
          newest: newest,
          available: true,
          reachable: false,
          dismissedAt: newest,
        ),
        isFalse,
      );
    });

    test('and something newer is a fresh cost, so it speaks again', () {
      // A watermark rather than a timer. A timer comes back on a quiet week
      // with nothing to say; this comes back only when something arrived
      // that missed you.
      expect(
        shouldOfferPhoneNotifications(
          newest: newest.add(const Duration(days: 1)),
          available: true,
          reachable: false,
          dismissedAt: newest,
        ),
        isTrue,
      );
    });

    test('an older thing than the dismissal stays quiet', () {
      expect(
        shouldOfferPhoneNotifications(
          newest: newest.subtract(const Duration(days: 1)),
          available: true,
          reachable: false,
          dismissedAt: newest,
        ),
        isFalse,
      );
    });
  });
}
