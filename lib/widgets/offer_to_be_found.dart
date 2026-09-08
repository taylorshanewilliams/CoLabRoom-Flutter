import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/colabroom_theme.dart';
import '../data/music_repository.dart';
import '../domain/music_models.dart';
import '../domain/musical_roles.dart';

/// Asking somebody whether they would like to be findable, at the one moment
/// it is obviously fair to ask.
///
/// **Almost nobody in production is findable.** One real account of four, with
/// the seeded ones purged — so the room a new invitee walks into has one
/// person in it. Nobody says what they play either, which is the second lock
/// on the same door: `find_musicians` matches on `plays`, so an empty one is
/// invisible to every role search even after the switch is on.
///
/// None of that is a bug. `discoverable` defaults to false and that is the
/// right default for this app — you do not turn strangers on. But **off by
/// default and never asked are different things**, and the only place that
/// asks is a button on your own profile page, shown to the population that
/// least needs telling.
///
/// So it is asked here, where it is reciprocal: somebody is standing in the
/// room looking for a bass player. "Can they look for you?" is a fair
/// question at that moment and an intrusive one at any other.
///
/// **And it says what it will do before it does it.** The dialog names what
/// becomes visible, promises private work stays private, and says it can be
/// undone — because a privacy switch flipped by a prompt somebody did not
/// fully read is worse than one nobody ever turned on.
abstract final class BeFound {
  /// When we last asked and were told no.
  ///
  /// A decline is an answer with a shelf life, not a permanent one — people
  /// join a band in March and want to be found in April. A month is long
  /// enough that it never feels like nagging and short enough that changing
  /// your mind does not require finding a settings page.
  static const String _declinedKey = 'be_found_declined_at';
  static const Duration _askAgainAfter = Duration(days: 30);

  /// Offers it, and reports whether anything changed.
  ///
  /// Silent when they are already findable, when we asked recently, or when
  /// their profile cannot be read — a prompt that appears because a network
  /// call failed is a prompt that appears at random.
  ///
  /// [becauseTheyAsked] is for the version of this that somebody pressed. The
  /// shelf life on a decline is there to stop the *unprompted* ask becoming a
  /// nag, and applying it to a button somebody deliberately tapped would make
  /// that button do nothing — which is the one thing worse than never asking.
  static Future<bool> offer(
    BuildContext context,
    MusicRepository repository, {
    bool becauseTheyAsked = false,
  }) async {
    Musician? me;
    try {
      me = await repository.loadMusician(repository.currentUserId);
    } catch (_) {
      return false;
    }
    if (me == null || me.discoverable == true) return false;

    final prefs = await SharedPreferences.getInstance();
    final declined = becauseTheyAsked ? null : prefs.getInt(_declinedKey);
    if (declined != null) {
      final when = DateTime.fromMillisecondsSinceEpoch(declined);
      if (DateTime.now().difference(when) < _askAgainAfter) return false;
    }

    // What they have actually played and never said they play.
    //
    // The second half of the fix, and the half that makes the switch worth
    // anything: turning discoverable on while `plays` is empty puts somebody
    // in "everybody" and in no search anybody would run. From shared takes
    // only — the same rule things_we_noticed uses, because a private draft is
    // nobody's evidence of anything, including their own.
    final claimed = me.plays.toSet();
    final unclaimed = me.partsRecorded.keys
        .where((part) => !claimed.contains(part))
        .toList(growable: false);

    if (!context.mounted) return false;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: const Text('Can they find you too?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'You are looking for people who play. Nobody can look for you '
              'yet.\n\n'
              'Turning this on puts your name, what you play and anything you '
              'have already shared on the Open Mic. Your private work stays '
              'private, and you can turn it off whenever you like.',
              style: TextStyle(height: 1.45),
            ),
            if (unclaimed.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                // Said out loud rather than done quietly. This is a claim
                // about somebody, made from their own recordings, and they
                // get to see it before it is on their profile.
                'We will also say you play ${_list(unclaimed)}, '
                'because you have.',
                style: const TextStyle(
                    color: AppColors.cyan, fontSize: 13, height: 1.45),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Let them find me'),
          ),
        ],
      ),
    );

    if (yes != true) {
      await prefs.setInt(_declinedKey, DateTime.now().millisecondsSinceEpoch);
      return false;
    }

    await repository.setOpenMicPresence(
      discoverable: true,
      plays: <String>[...me.plays, ...unclaimed],
    );
    return true;
  }

  /// "bass and keys", or "bass, keys and drums".
  static String _list(List<String> parts) {
    final words = parts
        .map((part) => MusicalRole.labelFor(part).toLowerCase())
        .toList(growable: false);
    if (words.length == 1) return words.first;
    return '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
  }
}
