import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';
import '../services/push_registration.dart';
import 'app_surface.dart';
import 'offer_notifications.dart';

/// Whether the line has something true to say.
///
/// Pulled out of the widget so the rule can be tested as a rule. Inside a
/// State it is only reachable through a Firebase that will not start in a
/// test binary, which is how you end up with a test that asserts two
/// DateTimes compare the way DateTimes compare.
///
/// Four facts, and every one of them has to hold:
///
///   * something is in the inbox — otherwise there is no cost to report and
///     this becomes a campaign for notifications
///   * this build can do push at all — a switch that cannot do anything is
///     worse than no switch, and must not imply the person did something
///     wrong
///   * no phone is registered — if one is, nothing was missed
///   * nothing has been dismissed since the newest thing arrived
bool shouldOfferPhoneNotifications({
  required DateTime? newest,
  required bool available,
  required bool reachable,
  required DateTime? dismissedAt,
}) {
  if (newest == null) return false;
  if (!available) return false;
  if (reachable) return false;
  if (dismissedAt == null) return true;
  // Strictly after. Dismissing the newest thing you have must silence that
  // thing, or "Not now" would survive exactly one rebuild.
  return newest.isAfter(dismissedAt);
}

/// The offer that comes back, because the first one only ever happened once.
///
/// The welcome flow asks about notifications, in its own words, before it
/// spends the system dialog — which is the right design and was already
/// built. What it is not is repeatable. `welcome_flow_seen_v2` is a flag that
/// survives every app update, so somebody who tapped "Not now", or who was
/// shown nothing because Firebase had not started, is never asked again. The
/// only door left is a switch on the Account screen, which is a thing you
/// have to already know exists.
///
/// So this is the second door, and it opens only when it has something true
/// to say: there are notifications in this inbox, and none of them could have
/// reached the phone, because no token is registered. No notifications, no
/// line. Registered, no line.
///
/// Dismissing it does not silence it forever and does not start a timer
/// either. It records the newest thing in the inbox at the moment of
/// dismissal, and says nothing again until something newer arrives — so "I
/// know" is respected exactly until there is a fresh cost to knowing about.
class MissedOnYourPhone extends StatefulWidget {
  const MissedOnYourPhone({required this.notifications, super.key});

  final List<AppNotification> notifications;

  @override
  State<MissedOnYourPhone> createState() => _MissedOnYourPhoneState();
}

class _MissedOnYourPhoneState extends State<MissedOnYourPhone> {
  static const String _dismissedKey = 'missed_on_phone_dismissed_at';

  bool _show = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_decide());
  }

  @override
  void didUpdateWidget(MissedOnYourPhone old) {
    super.didUpdateWidget(old);
    if (old.notifications.length != widget.notifications.length) {
      unawaited(_decide());
    }
  }

  DateTime? get _newest {
    DateTime? newest;
    for (final notification in widget.notifications) {
      if (newest == null || notification.createdAt.isAfter(newest)) {
        newest = notification.createdAt;
      }
    }
    return newest;
  }

  Future<void> _decide() async {
    // Nothing to miss, nothing to say. This is the whole honesty of the
    // thing: it is not a campaign for notifications, it is a report that
    // something already happened and did not reach you.
    final newest = _newest;
    final available = PushRegistration.isAvailable;

    // Only asked when it could change the answer. `reachesThisAccount` is a
    // round trip, and there is no point spending one to decide whether to
    // draw a line the other three facts have already ruled out.
    final reachable = newest != null && available
        ? await PushRegistration.reachesThisAccount()
        : false;

    DateTime? dismissedAt;
    try {
      final prefs = await SharedPreferences.getInstance();
      final held = prefs.getString(_dismissedKey);
      if (held != null) dismissedAt = DateTime.tryParse(held);
    } catch (_) {
      // A preferences store that will not open is not a reason to withhold
      // the offer; it only means the dismissal cannot be remembered.
    }

    final show = shouldOfferPhoneNotifications(
      newest: newest,
      available: available,
      reachable: reachable,
      dismissedAt: dismissedAt,
    );
    if (mounted) setState(() => _show = show);
  }

  Future<void> _dismiss() async {
    final newest = _newest;
    if (mounted) setState(() => _show = false);
    if (newest == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedKey, newest.toIso8601String());
    } catch (_) {
      // Dismissed for this session either way.
    }
  }

  Future<void> _turnOn() async {
    setState(() => _busy = true);
    // The same two-step the welcome flow uses: our own words first, and the
    // system dialog spent only on somebody who has already said yes. iOS
    // shows that dialog once per install and there is no second chance.
    await offerNotifications(
      context,
      title: 'Want these on your phone?',
      because: 'This all happened while the app was closed, and none of it '
          'reached you. We can tell you next time.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    await _decide();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final count = widget.notifications.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppSurface(
        child: Row(
          children: <Widget>[
            const Icon(Icons.notifications_off_outlined,
                size: 20, color: AppColors.gold),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    count == 1
                        ? 'You missed this one on your phone'
                        : 'You missed these on your phone',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Nothing here reached you while the app was closed.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            if (_busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...<Widget>[
              TextButton(
                key: const Key('missed_dismiss'),
                onPressed: () => unawaited(_dismiss()),
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                child: const Text('Not now'),
              ),
              FilledButton(
                key: const Key('missed_turn_on'),
                onPressed: () => unawaited(_turnOn()),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Turn on'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
