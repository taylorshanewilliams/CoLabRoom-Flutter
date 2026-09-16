import 'push_delivery_report.dart';

/// Whether this phone has quietly stopped being reachable, and what to say.
///
/// Taylor, 15 September 2026, after a week of notifications that never
/// arrived: his phone had CoLabRoom deep sleeping with its notifications
/// switched off. He had said yes in the app; Android had taken the yes back
/// later, the way it does for apps it decides are unused, and nothing told
/// him. The app knew. It said so on a settings screen he had no reason to
/// open, which is the same as not saying it.
///
/// "How do we make this work for all users, out the gate, and not demand
/// users do so many behind the scenes things." The honest half of the answer
/// is that no app can turn a phone's own restrictions off by itself. The
/// useful half is that noticing takes no taps at all, and that is this.
///
/// Two states are worth interrupting somebody for, and nothing else is:
///
///   1. **Switched off.** The system says notifications are not allowed. A
///      fact, known instantly, no network needed.
///   2. **Not drawing.** They are allowed, pushes went out, and the phone has
///      confirmed none of them. That is the half a permission check cannot
///      see -- a battery restriction eating delivery -- and it is only
///      knowable because of the receipts.
///
/// Pure, so the rule can be tested without a phone.
enum PushTroubleKind {
  /// The system has notifications switched off for this app.
  switchedOff,

  /// Allowed, sent, and never drawn. The phone is holding the app asleep.
  notDrawing,
}

class PushTrouble {
  const PushTrouble({
    required this.kind,
    required this.line,
    required this.detail,
    required this.actionLabel,
  });

  final PushTroubleKind kind;
  final String line;
  final String detail;
  final String actionLabel;
}

/// How many unconfirmed pushes before the app says the phone is not drawing
/// them.
///
/// One proves nothing: a phone can be off, or out of signal, and a single
/// notification can be swiped away before the receipt lands. Three in a week
/// with none confirmed is a pattern rather than a bad evening, and being
/// wrong here means telling somebody their phone is broken when it is not.
const int kUnconfirmedBeforeSaying = 3;

/// The card, or nothing at all.
///
/// [everEnabled] is what keeps this from being a nag. Somebody who has never
/// turned notifications on has not lost anything and is not owed a card about
/// it; the offer belongs at the moment that earns it, which is elsewhere.
/// This is only for people who had it working and lost it without being told.
PushTrouble? pushTrouble({
  required bool? allowed,
  required bool everEnabled,
  PushDeliveryReport? report,
  bool receiptsAreReliable = true,
}) {
  if (!everEnabled) return null;

  if (allowed == false) {
    return const PushTrouble(
      kind: PushTroubleKind.switchedOff,
      line: 'Your phone has switched notifications off',
      detail: 'Android does that to apps it thinks are unused, whatever you '
          'said in here. Nothing can reach you until they are back on.',
      actionLabel: 'Turn on',
    );
  }

  // Unknown is not a problem. A null means the check could not run, and a
  // screen that cries about what it does not know is worse than a quiet one.
  if (allowed != true || report == null) return null;

  // On iOS a missing receipt means almost nothing. Filing one needs the
  // system to wake the app, and iOS throttles that as it pleases -- so a
  // notification can be drawn on the lock screen, read, and dismissed without
  // the app ever running to say so. On 16 September a tester's iPhone got a
  // notification while the server still had it down as unconfirmed.
  //
  // Which would have made this card lie to every iPhone in the worst
  // available way: telling somebody their phone is broken and sending them
  // into their battery settings, while the notifications arrive perfectly
  // well. Android wakes the app for every push -- proven the same night by a
  // 'closed' receipt three seconds after a send -- so the inference is sound
  // there and nowhere else.
  if (!receiptsAreReliable) return null;

  if (report.sent >= kUnconfirmedBeforeSaying && report.arrived == 0) {
    return PushTrouble(
      kind: PushTroubleKind.notDrawing,
      line: 'This phone is not showing notifications',
      detail: '${report.sent} were sent and none arrived. Your phone is '
          'probably holding the app asleep: set its battery use to '
          'unrestricted.',
      actionLabel: 'How',
    );
  }

  return null;
}
