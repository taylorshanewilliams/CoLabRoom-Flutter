/// The week's pushes, in numbers, and the one sentence they add up to.
///
/// Taylor, 14 Sep: "I am not sure if notifications are actually working as
/// pushes to the phone. I've only gotten them to work when I do the test in
/// the options, but never actually gotten a notification to my phone from a
/// real event."
///
/// The server could say that FCM accepted every push to his phone that day,
/// and could not say whether the phone drew a single one. This is what the
/// phone reports back (see push_receipts.dart), summed up on the server by
/// `push_delivery_report` and said here in words. Kept out of the widget so
/// the wording can be pinned by a test that does not need Firebase.
class PushDeliveryReport {
  const PushDeliveryReport({
    required this.sent,
    required this.arrived,
    required this.arrivedClosed,
    this.lastSentAt,
    this.lastArrivedAt,
  });

  factory PushDeliveryReport.fromRow(Map<String, dynamic> row) {
    DateTime? when(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return PushDeliveryReport(
      sent: (row['sent'] as num?)?.toInt() ?? 0,
      arrived: (row['arrived'] as num?)?.toInt() ?? 0,
      arrivedClosed: (row['arrived_closed'] as num?)?.toInt() ?? 0,
      lastSentAt: when(row['last_sent_at']),
      lastArrivedAt: when(row['last_arrived_at']),
    );
  }

  /// Notifications written for this account this week, each of which went
  /// down the real path to the phone.
  final int sent;

  /// How many of those the phone confirmed, whichever way they arrived.
  final int arrived;

  /// How many arrived with the app not in front -- the half of the question
  /// the test button, pressed with the app open, cannot answer.
  final int arrivedClosed;

  final DateTime? lastSentAt;
  final DateTime? lastArrivedAt;

  /// The sentence. Honest about the one thing that makes it misleading: a
  /// phone on an older build shows notifications and reports nothing, so
  /// "none confirmed" on a phone that plainly got them means the build, not
  /// the push.
  String describe({DateTime? now}) {
    if (sent == 0) {
      return 'Nothing has been sent to this account in the last week, so '
          'there is nothing to report yet.';
    }
    final plural = sent == 1 ? 'notification' : 'notifications';
    if (arrived == 0) {
      return '$sent $plural sent this week; this phone has not confirmed '
          'receiving any. Only this build reports back, so if they are '
          'showing up anyway, the phone is on an older one.';
    }
    final reached = arrived == sent
        ? (sent == 1 ? 'it reached this phone' : 'all of them reached this phone')
        : '$arrived reached this phone';
    final closed = arrivedClosed == 0
        ? ''
        : arrivedClosed == arrived
            ? ', every one with the app closed'
            : ', $arrivedClosed with the app closed';
    final last = lastArrivedAt == null
        ? ''
        : ' The last one arrived ${_ago(lastArrivedAt!, now ?? DateTime.now())}.';
    return '$sent $plural sent this week; $reached$closed.$last';
  }

  static String _ago(DateTime time, DateTime now) {
    final gap = now.difference(time);
    if (gap.inMinutes < 1) return 'just now';
    if (gap.inHours < 1) return '${gap.inMinutes} min ago';
    if (gap.inDays < 1) return '${gap.inHours} h ago';
    return '${gap.inDays} d ago';
  }
}
