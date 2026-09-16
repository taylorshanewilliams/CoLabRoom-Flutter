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

/// An invitation or a lesson link names its own door in the path
/// (`/invite/<code>`, `/lesson/<code>`; see invite_link.dart), so it counts
/// as `invite` or `lesson` without carrying a `from`.
String? arrivalCodeFrom(Uri address) {
  final segments = address.pathSegments.where((segment) => segment.isNotEmpty).toList();
  final door = segments.length == 2 && (segments.first == 'invite' || segments.first == 'lesson')
      ? segments.first
      : null;
  final raw = address.queryParameters['from'] ?? address.queryParameters['c'] ?? door;
  if (raw == null) return null;
  final code = raw.trim().toLowerCase();
  return _shape.hasMatch(code) ? code : null;
}
