import 'package:flutter/foundation.dart';

/// A take somebody put away, on the day it comes back (migration 0158).
///
/// Every Musician, Same Song, 17 September 2026, from the big swings worth
/// keeping: "A year ago tonight you sealed this. Play it now?" Somebody
/// records an idea and seals it. Until its day it is not among the song's
/// takes, the retention sweep leaves it alone, and nobody else can see it.
/// On the day there is one quiet card, and either answer ends the seal: the
/// take is back among their takes and the card does not come again.
///
/// Nothing here counts anything. There is no tally of seals, no record of
/// which answer was given, and once a seal has ended nothing says there
/// ever was one.
@immutable
class SealedTake {
  const SealedTake({
    required this.id,
    required this.projectId,
    required this.songTitle,
    required this.storagePath,
    required this.sealedAt,
    required this.opensAt,
    this.label = '',
    this.part = 'other',
    this.durationMs = 0,
  });

  /// The take's id in `song_layers`.
  final String id;
  final String projectId;
  final String songTitle;

  /// Where the audio is, for the one player the whole app shares.
  final String storagePath;

  /// What the person typed for it, if they typed anything.
  final String label;
  final String part;
  final int durationMs;

  /// When they sealed it, which is what the card says.
  final DateTime sealedAt;

  /// The day they chose.
  final DateTime opensAt;
}

/// How far off a seal can open, in years. The table refuses anything further
/// (0158): a seal is an exemption from expiry, and one with no end would be
/// storage kept for ever.
const int sealForAtMostYears = 10;

/// A year from [now], at the same time of day.
///
/// The same time rather than midnight, so that a take sealed late one
/// evening comes back late one evening and "a year ago tonight" is true.
/// 29 February lands on 1 March, which is how DateTime carries it.
DateTime aYearOn(DateTime now) =>
    DateTime(now.year + 1, now.month, now.day, now.hour, now.minute);

/// The day somebody picked, at the time of day it is [now].
DateTime onTheDay(DateTime picked, DateTime now) =>
    DateTime(picked.year, picked.month, picked.day, now.hour, now.minute);

/// The first and last days a seal may be set to open.
DateTime earliestSealDay(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1);
DateTime latestSealDay(DateTime now) =>
    DateTime(now.year + sealForAtMostYears, now.month, now.day - 1);

const List<String> _months = <String>[
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "18 September 2027".
String dayInWords(DateTime day) =>
    '${day.day} ${_months[day.month - 1]} ${day.year}';

const List<String> _numbers = <String>[
  'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve',
];

String _inWords(int n) => n >= 2 && n <= 12 ? _numbers[n - 2] : '$n';

/// How long ago a take was sealed, the way somebody would say it: "A year
/// ago tonight", "Three months ago today", "Over a year ago".
///
/// "Tonight" and "today" are only said when it is the day itself -- the same
/// date a whole number of months or years on, or a whole number of weeks.
/// Somebody who opens the app four days late is told "A year ago", which is
/// still true, rather than "tonight", which is not.
String sealedAgo(DateTime sealedAt, DateTime now) {
  final then = sealedAt.toLocal();
  final today = now.toLocal();
  final onTheDay = today.hour >= 17 || today.hour < 4 ? ' tonight' : ' today';

  var months = (today.year - then.year) * 12 + today.month - then.month;
  if (today.day < then.day) months -= 1;

  if (months >= 12) {
    final years = months ~/ 12;
    final said = years == 1 ? 'a year ago' : '${_inWords(years).toLowerCase()} years ago';
    if (months % 12 != 0) return 'Over $said';
    final exact = today.month == then.month && today.day == then.day;
    return '${said[0].toUpperCase()}${said.substring(1)}${exact ? onTheDay : ''}';
  }
  if (months >= 1) {
    final said = months == 1 ? 'A month ago' : '${_inWords(months)} months ago';
    return today.day == then.day ? '$said$onTheDay' : said;
  }

  // Counted in calendar days, in UTC so a clock change cannot make a week
  // six days and a bit.
  final days = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(then.year, then.month, then.day))
      .inDays;
  if (days >= 7) {
    final weeks = days ~/ 7;
    final said = weeks == 1 ? 'A week ago' : '${_inWords(weeks)} weeks ago';
    return days % 7 == 0 ? '$said$onTheDay' : said;
  }
  if (days >= 2) return '${_inWords(days)} days ago';
  if (days == 1) return 'Yesterday';
  return 'Earlier today';
}
