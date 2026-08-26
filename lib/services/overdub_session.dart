import 'package:audioplayers/audioplayers.dart';

/// The audio session a phone needs in order to play and record at the same
/// time.
///
/// **This is the whole overdub feature.** Playing a backing track while the
/// microphone is open is the one thing takes must do, and neither platform
/// does it by default — audioplayers ships a configuration built for a music
/// player, which is the exact opposite of what recording against a track
/// needs:
///
/// - Android defaults to `AndroidAudioFocus.gain`, which announces this app
///   as the sole source of audio the user is listening to. Asking for
///   exclusive focus while this same app is holding the microphone gets the
///   capture silenced: the recorder keeps running, keeps writing a file, and
///   the file is four seconds of digital silence.
/// - iOS defaults to the `playback` category, which does not permit recording
///   at all. `playAndRecord` is the only category that allows both, and
///   without `defaultToSpeaker` it plays the backing track out of the earpiece
///   — technically working, and useless to somebody holding a guitar.
///
/// The symptom this produced was miserable to read: the *first* take of a
/// session recorded perfectly, because nothing was playing while it was
/// recorded, and every take after it came back silent. That looks exactly
/// like a playback bug — "only the first take plays" — which is where three
/// rounds of fixes went. The audio was never there to play.
///
/// The evidence, for the next person who doubts it: layer one, recorded dry,
/// was 41,073 bytes for 3,200 ms — right for AAC-LC at 96 kbps. Layer two,
/// recorded ten seconds later against the mix, was 2,486 bytes for 4,000 ms.
/// That is not a short recording, it is what encoded silence costs.
class OverdubSession {
  const OverdubSession._();

  /// Play and capture together.
  ///
  /// `AndroidAudioFocus.none` is deliberate rather than a softer request like
  /// `gainTransientMayDuck`: there is no other app to duck. The only audio in
  /// play belongs to this screen, and every focus request that is not `none`
  /// risks the system resolving the conflict by muting the capture.
  static AudioContext get recording => AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: const <AVAudioSessionOptions>{
            // Out of the loudspeaker, not the earpiece.
            AVAudioSessionOptions.defaultToSpeaker,
            // A band member on headphones is the good case — the backing
            // track stops bleeding into the take entirely.
            AVAudioSessionOptions.allowBluetooth,
            AVAudioSessionOptions.mixWithOthers,
          },
        ),
      );

  /// Ordinary playback, for every other screen.
  ///
  /// Restored on the way out because `playAndRecord` is a process-wide
  /// setting on iOS and quieter than `playback`: leaving it applied would
  /// turn the volume down on the stem player and the song sheet, on a phone
  /// that is no longer recording anything.
  static AudioContext get playback => AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const <AVAudioSessionOptions>{},
        ),
      );

  /// Both of these swallow failure deliberately.
  ///
  /// A phone that refuses the session is a phone where recording against a
  /// backing track will not work well — but it is still a phone where the
  /// takes already recorded can be listened to, renamed and exported, and
  /// none of that should be behind an audio session. There is also nowhere
  /// useful to report it to: this runs from initState, before there is a
  /// screen to put a message on.
  static Future<void> begin() => _apply(recording);

  static Future<void> end() => _apply(playback);

  /// The same session, applied to one player rather than to the default.
  ///
  /// [begin] sets the *global* context, and a player that already exists may
  /// never see it: AudioPlayer is constructed as a field initialiser on the
  /// takes screen, which runs before initState. So the player doing the
  /// playback during a recording was quite possibly still carrying the
  /// default context — the one that takes the microphone away — while the
  /// global default said otherwise.
  ///
  /// Belt and braces on purpose. This is the one behaviour the feature cannot
  /// work without, it costs a single call, and there is no device in the
  /// development loop to tell the two apart.
  static Future<void> applyTo(AudioPlayer player) async {
    try {
      await player.setAudioContext(recording);
    } catch (_) {
      // As with _apply: a phone that refuses the session still plays back
      // what is already recorded.
    }
  }

  static Future<void> _apply(AudioContext context) async {
    try {
      await AudioPlayer.global.setAudioContext(context);
    } catch (_) {
      // Including in a widget test, where there is no platform behind the
      // channel at all.
    }
  }
}
