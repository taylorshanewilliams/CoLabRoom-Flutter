import 'dart:io';

/// What a visit to Takes leaves behind in a song's own audio directory, and
/// which of it is safe to delete on the next visit.
///
/// Two kinds of file are written there. The console writes mixes, `_mix_…`,
/// under a fresh name every time so the player cannot hand back a stale one;
/// the microphone writes recordings, `new_<ms>.m4a`, with the decoded copy
/// the silence check makes beside them. Both are worthless once the visit
/// that made them is over -- a mix is rebuilt from the takes, and a recording
/// that became a take was uploaded and deleted where it was made.
///
/// The sweep used to look only for the `_mix_` prefix, so a recording backed
/// out of part-way -- during the count, or before the take was named -- stayed
/// on the phone for good. Room for one abandoned recording is not much; room
/// for every abandoned recording a band ever makes is a phone filling up for
/// no reason anybody can see.
///
/// Everything else in that directory belongs to somebody: the room's takes
/// are kept there under their layer id, which is a uuid and so cannot begin
/// with either prefix.
bool isSpentAudio(String name) {
  if (name.startsWith('_mix_') && name.endsWith('.wav')) return true;
  // The recording, and the wav Multitrack decoded it into to check it for
  // silence. The decoded copies of the room's takes sit beside these under
  // their own layer ids and are a cache worth keeping; these two are not,
  // because the take they belong to has already been uploaded or given up on.
  if (name.startsWith('new_') &&
      (name.endsWith('.m4a') || name.endsWith('.m4a.pcm.wav'))) {
    return true;
  }
  return false;
}

/// Deletes the spent audio in [dir], leaving alone anything in [inUse].
///
/// [inUse] is every path something is still holding: the mix that is loaded,
/// the file the microphone is writing to this second, and the take an upload
/// is reading from. That last one is why this takes the argument at all -- a
/// take on its way to the room is the only copy of something somebody played,
/// and housekeeping must never be the reason it does not arrive.
///
/// Best effort throughout. A file that will not delete is clutter, not a
/// failure worth showing anybody.
Future<void> sweepSpentAudio(
  Directory dir, {
  Set<String> inUse = const <String>{},
}) async {
  // Matched on the name rather than the whole path. Everything here is one
  // directory deep, so a name is as good as an address -- and a path built as
  // `${dir.path}/name` does not equal the one `list()` hands back on Windows,
  // where the separator it uses is the other one.
  final held = <String>{for (final path in inUse) _nameOf(path)};
  try {
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = _nameOf(entry.path);
      if (!isSpentAudio(name)) continue;
      if (held.contains(name)) continue;
      await entry.delete();
    }
  } catch (_) {
    // Clutter, not a failure worth showing anybody.
  }
}

String _nameOf(String path) => path.split(RegExp(r'[\\/]')).last;
