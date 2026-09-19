import 'package:flutter/foundation.dart';

import '../../domain/music_models.dart';
import 'waiting_on_you.dart';

/// A set for a day, and one quiet card for each of you.
///
/// Every Musician, Same Song, 17 September 2026, worship teams item 2: "the
/// dated set practised during the week, with one quiet card per member.
/// Leaders never see who opened it." A set with a day on it (0164) puts one
/// card on the Home of everybody in the rooms its songs live in, from a week
/// out until the day goes by. Tapping it opens the set's songs in Perform,
/// in the running order and each in the key the set does it in.
///
/// What it deliberately does not do is the whole design. There is no push
/// and no reminder: the card is on Home when the app is opened and nowhere
/// else. It never says "not practised", never counts anything and never
/// counts down — it names the day, and a person who knows what day it is
/// knows how long they have. And nothing anywhere records that it was
/// opened, so the question "who has looked at Sunday's set?" has no answer
/// to give a leader rather than a hidden one.
///
/// Kept out of the screen so the words and the window can be read in a test,
/// the way sealed_take_card.dart keeps its own.

/// How far out the card appears: the week before the day.
///
/// The plan's word is "during the week", and a week is what makes the card
/// worth having — long enough to learn the songs in, short enough that a set
/// dated for Easter is not sitting on somebody's Home in February.
const int setCardDaysAhead = 7;

/// The day part of [when], with the time thrown away.
DateTime dayOf(DateTime when) => DateTime(when.year, when.month, when.day);

/// Whether [set]'s card belongs on Home on [today].
///
/// From a week out, and gone the day after the day: a set is still the set
/// on the morning it is for, and the moment Sunday is over it is history.
bool setIsForTheWeekOf(Setlist set, DateTime today) {
  final day = set.forDay;
  if (day == null || set.songs.isEmpty) return false;
  final from = dayOf(today);
  final until = DateTime(from.year, from.month, from.day + setCardDaysAhead);
  final on = dayOf(day);
  return !on.isBefore(from) && !on.isAfter(until);
}

/// The sets with a card on Home today, soonest first.
List<Setlist> setsForTheWeek(Iterable<Setlist> sets, DateTime today) {
  final showing = <Setlist>[
    for (final set in sets)
      if (setIsForTheWeekOf(set, today)) set,
  ]..sort((a, b) {
      final byDay = a.forDay!.compareTo(b.forDay!);
      return byDay != 0 ? byDay : a.id.compareTo(b.id);
    });
  return showing;
}

const List<String> _weekdays = <String>[
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

const List<String> _months = <String>[
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The day said the way somebody would say it: "Sunday", or "Sunday 4
/// October" when a weekday on its own would not say which.
///
/// Never a countdown. "In 2 days" is the sentence this app does not write:
/// it is a number about you rather than a fact about the set, and a card
/// that counts down is a card that nags. Inside the coming six days a
/// weekday names exactly one day and needs nothing after it; a week out,
/// "Sunday" could be either Sunday, so the date is said.
String setDayNamed(DateTime day, DateTime today) {
  final on = dayOf(day);
  final from = dayOf(today);
  final ahead = on.difference(from).inDays;
  final weekday = _weekdays[on.weekday - 1];
  if (ahead >= 0 && ahead < 7) return weekday;
  return '$weekday ${on.day} ${_months[on.month - 1]}';
}

/// The whole day, for where there is no "today" to count from: "Sunday 4
/// October 2026", on the set's own screen where the person setting it needs
/// to be sure which one they picked.
String setDayInFull(DateTime day) {
  final on = dayOf(day);
  return '${_weekdays[on.weekday - 1]} ${on.day} '
      '${_months[on.month - 1]} ${on.year}';
}

/// The one card, in the row's own grammar.
///
/// The set's name goes in the eyebrow and the day in the title, which is the
/// way round the card is read: the eyebrow says what kind of thing this is
/// ("Morning service") and the line is the thing itself. No face, because
/// nobody did this to you; no detail line, because a count of songs is a
/// count and the set is what is on the other side of the tap.
///
/// No dismissal is given, so the x hides it until the app is opened again.
/// That is the honest answer for a card that is not asking anything: there
/// is nothing to decline, the set is still on Sunday, and a permanent no
/// would be how somebody misses it. It also means nothing at all is written
/// when the card is answered, which is the promise this slice is made of.
WaitingItem setForDayCard(
  Setlist set, {
  required DateTime today,
  required VoidCallback onOpen,
}) {
  return WaitingItem(
    id: 'set-day-${set.id}',
    kind: WaitingKind.setDay,
    eyebrow: set.name,
    line: 'The set for ${setDayNamed(set.forDay!, today)}',
    actionLabel: 'Open',
    onAction: onOpen,
  );
}
