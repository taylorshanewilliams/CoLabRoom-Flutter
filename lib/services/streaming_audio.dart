import 'package:supabase_flutter/supabase_flutter.dart';

/// Turning a stored recording into something a player can stream.
///
/// Everything else in this app downloads audio before it plays it —
/// `storage.download()` pulls the whole file into memory and the player reads
/// bytes or a local file. That is right for a workspace, where you open one
/// song and then work on it for an hour, and completely wrong for listening
/// through a feed: it means waiting for an entire song to arrive before
/// hearing a second of it, and holding every song you scrolled past in memory.
///
/// A signed URL is the other shape. The player fetches it over HTTP, which
/// gets range requests and progressive playback for free, and starts on the
/// first few kilobytes rather than the last.
///
/// **Signing is the permission check.** Supabase applies row level security
/// when the URL is created, not when it is used — so a URL only exists for a
/// recording the person asking was already allowed to hear. After that the
/// URL itself is the credential, which is why they are short-lived and why
/// this never hands one to anybody it did not sign for.
class StreamingAudio {
  StreamingAudio({SupabaseClient? client, this.bucket = 'room-files'})
      : _clientOverride = client;

  final SupabaseClient? _clientOverride;
  final String bucket;

  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  /// How long a signed URL lasts.
  ///
  /// Long enough to listen to a song and the few after it without a
  /// re-sign mid-scroll; short enough that a leaked link is a leaked
  /// afternoon rather than a leaked recording. Cached entries are retired
  /// early by [_safetyMargin] so a URL is never handed out moments before it
  /// stops working.
  static const Duration ttl = Duration(hours: 2);
  static const Duration _safetyMargin = Duration(minutes: 5);

  final Map<String, _Signed> _cache = <String, _Signed>{};

  /// Signs a whole page at once.
  ///
  /// One request for twelve tracks rather than twelve requests, which is the
  /// difference between a feed that can preload and one that stutters every
  /// time somebody swipes. Paths already held and still fresh are not asked
  /// for again.
  Future<Map<String, String>> urlsFor(Iterable<String> storagePaths) async {
    final wanted = storagePaths.toSet();
    final now = DateTime.now();
    final result = <String, String>{};
    final missing = <String>[];

    for (final path in wanted) {
      final held = _cache[path];
      if (held != null && held.expiresAt.isAfter(now.add(_safetyMargin))) {
        result[path] = held.url;
      } else {
        missing.add(path);
      }
    }
    if (missing.isEmpty) return result;

    final signed = await _client.storage
        .from(bucket)
        .createSignedUrls(missing, ttl.inSeconds);

    for (final entry in signed) {
      final path = entry.path;
      _cache[path] = _Signed(entry.signedUrl, now.add(ttl));
      result[path] = entry.signedUrl;
    }
    return result;
  }

  /// One path, for the cases that only have one.
  Future<String?> urlFor(String storagePath) async {
    final urls = await urlsFor(<String>[storagePath]);
    return urls[storagePath];
  }

  /// Whether a path is already playable without a network round trip.
  ///
  /// The feed asks this before it decides whether swiping needs to wait on
  /// anything.
  bool isReady(String storagePath) {
    final held = _cache[storagePath];
    return held != null &&
        held.expiresAt.isAfter(DateTime.now().add(_safetyMargin));
  }

  /// Forgets everything. Called when somebody signs out, because a signed URL
  /// outlives the session that made it and should not.
  void clear() => _cache.clear();

  /// How many URLs are held. Only for tests and diagnostics.
  int get cached => _cache.length;
}

class _Signed {
  const _Signed(this.url, this.expiresAt);

  final String url;
  final DateTime expiresAt;
}
