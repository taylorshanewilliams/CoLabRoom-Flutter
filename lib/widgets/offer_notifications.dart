import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../services/push_registration.dart';

/// Asking to be allowed to tell somebody something, at the moment they would
/// want to be told.
///
/// **Nobody has ever turned push on.** Not one device token exists in
/// production, and the machinery is fine — Firebase comes up at launch,
/// tokens re-register, the trigger hands rows to the sender, the sender is
/// configured. The switch is in Account → Notifications, and nobody goes
/// looking in settings for a thing they have not missed yet.
///
/// The ask bar had the right idea and the wrong scope: it offers this when
/// somebody asks their own room for a part, which is one uncommon path. The
/// moments that actually matter now are putting a song on the Open Mic,
/// asking a particular musician, and starting something with somebody — all
/// of which end with a person waiting on an answer from somebody else, which
/// is exactly the condition a notification is for.
///
/// **Our dialog first, the system one only through a yes.** On iOS the
/// permission prompt can be shown once for the life of an install; a no there
/// is permanent and undoable only in Settings, which nobody does. So the
/// cheap reversible question is asked first and the expensive irreversible
/// one is spent only on somebody who has already said they want it.
///
/// Silent when it has nothing to offer: no Firebase in this build, or
/// permission already granted. It never asks twice in a row for the same
/// thing, because the whole point is not being a nuisance.
Future<void> offerNotifications(
  BuildContext context, {
  required String title,
  required String because,
}) async {
  if (!PushRegistration.isAvailable) return;
  if (await PushRegistration.isAllowed()) return;
  if (!context.mounted) return;

  final wants = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.raised,
      title: Text(title),
      content: Text(because),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Yes, tell me'),
        ),
      ],
    ),
  );
  if (wants != true) return;
  await PushRegistration.enable();
}
