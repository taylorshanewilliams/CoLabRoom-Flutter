import 'package:flutter/foundation.dart';

import '../../domain/sealed_take.dart';
import 'waiting_on_you.dart';

/// A sealed take's one card, on the day it comes back.
///
/// Every Musician, Same Song, 17 September 2026: "A year ago tonight you
/// sealed this. Play it now?" -- and "Not now" ends it for good, with no
/// repeat and no count. The sentence is the plan's, split where the card
/// splits everything: when goes above, in the eyebrow, and the rest is the
/// title. A card in Home's row gets two lines of title on a phone, and the
/// whole sentence on one Text was cut off before it reached the question.
///
/// Kept out of the screen so the words can be read in a test, the way
/// sending_a_take.dart keeps its own.
///
/// Quiet on purpose. No face and no filled button: nobody did this to you,
/// and it is not news. Both answers end the seal. Playing it is [onPlay]; the
/// x is "Not now", and it is the permanent kind of dismissal, not the
/// session's -- the take goes back among the song's takes either way, and
/// nothing anywhere remembers which answer it was.
/// What Home says when "Play it" could not make a sound.
///
/// The seal has ended all the same, so this is where the take now is: a weak
/// connection on the one evening it was offered must not read as the idea
/// being lost.
String sealedTakeIsBackWords(SealedTake take) =>
    'It is back among the takes on ${take.songTitle}.';

WaitingItem sealedTakeCard(
  SealedTake take, {
  required DateTime now,
  required VoidCallback onPlay,
  required VoidCallback onNotNow,
}) {
  return WaitingItem(
    id: 'sealed-${take.id}',
    kind: WaitingKind.sealed,
    eyebrow: sealedAgo(take.sealedAt, now),
    line: 'You sealed this. Play it now?',
    // Which song, because a year is long enough to forget, and what they
    // called it if they called it anything.
    about: take.label.trim().isEmpty
        ? take.songTitle
        : '${take.label.trim()} · ${take.songTitle}',
    actionLabel: 'Play it',
    onAction: onPlay,
    onDismiss: onNotNow,
    dismissLabel: 'Not now',
  );
}
