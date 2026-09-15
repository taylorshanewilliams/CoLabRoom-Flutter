/// The code a person arrived with, if the address carried one.
///
/// A flier on a board, a card on a merch table, a link under a video: each
/// carries `colabroom.com/chords?c=orl-wp`, the tool keeps the code and
/// passes it on to the app as `?from=orl-wp`, and an account made or signed
/// into from that address claims it once (0120). The code names a place,
/// never a person, and a week later it is the answer to "which board
/// worked".
///
/// Pure, so the rule can be tested without a browser: lower-case letters,
/// digits and hyphens, at most thirty-two of them, or nothing. Anything else
/// in the address bar is ignored rather than argued with.
final RegExp _shape = RegExp(r'^[a-z0-9-]{1,32}$');

String? arrivalCodeFrom(Uri address) {
  final raw = address.queryParameters['from'] ?? address.queryParameters['c'];
  if (raw == null) return null;
  final code = raw.trim().toLowerCase();
  return _shape.hasMatch(code) ? code : null;
}
