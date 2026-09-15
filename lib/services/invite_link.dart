/// An invitation as a link, so it opens a room rather than an install.
///
/// "Taylor would like you to play bass on 'Weathervane', just that one
/// song" is the best acquisition message a music app can send, and for
/// months it stopped at the last mile: the person got a code and an
/// instruction to install something. The web app is the same account, the
/// same rooms and the same songs in a browser, so the code now travels as a
/// link that opens there. Sign in or sign up on that page and the room is
/// already yours; on a phone the same link works in the browser.
///
/// `from=invite` rides along so an account made this way counts as one
/// that arrived by invitation (0120), which is the channel the plan for the
/// first ten thousand expects to matter most.
const String _webApp = 'https://app.colabroom.com/';

String inviteLink(String code) {
  final clean = code.trim();
  return '$_webApp?invite=${Uri.encodeQueryComponent(clean)}&from=invite';
}

final RegExp _shape = RegExp(r'^[A-Za-z0-9_-]{4,80}$');

/// The code on the address, or null when there is none or it is not one.
String? inviteCodeFrom(Uri address) {
  final raw = address.queryParameters['invite'];
  if (raw == null) return null;
  final code = raw.trim();
  return _shape.hasMatch(code) ? code : null;
}
