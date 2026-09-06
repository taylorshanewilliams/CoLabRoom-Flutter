/// Naming an idea after what is in it.
///
/// A library of "Recording 8/23 11:40" is the single most common reason
/// captured ideas are never revisited: you cannot skim audio, so an un-named
/// take is one you have to play to identify, and eighty of them is a pile
/// nobody digs through.
///
/// These moved here when studio_drafts was retired. They were the one part of
/// that service worth keeping — everything else it did, the project side
/// already did.

/// Does this name carry any information, or is it just when the file
/// happened to be created?
///
/// "Recording 8/23 11:40", "New Recording 12", "audio_2026_08_23.m4a" — the
/// universal failure mode of idea capture is a library of eighty files named
/// like this, none of which anyone can identify without playing them. A name
/// matching one of these shapes is safe to replace with something the
/// recording actually says.
bool looksAutoNamed(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final withoutExtension = trimmed.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '');
  // No \b after the keyword: underscore is a word character, so `audio\b`
  // refuses to match "audio_2026_08_23" — one of the commonest shapes there
  // is. The trailing character class does the work instead, which also keeps
  // "Audiophile demo" from being treated as a placeholder.
  return RegExp(
    r'^(new\s+)?(recording|voice\s*memo|audio|track|untitled|idea)[\s\d/:._-]*$',
    caseSensitive: false,
  ).hasMatch(withoutExtension);
}

/// A name for an idea, taken from the first words actually sung in it.
///
/// Returns null when there's nothing usable, so the caller keeps whatever
/// name it already had rather than replacing a real title with a fragment.
String? nameFromTranscript(String? transcript, {int maxWords = 6, int maxChars = 48}) {
  final cleaned = (transcript ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length < 3) return null;
  final words = cleaned.split(' ').where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return null;
  var title = words.take(maxWords).join(' ');
  if (title.length > maxChars) title = title.substring(0, maxChars).trimRight();
  // Strip trailing punctuation so a title doesn't end mid-sentence on a comma.
  title = title.replaceFirst(RegExp(r'[,;:.\-—]+$'), '').trim();
  return title.isEmpty ? null : title;
}
