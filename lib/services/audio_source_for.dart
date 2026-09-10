import 'package:audioplayers/audioplayers.dart';

/// Hands the player whichever kind of source it has been given.
///
/// Everything in this app used to hold audio as a **local file path**: the
/// services downloaded bytes into a temporary directory and returned the
/// path, and every play site wrote `DeviceFileSource(path)`. That is right on
/// a phone, where a file survives the screen that fetched it and the player
/// can seek into it without asking the network anything.
///
/// It is not available in a browser at all. There is no filesystem, and
/// `path_provider` has no web implementation — which is not a graceful
/// degradation but a `MissingPluginException` thrown out of
/// `getApplicationDocumentsDirectory`. That is the exception behind Taylor's
/// first-ever bug report on 2026-09-10: "tried to do a take but it said
/// recording couldnt be loaded?"
///
/// So on the web the same services return a **signed URL** instead, and this
/// decides which source to build. Signing is the permission check — Supabase
/// applies row level security when the URL is created, not when it is used —
/// so a URL only exists for a recording the person asking was already allowed
/// to hear.
///
/// Matched on the scheme rather than on `kIsWeb`, deliberately. The caller
/// should not have to know which platform produced the string it is holding,
/// and a URL handed to a phone works there too.
Source audioSourceFor(String pathOrUrl) {
  final trimmed = pathOrUrl.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return UrlSource(trimmed);
  }
  return DeviceFileSource(trimmed);
}

/// Whether this string is something only a browser could have produced.
///
/// Used where the difference genuinely matters — a local file can be handed
/// to a decoder or a mixdown, and a URL cannot.
bool isRemoteAudio(String pathOrUrl) {
  final trimmed = pathOrUrl.trim();
  return trimmed.startsWith('http://') || trimmed.startsWith('https://');
}
