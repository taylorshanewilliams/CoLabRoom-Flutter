import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'streaming_audio.dart';

/// The one thing making a sound.
///
/// Once every list has a play button, the obvious implementation — a player
/// per row — is the wrong one: two taps make two songs, and a phone playing
/// two pieces of music at once is not a bug anybody has to be told about.
/// Sound is a single physical resource and this models it as one.
///
/// So there is exactly one player in the app, and starting anything stops
/// whatever was going. Every surface asks the same object what is playing,
/// which is also what makes a row in a list and the full-screen stage agree
/// without either knowing about the other.
///
/// **It never decides who may hear what.** It is handed a storage path and
/// asks [StreamingAudio] to sign it; signing is where row level security
/// applies. A path this object cannot sign simply does not play, which is the
/// correct outcome and needs no check here.
class NowPlaying extends ChangeNotifier {
  NowPlaying._();

  /// The app's player. A singleton because the speaker is.
  static final NowPlaying instance = NowPlaying._();

  final AudioPlayer _player = AudioPlayer();
  final StreamingAudio streams = StreamingAudio();

  StreamSubscription<Duration>? _positions;
  StreamSubscription<void>? _completions;
  bool _wired = false;

  String? _path;
  String _title = '';
  String _byline = '';
  String? _songId;
  bool _playing = false;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration? _length;

  /// What is loaded, playing or paused. Null when nothing is.
  String? get path => _path;

  /// What to call it, for anything drawing a bar rather than a button.
  ///
  /// Carried here rather than looked up, because the thing showing the bar is
  /// the shell — which has no idea what song a path belongs to and should not
  /// have to fetch one to draw a title.
  String get title => _title;
  String get byline => _byline;

  /// The song this came from, so a bar can be tapped through to it. Null when
  /// whatever started it did not say.
  String? get songId => _songId;

  bool get playing => _playing;

  /// True between the tap and the first sound. A row that looks inert for the
  /// second it takes to sign and buffer gets tapped again.
  bool get loading => _loading;

  Duration get position => _position;
  Duration? get length => _length;

  /// Called when a track finishes on its own, so a feed can move on. Set by
  /// whoever is driving a session; cleared when they leave.
  VoidCallback? onFinished;

  /// Called once per song when somebody has actually listened to it.
  ///
  /// Set once, at startup, by whatever can reach the repository. The player
  /// knows when a song has been playing and for how long; it has no business
  /// knowing how a listen is recorded.
  void Function(String songId)? onListened;

  /// How much of a song counts as having listened to it.
  ///
  /// Somebody who skips after two seconds did not listen, and counting them
  /// would make the number reassuring and useless.
  static const Duration listenedAfter = Duration(seconds: 10);

  /// The song already counted, so a track playing for four minutes reports
  /// once rather than every position update.
  String? _counted;

  /// Whether [storagePath] is the one currently loaded.
  bool isCurrent(String storagePath) =>
      _path != null && _path == storagePath && storagePath.isNotEmpty;

  /// How far through, 0..1, or null when the length is not known yet.
  double? get fraction {
    final total = _length?.inMilliseconds ?? 0;
    if (total <= 0) return null;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    _positions = _player.onPositionChanged.listen((where) {
      _position = where;
      final song = _songId;
      if (song != null &&
          _counted != song &&
          where >= listenedAfter) {
        _counted = song;
        onListened?.call(song);
      }
      notifyListeners();
    });
    _completions = _player.onPlayerComplete.listen((_) {
      _playing = false;
      _position = Duration.zero;
      notifyListeners();
      onFinished?.call();
    });
  }

  /// Plays [storagePath], or pauses it if it is already the one playing.
  ///
  /// The single entry point for every play button in the app. Anything else
  /// that was sounding stops first, without its own screen having to know.
  Future<void> toggle(
    String storagePath, {
    Duration? knownLength,
    String title = '',
    String byline = '',
    String? songId,
  }) async {
    if (storagePath.isEmpty) return;
    if (isCurrent(storagePath)) {
      if (_playing) {
        await _player.pause();
        _playing = false;
      } else {
        await _player.resume();
        _playing = true;
      }
      notifyListeners();
      return;
    }
    await play(
      storagePath,
      knownLength: knownLength,
      title: title,
      byline: byline,
      songId: songId,
    );
  }

  /// Starts [storagePath] from the beginning, whatever was playing before.
  Future<void> play(
    String storagePath, {
    Duration? knownLength,
    String title = '',
    String byline = '',
    String? songId,
  }) async {
    if (storagePath.isEmpty) return;
    _wire();
    await _player.stop();
    _path = storagePath;
    _title = title;
    _byline = byline;
    _songId = songId;
    // A new song has not been listened to yet, whatever the last one did.
    _counted = null;
    _position = Duration.zero;
    _length = knownLength;
    _playing = false;
    _loading = true;
    notifyListeners();

    String? url;
    try {
      url = await streams.urlFor(storagePath);
    } catch (_) {
      // A recording that will not sign is one this person may not hear, or
      // one that is no longer there. Either way the answer is silence and a
      // button that goes back to how it was — not an error across a feed
      // somebody is browsing.
      url = null;
    }

    // Somebody tapped something else while this was signing. That tap owns
    // the player now, and this one must not steal it back.
    if (_path != storagePath) return;

    if (url == null) {
      _loading = false;
      _path = null;
      notifyListeners();
      return;
    }

    try {
      await _player.play(UrlSource(url));
      if (_path != storagePath) return;
      _playing = true;
      _length = knownLength ?? await _player.getDuration() ?? _length;
    } catch (_) {
      _playing = false;
      _path = null;
    } finally {
      if (_path == storagePath || _path == null) _loading = false;
      notifyListeners();
    }
  }

  Future<void> pause() async {
    if (!_playing) return;
    await _player.pause();
    _playing = false;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_playing || _path == null) return;
    await _player.resume();
    _playing = true;
    notifyListeners();
  }

  /// Stops and forgets. Used when leaving a listening surface, and on sign
  /// out — where the signed URLs go too, because one outlives its session.
  Future<void> stop() async {
    await _player.stop();
    _path = null;
    _title = '';
    _byline = '';
    _songId = null;
    _counted = null;
    _playing = false;
    _loading = false;
    _position = Duration.zero;
    _length = null;
    notifyListeners();
  }

  /// Sign out. Nothing of the previous account stays loaded or signed.
  Future<void> forget() async {
    onFinished = null;
    await stop();
    streams.clear();
  }

  @override
  void dispose() {
    unawaited(_positions?.cancel());
    unawaited(_completions?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }
}
