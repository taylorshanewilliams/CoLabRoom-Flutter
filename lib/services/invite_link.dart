/// An invitation as a link, so it opens a room rather than an install.
///
/// "Taylor would like you to play bass on 'Weathervane', just that one
/// song" is the best acquisition message a music app can send, and for
/// months it stopped at the last mile: the person got a code and an
/// instruction to install something. The web app is the same account, the
/// same rooms and the same songs in a browser, so the code now travels as a
/// link that opens there. Sign in or sign up on that page and the room is
/// already yours; on a phone with the app installed the same link opens the
/// app instead (see IncomingAddresses and the App Links in the manifest).
///
/// The code is the path -- `/invite/<code>`, `/lesson/<code>` -- rather than
/// a query, for two reasons. A phone claims links by path, and the paths it
/// claims must leave the root to the browser: password resets and account
/// deletion land on `app.colabroom.com/?...` and only work on the web. And a
/// shorter link is a less dense QR code, which scans from further across a
/// room. The query form (`?invite=`, `?lesson=`) came first and is still
/// read, so nothing already sent or printed stops working.
///
/// The path names the door, so an account made this way still counts as one
/// that arrived by invitation or lesson (0120; see arrivalCodeFrom).
const String _webApp = 'https://app.colabroom.com/';

String inviteLink(String code) {
  final clean = code.trim();
  return '${_webApp}invite/${Uri.encodeComponent(clean)}';
}

final RegExp _shape = RegExp(r'^[A-Za-z0-9_-]{4,80}$');

/// The code a link carries under [key]: `/<key>/<code>`, or the older
/// `?<key>=<code>`.
String? _codeOn(Uri address, String key) {
  final segments = address.pathSegments.where((segment) => segment.isNotEmpty).toList();
  if (segments.length == 2 && segments.first == key) return segments.last;
  return address.queryParameters[key];
}

/// The code on the address, or null when there is none or it is not one.
String? inviteCodeFrom(Uri address) {
  final raw = _codeOn(address, 'invite');
  if (raw == null) return null;
  final code = raw.trim();
  return _shape.hasMatch(code) ? code : null;
}

/// A teacher's lesson link (0129): whoever opens it gets their own room
/// with the teacher. The same web app as an invitation, a different door,
/// so the shell can tell "join this room" from "make me one".
String lessonLink(String code) {
  final clean = code.trim().toLowerCase();
  return '${_webApp}lesson/${Uri.encodeComponent(clean)}';
}

final RegExp _lessonShape = RegExp(r'^[0-9a-f]{12}$');

/// Twelve hex characters, however they were written: with the dashes the
/// screen shows, in capitals, with a space from a phone keyboard.
String? _lessonCode(String raw) {
  final cleaned = raw.toLowerCase().replaceAll(RegExp(r'[^0-9a-z]'), '');
  return _lessonShape.hasMatch(cleaned) ? cleaned : null;
}

/// The lesson code on the address, or null when there is none.
String? lessonCodeFrom(Uri address) {
  final raw = _codeOn(address, 'lesson');
  return raw == null ? null : _lessonCode(raw);
}

/// A lesson code in whatever somebody typed or pasted into "Join with a
/// code": the whole link, or the code on its own. Null for anything else,
/// which includes an invitation's much longer code.
String? lessonCodeFromText(String text) {
  final trimmed = text.trim();
  if (trimmed.contains('lesson=') || trimmed.contains('/lesson/')) {
    final address = Uri.tryParse(trimmed);
    return address == null ? null : lessonCodeFrom(address);
  }
  return _lessonCode(trimmed);
}

/// The code the way a person reads it off a wall: abcd-ef01-2345.
String lessonCodeSaid(String code) {
  final clean = code.toLowerCase();
  if (clean.length != 12) return clean;
  return '${clean.substring(0, 4)}-${clean.substring(4, 8)}-${clean.substring(8)}';
}

/// Somebody's code for meeting in person (0130): `/add/<code>` opens their
/// card, so the two of you can add each other. Eight characters from an
/// alphabet with no i, l, o or u, because it gets read out over a band.
String meetingLink(String code) => '${_webApp}add/${Uri.encodeComponent(code.trim().toLowerCase())}';

final RegExp _meetingShape = RegExp(r'^[0-9a-hjkmnp-tv-z]{8}$');

/// What somebody typed, the way it is stored -- the same rule as
/// `private.clean_meeting_code`: no dashes or spaces, lower case, and the
/// letters people read as digits read as those digits.
String? _meetingCode(String raw) {
  final cleaned = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^0-9a-z]'), '')
      .replaceAll('o', '0')
      .replaceAll(RegExp('[il]'), '1');
  return _meetingShape.hasMatch(cleaned) ? cleaned : null;
}

/// The meeting code on an address, or null when there is none.
String? meetingCodeFrom(Uri address) {
  final raw = _codeOn(address, 'add');
  return raw == null ? null : _meetingCode(raw);
}

/// A meeting code in whatever somebody typed or pasted: the whole link, or
/// the code on its own.
String? meetingCodeFromText(String text) {
  final trimmed = text.trim();
  if (trimmed.contains('/add/')) {
    final address = Uri.tryParse(trimmed);
    return address == null ? null : meetingCodeFrom(address);
  }
  return _meetingCode(trimmed);
}

/// The code the way it is read out: k7m2-9xqp.
String meetingCodeSaid(String code) {
  final clean = code.toLowerCase();
  if (clean.length != 8) return clean;
  return '${clean.substring(0, 4)}-${clean.substring(4)}';
}
