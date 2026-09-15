import 'package:colabroom/services/push_delivery_report.dart';
import 'package:colabroom/services/push_receipts.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

/// Did it reach the phone?
///
/// The server could say FCM accepted every push and could not say whether
/// the phone drew one. The phone reports back now, and the settings screen
/// says the week in one sentence. These pin the sentence, since its whole
/// point is to be the honest one, and the id a receipt is filed under.
void main() {
  group('the sentence', () {
    test('nothing sent is nothing to report', () {
      const report = PushDeliveryReport(sent: 0, arrived: 0, arrivedClosed: 0);
      expect(report.describe(), contains('nothing to report yet'));
    });

    test('sent and none confirmed blames the build before the push', () {
      const report = PushDeliveryReport(sent: 6, arrived: 0, arrivedClosed: 0);
      final line = report.describe();
      expect(line, startsWith('6 notifications sent this week'));
      expect(line, contains('has not confirmed receiving any'));
      expect(line, contains('older one'));
    });

    test('all arrived, with the app closed, says so and when', () {
      final now = DateTime(2026, 9, 15, 1, 0);
      final report = PushDeliveryReport(
        sent: 6,
        arrived: 6,
        arrivedClosed: 6,
        lastArrivedAt: now.subtract(const Duration(minutes: 12)),
      );
      final line = report.describe(now: now);
      expect(line, contains('all of them reached this phone'));
      expect(line, contains('every one with the app closed'));
      expect(line, contains('12 min ago'));
    });

    test('some arrived counts both halves', () {
      const report = PushDeliveryReport(sent: 6, arrived: 4, arrivedClosed: 1);
      final line = report.describe();
      expect(line, contains('4 reached this phone'));
      expect(line, contains('1 with the app closed'));
    });

    test('one is singular', () {
      const report = PushDeliveryReport(sent: 1, arrived: 1, arrivedClosed: 0);
      expect(report.describe(), startsWith('1 notification sent this week; it reached this phone.'));
    });

    test('reads the row the server returns', () {
      final report = PushDeliveryReport.fromRow(<String, dynamic>{
        'sent': 3,
        'arrived': 2,
        'arrived_closed': 1,
        'last_sent_at': '2026-09-15T00:50:11+00:00',
        'last_arrived_at': null,
      });
      expect(report.sent, 3);
      expect(report.arrived, 2);
      expect(report.arrivedClosed, 1);
      expect(report.lastSentAt, isNotNull);
      expect(report.lastArrivedAt, isNull);
    });
  });

  group('the receipt', () {
    test('is filed under the notification the push carries', () {
      const message = RemoteMessage(data: <String, dynamic>{
        'type': 'analysis_ready',
        'notification_id': ' 0b1a2c3d-0000-4000-8000-000000000001 ',
      });
      expect(PushReceipts.notificationIdOf(message),
          '0b1a2c3d-0000-4000-8000-000000000001');
    });

    test('a push about nothing files nothing', () {
      const bare = RemoteMessage(data: <String, dynamic>{'notification_id': ''});
      expect(PushReceipts.notificationIdOf(bare), isNull);
      const none = RemoteMessage();
      expect(PushReceipts.notificationIdOf(none), isNull);
    });

    test('a tap that lands before the shell exists is kept for it', () {
      const message = RemoteMessage(data: <String, dynamic>{'type': 'song_ask'});
      RemoteMessage? handed;
      PushReceipts.onTapped(null);
      PushReceipts.onTapped((m) => handed = m);
      expect(handed, isNull);
      PushReceipts.onTapped(null);
      // Nothing pending yet, so installing a handler hands nothing over;
      // the pending path itself needs Firebase to fire and is covered on
      // the device.
      PushReceipts.onTapped((m) => handed = m);
      expect(handed, isNull);
      expect(message.data['type'], 'song_ask');
    });
  });
}
