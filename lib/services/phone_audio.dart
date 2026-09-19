/// One owner for the phone's audio session.
///
/// **Why this exists.** A platform audio session is global to the app
/// process, and this app has three separate libraries that each believe they
/// own it:
///
/// - `livekit_client` sets iOS to `playAndRecord` with mode `videoChat`
///   (Apple's voice-processing I/O: echo cancelling and gain riding on the
///   input, earpiece-first routing) and Android to `MODE_IN_COMMUNICATION`.
/// - `audioplayers` writes its own context. On iOS it calls
///   `setCategory(category, options:)` with no mode at all, so it cannot ask
///   for — or preserve — the mode a call needs. On Android both
///   `AudioPlayer.global.setAudioContext` and a per-player `setAudioContext`
///   write `audioManager.mode` and `isSpeakerphoneOn` globally; the plugin's
///   own source says so ("AudioManager values are set globally"), and the
///   default mode in an `AudioContextAndroid` is `MODE_NORMAL`.
/// - `record` opens the microphone underneath both of them.
///
/// So before this class, playing the song during a call, or recording a take
/// during a call, fought the call for the session: the loser lost silently.
/// The music came out thin, mono or through the earpiece, or a take was echo
/// cancelled against the very track it was played to. The panel's engineer
/// called it the biggest hole in the whole of "The Session" (17 September
/// 2026), and it is the foundation everything else in wave 4 stands on.
///
/// **The rule.** Nothing in this app writes an audio session except this
/// file. Every audio user — the call, song playback, take recording, the
/// click and the drone — asks here first and lets go afterwards, and the
/// owner works out the one state the phone is actually in and applies one
/// coherent configuration for it. Letting go restores whatever the remaining
/// holds need, which is what "restore it afterwards" means when several
/// things overlap.
///
/// **The evidence this replaces, kept because it cost three rounds of
/// fixes.** The takes screen used to set a contradictory audioplayers
/// context of its own. Android defaults to `AudioFocus.gain` — "this app is
/// the only thing you are listening to" — and asking for exclusive focus
/// while this same app holds the microphone gets the capture silenced: the
/// recorder keeps running, keeps writing a file, and the file is four
/// seconds of digital silence. iOS defaults to the `playback` category,
/// which does not permit recording at all. The symptom was miserable to
/// read: the *first* take of a session recorded perfectly, because nothing
/// was playing while it was recorded, and every take after it came back
/// silent — which looks exactly like a playback bug. Layer one, recorded
/// dry, was 41,073 bytes for 3,200 ms, right for AAC-LC at 96 kbps. Layer
/// two, recorded ten seconds later against the mix, was 2,486 bytes for
/// 4,000 ms. That is not a short recording; it is what encoded silence
/// costs.
///
/// LiveKit marks its whole audio-session API `@experimental`, and there is no
/// other way to reach the platform session it owns: the alternative is the
/// collision above. The suppression is for this file alone, which is the one
/// file allowed to write a session at all, so if the API does change it is
/// this file that stops compiling and nothing else.
// ignore_for_file: experimental_member_use
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// What the phone's one audio session is for, right now.
///
/// Five states and no others. Everything a caller asks for collapses into
/// one of these, and each one has exactly one configuration
/// ([AudioSetup.of]).
enum PhoneAudioState {
  /// No call, nothing recording: ordinary music playback, which is what
  /// every screen in the app that is only a player wants.
  music,

  /// No call, and something that plays and records together is open.
  ///
  /// One state rather than two, because the session a take needs has to be
  /// in place *before* the microphone opens — a backing track already
  /// playing under the wrong session is the silent-take bug — so a screen
  /// that is about to record and a screen that is recording want the same
  /// thing.
  take,

  /// A call, talking. LiveKit's own communication session, untouched.
  callTalking,

  /// A call with music on this phone: the song playing under it, or Music
  /// mode turned on, or a takes screen open.
  ///
  /// One state for all three because they need the same thing: music-grade
  /// output and Apple's voice processing off, so a held note is not eaten
  /// by echo cancelling and the song is not squeezed down a voice path.
  callWithMusic,

  /// A call with a recording pass on this phone. The call's microphone is
  /// let go of first — two microphone clients in one process is the
  /// collision — and handed back when the pass is over.
  callWithTake,
}

/// What a caller is asking the phone's audio for.
enum AudioNeed {
  /// Something is sounding on this phone: a song, a click, a drone.
  playing,

  /// A screen that plays and records together is open, but nothing is being
  /// recorded yet.
  ///
  /// Held for as long as the screen is, because the session has to be
  /// record-capable before the first note of the backing track sounds, not
  /// after the record button is pressed.
  readyToRecord,

  /// The microphone is open on this phone right now.
  recording,
}

/// The call's microphone, as the owner needs to be able to reach it.
///
/// Implemented by the call session. A recording pass on this phone asks the
/// call to let the microphone go rather than opening a second one beside it:
/// on iOS the call's voice-processing unit holds the input and would echo
/// cancel the take against the track it is being played to, and on Android a
/// second `AudioRecord` opened against a live `VOICE_COMMUNICATION` capture
/// is how a take comes back silent.
abstract class CallMicrophone {
  /// Give the microphone up, remembering whether it was on.
  Future<void> letGo();

  /// Take it back, as it was.
  Future<void> takeBack();
}

/// Something a caller holds while it needs the phone's audio.
abstract class AudioHold {
  /// Let go. Safe to call twice; the second call does nothing.
  Future<void> release();
}

/// The call's hold, which can also say whether Music mode is on.
abstract class CallHold extends AudioHold {
  /// Music mode, turned on or off during the call.
  ///
  /// This is the half that was missing: `AudioCaptureOptions` configures
  /// WebRTC's own capture, which does nothing about the platform session
  /// Apple applies its voice processing from.
  Future<void> music(bool on);
}

/// What every audio user asks. [AudioSessionOwner] is the real one; a test
/// hands screens a fake.
abstract class PhoneAudio {
  /// Ask for what you need, and let the returned hold go when you are done.
  Future<AudioHold> need(AudioNeed need);

  /// A call is up on this phone, with [microphone] as the way to ask it to
  /// stand down while a take is recorded.
  Future<CallHold> callIsUp(CallMicrophone microphone, {required bool music});

  /// Put the current session on [player] as well as on the app's default.
  ///
  /// Belt and braces, and the reason is real: a player built as a field
  /// initialiser exists before `initState` runs, so the global default may
  /// never reach it.
  ///
  /// [amongOthers] is for a player that is deliberately one voice among
  /// several on this phone — the drone under a song, the click under a take.
  /// It asks for no audio focus, because on Android each new focus request
  /// takes focus off the last one and audioplayers pauses a player that
  /// loses focus and never starts it again.
  Future<void> useOn(AudioPlayer player, {bool amongOthers = false});

  /// What state the phone's audio is in. For tests and for reading; nothing
  /// on screen shows it.
  PhoneAudioState get state;
}

/// One coherent configuration of the phone's one audio session.
///
/// A pure function of [PhoneAudioState] — [AudioSetup.of] — so that the
/// whole of what each state means can be read in one place and tested
/// without a phone.
class AudioSetup {
  AudioSetup._(this.state, this.players, this.call);

  final PhoneAudioState state;

  /// What audioplayers is told.
  ///
  /// Always written *before* the call's session, never after: both write the
  /// same global settings, and the call's mode is the one that has to
  /// survive.
  final AudioContext players;

  /// What the call is told, or null when there is no call.
  final lk.AudioSessionOptions? call;

  /// Whether a call holds the session in this state.
  bool get callOwnsSession => call != null;

  /// The same session for a player that is one voice among several: no audio
  /// focus, so it neither takes focus from what is already sounding nor
  /// pauses itself when the next sound asks for it.
  AudioContext get playersAmongOthers => AudioContext(
        android: players.android.copy(audioFocus: AndroidAudioFocus.none),
        iOS: players.iOS,
      );

  /// The one configuration [state] means.
  static AudioSetup of(PhoneAudioState state) {
    switch (state) {
      case PhoneAudioState.music:
        return AudioSetup._(state, _musicPlayers, null);
      case PhoneAudioState.take:
        return AudioSetup._(state, _takePlayers, null);
      case PhoneAudioState.callTalking:
        return AudioSetup._(state, _inCallPlayers(talking: true), _talkingCall);
      case PhoneAudioState.callWithMusic:
        return AudioSetup._(state, _inCallPlayers(talking: false), _musicCall);
      case PhoneAudioState.callWithTake:
        // The same players context as a call with music: what is playing in
        // both is the track, and only the microphone differs.
        return AudioSetup._(state, _inCallPlayers(talking: false), _takeCall);
    }
  }

  /// Ordinary playback, for every screen that is only a player.
  ///
  /// `playback` rather than `playAndRecord` on the way out of a recording
  /// screen because `playAndRecord` is process-wide on iOS and quieter:
  /// leaving it applied turns the volume down on the stem player and the
  /// song sheet, on a phone that is no longer recording anything.
  static AudioContext get _musicPlayers => AudioContext(
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

  /// Play and capture together, with no call.
  ///
  /// `AndroidAudioFocus.none` is deliberate rather than a softer request
  /// like `gainTransientMayDuck`: there is no other app to duck, the only
  /// audio in play belongs to this screen, and every focus request that is
  /// not `none` risks the system resolving the conflict by muting the
  /// capture. `defaultToSpeaker` puts the backing track out of the
  /// loudspeaker rather than the earpiece, which is the difference between
  /// working and useless to somebody holding a guitar.
  static AudioContext get _takePlayers => AudioContext(
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
            AVAudioSessionOptions.defaultToSpeaker,
            // A band member on headphones is the good case: the backing
            // track stops bleeding into the take entirely.
            AVAudioSessionOptions.allowBluetooth,
            AVAudioSessionOptions.mixWithOthers,
          },
        ),
      );

  /// What audioplayers may do while a call holds the session.
  ///
  /// No audio focus, ever: during a call this app is always holding the
  /// microphone, and a focus request made while holding the microphone is
  /// exactly what silenced the capture in the takes bug above. There is
  /// nothing to duck either — the call and the song are both this app.
  ///
  /// The Android mode here agrees with what the call is about to be set to,
  /// and `isSpeakerphoneOn` is left false because LiveKit's own routing runs
  /// straight after this and knows about the headset. Neither value is load
  /// bearing: the call writes them again afterwards.
  static AudioContext _inCallPlayers({required bool talking}) => AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          audioMode: talking ? AndroidAudioMode.inCommunication : AndroidAudioMode.normal,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: const <AVAudioSessionOptions>{
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.allowBluetooth,
            AVAudioSessionOptions.mixWithOthers,
          },
        ),
      );

  /// A plain call: LiveKit's own communication session, unchanged.
  ///
  /// This slice must not change how an ordinary call sounds, so this state
  /// applies exactly what LiveKit applies for itself — `playAndRecord` with
  /// mode `videoChat` on iOS, `MODE_IN_COMMUNICATION` with voice-call
  /// attributes on Android — and only takes over the writing of it.
  static lk.AudioSessionOptions get _talkingCall => const lk.AudioSessionOptions.communication();

  /// A call with music on this phone.
  ///
  /// Apple mode `default_` is the whole point: voice processing on iOS is
  /// selected by the session's *mode*, so `videoChat` keeps echo cancelling
  /// and gain riding on the input however the WebRTC capture options are
  /// set. `default_` is what turns it off at the platform, which is what
  /// Music mode has always promised on screen ("your instrument goes
  /// through as it is, with no echo cancelling or noise gate. Wear
  /// headphones, or the others will hear themselves.") and never actually
  /// did.
  ///
  /// On Android `normal` with media attributes moves both the song and the
  /// other person's voice off the narrow voice-call path onto the music one,
  /// which is what "sounds full" means. `forceAudioRouting` keeps LiveKit's
  /// headset handling working even though the mode is no longer a
  /// communication mode, so unplugging headphones mid-call still routes.
  ///
  /// Audio focus stays LiveKit's here, and stays exactly one request: the
  /// audioplayers context that goes with every call state asks for none, so
  /// the song under the call does not take focus off it. Nothing is
  /// recording in this state, which is the condition the takes bug needed.
  static lk.AudioSessionOptions get _musicCall => lk.AudioSessionOptions.communication(
        apple: const lk.AppleAudioSessionConfiguration(
          category: lk.AppleAudioCategory.playAndRecord,
          categoryOptions: <lk.AppleAudioCategoryOption>{
            lk.AppleAudioCategoryOption.allowBluetooth,
            lk.AppleAudioCategoryOption.allowBluetoothA2DP,
            lk.AppleAudioCategoryOption.allowAirPlay,
            lk.AppleAudioCategoryOption.defaultToSpeaker,
          },
          mode: lk.AppleAudioMode.default_,
        ),
        android: const lk.AndroidAudioSessionConfiguration(
          audioMode: lk.AndroidAudioMode.normal,
          manageAudioFocus: true,
          focusMode: lk.AndroidAudioFocusMode.gain,
          streamType: lk.AndroidAudioStreamType.music,
          usageType: lk.AndroidAudioAttributesUsageType.media,
          contentType: lk.AndroidAudioAttributesContentType.music,
          forceAudioRouting: true,
        ),
      );

  /// A call with a recording pass on this phone.
  ///
  /// The same music-grade session, because a take is recorded against a
  /// track and must not be echo cancelled against it — plus `mixWithOthers`,
  /// because the call's playout and the recorder now share the input side of
  /// one session. The call's microphone is let go of before this is applied
  /// and taken back after it is undone; that part is the owner's job, not
  /// the configuration's.
  ///
  /// `manageAudioFocus: false` is the one place this slice departs from
  /// LiveKit's defaults on the focus question, and it is the one place the
  /// takes bug's evidence applies exactly: the `record` plugin is holding
  /// the microphone, and a focus request made while this app holds the
  /// microphone is what produced 2,486 bytes for 4,000 ms. There is nothing
  /// to duck anyway — the call and the track are both this app.
  static lk.AudioSessionOptions get _takeCall => lk.AudioSessionOptions.communication(
        apple: const lk.AppleAudioSessionConfiguration(
          category: lk.AppleAudioCategory.playAndRecord,
          categoryOptions: <lk.AppleAudioCategoryOption>{
            lk.AppleAudioCategoryOption.allowBluetooth,
            lk.AppleAudioCategoryOption.allowBluetoothA2DP,
            lk.AppleAudioCategoryOption.defaultToSpeaker,
            lk.AppleAudioCategoryOption.mixWithOthers,
          },
          mode: lk.AppleAudioMode.default_,
        ),
        android: const lk.AndroidAudioSessionConfiguration(
          audioMode: lk.AndroidAudioMode.normal,
          manageAudioFocus: false,
          streamType: lk.AndroidAudioStreamType.music,
          usageType: lk.AndroidAudioAttributesUsageType.media,
          contentType: lk.AndroidAudioAttributesContentType.music,
          forceAudioRouting: true,
        ),
      );
}

/// Where a configuration actually lands. Faked in tests, which is the only
/// way any of this can be tested at all: there is no audio behind the
/// channels in a test and no phone in the development loop.
abstract class AudioSessionWriter {
  /// Apply [setup].
  ///
  /// [leavingCall] is true on the one transition where a call is handing the
  /// session back, which is the only moment the call's hold on the platform
  /// should be released.
  Future<void> apply(AudioSetup setup, {required bool leavingCall});

  /// Put [setup] on one player as well.
  Future<void> applyToPlayer(AudioPlayer player, AudioSetup setup);
}

/// The real one: audioplayers and LiveKit, in that order.
class DeviceAudioSession implements AudioSessionWriter {
  const DeviceAudioSession();

  @override
  Future<void> apply(AudioSetup setup, {required bool leavingCall}) async {
    // audioplayers first and the call last, always. Both write the same
    // global settings — the iOS category and the Android mode — and
    // audioplayers cannot express an iOS mode at all, so whatever it writes
    // has to be overwritten by the call rather than the other way round.
    await _tellPlayers(setup.players);
    if (leavingCall) {
      // Twice on this one transition, deliberately. audioplayers' Android
      // plugin applies the *previous* default context's `audioMode` and
      // `isSpeakerphoneOn` to AudioManager and only then stores the new
      // context, so a single write leaves the phone in the call's mode with
      // the music context merely recorded. Every other transition either
      // moves between two contexts whose mode is already `normal` or has
      // the call writing the mode afterwards; this is the one where nothing
      // comes after, and a phone left in MODE_IN_COMMUNICATION after a call
      // has the volume keys on the wrong stream.
      await _tellPlayers(setup.players);
      // Last, so LiveKit's own restoring of the mode and its audio focus is
      // the final word, and the session is only released once the music
      // context is in place to take it.
      await _callLetsGo();
      return;
    }
    final call = setup.call;
    if (call != null) await _tellTheCall(call);
  }

  @override
  Future<void> applyToPlayer(AudioPlayer player, AudioSetup setup) async {
    try {
      await player.setAudioContext(setup.players);
    } catch (_) {
      // Swallowed on purpose. A phone that refuses the session is a phone
      // where recording against a backing track will not work well, but it
      // is still a phone where what is already recorded can be listened to,
      // renamed and exported, and none of that should be behind an audio
      // session. There is also nowhere useful to report it to: this runs
      // from initState, before there is a screen to put a message on. In a
      // widget test there is no platform behind the channel at all.
    }
    // A per-player context write is global too — on iOS it is documented as
    // such by the plugin itself, and on Android it sets `audioManager.mode`
    // — so a call that is up has to be put back straight afterwards.
    final call = setup.call;
    if (call != null) await _tellTheCall(call);
  }

  Future<void> _tellPlayers(AudioContext context) async {
    try {
      await AudioPlayer.global.setAudioContext(context);
    } catch (_) {
      // As above.
    }
  }

  Future<void> _tellTheCall(lk.AudioSessionOptions options) async {
    try {
      // This also puts LiveKit into manual mode, which is the point: from
      // here on it stops reconfiguring the session from room and track
      // lifecycle, so there is one writer rather than two.
      await lk.AudioManager.instance.setAudioSessionOptions(options);
    } catch (_) {
      // A phone that refuses is a phone where the call sounds like it did
      // before this class existed. That is worse, not broken.
    }
  }

  Future<void> _callLetsGo() async {
    try {
      await lk.AudioManager.instance.deactivateAudioSession();
    } catch (_) {
      // As above.
    }
  }
}

/// The owner. One per app; [instance] is the app's.
class AudioSessionOwner implements PhoneAudio {
  AudioSessionOwner(this._sessions);

  /// The app's one owner.
  ///
  /// Settable so a test can put a fake in place of the real thing, the way
  /// the rest of the app's singletons are reached. Nothing in production
  /// assigns it.
  static PhoneAudio instance = AudioSessionOwner(const DeviceAudioSession());

  final AudioSessionWriter _sessions;

  /// How many holds of each kind are out.
  ///
  /// Counted rather than a flag, because two things can want the same thing
  /// at once — the click and the song both sounding — and the first one to
  /// finish must not turn the session off under the other.
  final Map<AudioNeed, int> _held = <AudioNeed, int>{};

  _CallHold? _call;

  /// Whether the call's microphone is currently let go of for a take.
  bool _micLetGo = false;

  PhoneAudioState _state = PhoneAudioState.music;

  /// Transitions run one at a time, and each one works out afresh what the
  /// holds add up to when its turn comes.
  ///
  /// Two things at once is the ordinary case -- the click and the song, a
  /// call and a take -- and overlapping configurations applied on top of
  /// each other are how the phone ends up in a state nobody asked for.
  /// Working the answer out at the front of the queue also means a state
  /// nothing wants any more is never applied on the way past, which on a
  /// phone is an audible route change for nothing.
  Future<void> _queue = Future<void>.value();

  @override
  PhoneAudioState get state => _state;

  @override
  Future<AudioHold> need(AudioNeed need) async {
    _held.update(need, (count) => count + 1, ifAbsent: () => 1);
    final hold = _Hold(this, need);
    await _settle();
    return hold;
  }

  @override
  Future<CallHold> callIsUp(CallMicrophone microphone, {required bool music}) async {
    // A second call cannot happen — one phone, one call — but if one did,
    // the newer one owns the session and the older hold becomes inert.
    final hold = _CallHold(this, microphone, music);
    _call = hold;
    await _settle();
    return hold;
  }

  /// Queued with the transitions, because it writes the same global settings
  /// they do: a per-player context is documented as global on iOS and sets
  /// `audioManager.mode` on Android. Interleaved with a transition it could
  /// be the last write to land, leaving the phone on a session nobody is in
  /// any more.
  @override
  Future<void> useOn(AudioPlayer player, {bool amongOthers = false}) =>
      _after(() => _putOnPlayer(player, amongOthers: amongOthers));

  Future<void> _putOnPlayer(AudioPlayer player, {required bool amongOthers}) async {
    final setup = AudioSetup.of(_state);
    try {
      await _sessions.applyToPlayer(
        player,
        amongOthers ? AudioSetup._(setup.state, setup.playersAmongOthers, setup.call) : setup,
      );
    } catch (_) {
      // As with a transition that is refused: a phone that will not take the
      // session still plays, and this is called from build paths with
      // nowhere to put a message.
    }
  }

  /// What the holds that are out add up to.
  PhoneAudioState _wanted() {
    final recording = (_held[AudioNeed.recording] ?? 0) > 0;
    final ready = recording || (_held[AudioNeed.readyToRecord] ?? 0) > 0;
    final playing = (_held[AudioNeed.playing] ?? 0) > 0;
    final call = _call;
    if (call == null) return ready ? PhoneAudioState.take : PhoneAudioState.music;
    if (recording) return PhoneAudioState.callWithTake;
    if (call.wantsMusic || playing || ready) return PhoneAudioState.callWithMusic;
    return PhoneAudioState.callTalking;
  }

  Future<void> _settle() => _after(_moveToWhatIsWanted);

  /// Runs [work] after everything already queued, and never lets a failure
  /// travel down the queue: one transition that threw would otherwise make
  /// every later one fail without running, and the phone would be stuck on
  /// whatever session happened to be applied when it went wrong.
  Future<void> _after(Future<void> Function() work) {
    final next = _queue.then((_) => work());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _moveToWhatIsWanted() async {
    // Worked out afresh here rather than when the hold was asked for, and
    // applied even when it is the state the phone is already in: audioplayers
    // and LiveKit both write this session behind the owner's back -- the one
    // on every play and stop, the other until it is put into manual mode --
    // so restating it on every transition is what keeps it true.
    final wanted = _wanted();
    final leavingCall = _call == null && _state != PhoneAudioState.music && _state != PhoneAudioState.take;
    // The microphone goes before the session changes, so the input is free
    // by the time the recorder asks for it.
    if (wanted == PhoneAudioState.callWithTake && !_micLetGo) {
      _micLetGo = true;
      await _ask((microphone) => microphone.letGo());
    }
    // Written down before the configuration is applied, not after: a phone
    // that refuses one must not leave the owner believing the old one is
    // still on, or the next transition would be worked out from a state the
    // phone is not in.
    _state = wanted;
    try {
      await _sessions.apply(AudioSetup.of(wanted), leavingCall: leavingCall);
    } catch (_) {
      // Swallowed, and it has to be. Holds are taken from initState and from
      // the middle of a tap on Record, so a phone that refuses a session
      // would otherwise throw out of a screen being built or a button being
      // pressed -- and a phone that refuses is still a phone that plays what
      // is already recorded, and records when nothing else is sounding. It
      // is worse, not broken. There is nowhere useful to say so either: no
      // screen exists yet at the moment most of these are asked for.
    }
    if (wanted != PhoneAudioState.callWithTake && _micLetGo) {
      _micLetGo = false;
      // Nothing to hand back to when the call itself is what ended.
      if (_call != null) await _ask((microphone) => microphone.takeBack());
    }
  }

  Future<void> _ask(Future<void> Function(CallMicrophone) what) async {
    final call = _call;
    if (call == null) return;
    try {
      await what(call.microphone);
    } catch (_) {
      // A call that will not give its microphone up is a call the take will
      // be recorded beside. That is the old behaviour, and the recording
      // screen has its own failure path for a take that comes back empty.
    }
  }

  void _letGoOf(AudioNeed need) {
    final count = _held[need] ?? 0;
    if (count <= 1) {
      _held.remove(need);
    } else {
      _held[need] = count - 1;
    }
  }
}

class _Hold implements AudioHold {
  _Hold(this._owner, this._need);

  final AudioSessionOwner _owner;
  final AudioNeed _need;
  bool _gone = false;

  @override
  Future<void> release() async {
    if (_gone) return;
    _gone = true;
    _owner._letGoOf(_need);
    await _owner._settle();
  }
}

class _CallHold implements CallHold {
  _CallHold(this._owner, this.microphone, this.wantsMusic);

  final AudioSessionOwner _owner;
  final CallMicrophone microphone;
  bool wantsMusic;
  bool _gone = false;

  @override
  Future<void> music(bool on) async {
    if (_gone || wantsMusic == on) return;
    wantsMusic = on;
    await _owner._settle();
  }

  @override
  Future<void> release() async {
    if (_gone) return;
    _gone = true;
    // Only if this is still the call that owns the session.
    if (identical(_owner._call, this)) {
      _owner._call = null;
      await _owner._settle();
    }
  }
}

/// The app's owner, for the callers that reach it directly.
PhoneAudio get phoneAudio => AudioSessionOwner.instance;
