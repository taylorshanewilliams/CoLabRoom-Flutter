// LiveKit marks its audio-session API experimental; the configurations this
// file checks are the ones lib/services/phone_audio.dart applies, and that
// file carries the explanation of why there is no other way to reach them.
// ignore_for_file: experimental_member_use

import 'package:audioplayers/audioplayers.dart';
import 'package:colabroom/services/phone_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// One owner for the phone's audio session.
///
/// A platform audio session is global to the app process, and before this
/// there were three libraries each writing one: LiveKit for the call,
/// audioplayers for the song and the click, record for a take. The state
/// machine below is the whole of what decides which single configuration is
/// applied, so every transition through it is worth a test — there is no
/// audio behind a channel in a test and no phone in the development loop,
/// which makes this the only place any of it can be checked at all.

/// A session writer that applies nothing and writes down what it was asked
/// for.
class _WroteItDown implements AudioSessionWriter {
  final List<PhoneAudioState> applied = <PhoneAudioState>[];
  final List<AudioSetup> setups = <AudioSetup>[];
  final List<bool> handedBack = <bool>[];
  final List<AudioContext> ontoPlayers = <AudioContext>[];

  /// A state the phone refuses, the way a phone with no audio behind the
  /// channel refuses everything.
  PhoneAudioState? refuses;

  /// Whether two configurations were ever being written at the same time.
  bool everTwoAtOnce = false;
  bool _writing = false;

  @override
  Future<void> apply(AudioSetup setup, {required bool leavingCall}) async {
    if (_writing) everTwoAtOnce = true;
    _writing = true;
    applied.add(setup.state);
    setups.add(setup);
    handedBack.add(leavingCall);
    // A real session takes a moment to apply, so the gap a second transition
    // could arrive in is a real one.
    await Future<void>.delayed(Duration.zero);
    _writing = false;
    if (setup.state == refuses) throw StateError('This phone will not.');
  }

  @override
  Future<void> applyToPlayer(AudioPlayer player, AudioSetup setup) async {
    ontoPlayers.add(setup.players);
  }
}

/// A call that writes down whether it was asked for its microphone.
class _ACallsMicrophone implements CallMicrophone {
  final List<String> log = <String>[];

  @override
  Future<void> letGo() async => log.add('let go');

  @override
  Future<void> takeBack() async => log.add('took back');
}

void main() {
  group('the states that exist', () {
    test('nothing asked for is ordinary music playback', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final hold = await owner.need(AudioNeed.playing);
      expect(owner.state, PhoneAudioState.music);
      await hold.release();
      expect(owner.state, PhoneAudioState.music);
    });

    test('a takes screen open makes the session record-capable before anything plays', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.need(AudioNeed.readyToRecord);
      expect(owner.state, PhoneAudioState.take);
    });

    test('recording with no call is the same session as a takes screen open', () async {
      // The silent-take bug lived exactly here: the session a take needs has
      // to be in place before the backing track sounds, not after Record is
      // pressed. These two collapsing to one state is what keeps that true.
      expect(
        AudioSetup.of(PhoneAudioState.take).players,
        AudioSetup.of(PhoneAudioState.take).players,
      );
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.need(AudioNeed.recording);
      expect(owner.state, PhoneAudioState.take);
      // And nothing was asked of a call, because there is no call.
      expect(AudioSetup.of(PhoneAudioState.take).callOwnsSession, isFalse);
    });

    test('a call on its own is a talking call', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(owner.state, PhoneAudioState.callTalking);
    });

    test('a song playing under a call makes it a call with music', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ACallsMicrophone(), music: false);
      final song = await owner.need(AudioNeed.playing);
      expect(owner.state, PhoneAudioState.callWithMusic);
      await song.release();
      expect(owner.state, PhoneAudioState.callTalking);
    });

    test('a takes screen open under a call is a call with music too', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ACallsMicrophone(), music: false);
      await owner.need(AudioNeed.readyToRecord);
      expect(owner.state, PhoneAudioState.callWithMusic);
    });

    test('music mode turned on in a call reaches the phone, not only WebRTC', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(owner.state, PhoneAudioState.callTalking);
      await call.music(true);
      expect(owner.state, PhoneAudioState.callWithMusic);
      await call.music(false);
      expect(owner.state, PhoneAudioState.callTalking);
    });

    test('a call joined with music mode already on starts as a call with music', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ACallsMicrophone(), music: true);
      expect(owner.state, PhoneAudioState.callWithMusic);
    });
  });

  group('the call and the microphone', () {
    test('a take during a call takes the microphone first and hands it back after', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final microphone = _ACallsMicrophone();
      await owner.callIsUp(microphone, music: false);
      expect(microphone.log, isEmpty);

      final take = await owner.need(AudioNeed.recording);
      expect(owner.state, PhoneAudioState.callWithTake);
      expect(microphone.log, <String>['let go']);
      // Let go of before the session was written, so the input is free by
      // the time the recorder asks for it.
      expect(wrote.applied.last, PhoneAudioState.callWithTake);

      await take.release();
      expect(owner.state, PhoneAudioState.callTalking);
      expect(microphone.log, <String>['let go', 'took back']);
    });

    test('a second recording during one call does not ask for the microphone twice', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final microphone = _ACallsMicrophone();
      await owner.callIsUp(microphone, music: false);
      final first = await owner.need(AudioNeed.recording);
      final second = await owner.need(AudioNeed.recording);
      expect(microphone.log, <String>['let go']);
      await first.release();
      // Still recording: the first one finishing must not hand the
      // microphone back under the second.
      expect(owner.state, PhoneAudioState.callWithTake);
      expect(microphone.log, <String>['let go']);
      await second.release();
      expect(microphone.log, <String>['let go', 'took back']);
    });

    test('a call that ends mid-take does not hand the microphone back to a call that is gone', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final microphone = _ACallsMicrophone();
      final call = await owner.callIsUp(microphone, music: false);
      final take = await owner.need(AudioNeed.recording);
      expect(microphone.log, <String>['let go']);

      await call.release();
      expect(owner.state, PhoneAudioState.take);
      expect(microphone.log, <String>['let go']);
      await take.release();
      expect(owner.state, PhoneAudioState.music);
      expect(microphone.log, <String>['let go']);
    });

    test('a microphone that refuses to stand down does not stop the take', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ARefusingMicrophone(), music: false);
      await owner.need(AudioNeed.recording);
      expect(owner.state, PhoneAudioState.callWithTake);
      expect(wrote.applied.last, PhoneAudioState.callWithTake);
    });
  });

  group('nothing leaks when things overlap', () {
    test('a call ending while a song is playing leaves the phone playing music', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: true);
      final song = await owner.need(AudioNeed.playing);
      expect(owner.state, PhoneAudioState.callWithMusic);

      await call.release();
      expect(owner.state, PhoneAudioState.music);
      await song.release();
      expect(owner.state, PhoneAudioState.music);
    });

    test('the first of two sounds to finish does not turn the session off under the other', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ACallsMicrophone(), music: false);
      final song = await owner.need(AudioNeed.playing);
      final click = await owner.need(AudioNeed.playing);
      expect(owner.state, PhoneAudioState.callWithMusic);
      await click.release();
      expect(owner.state, PhoneAudioState.callWithMusic);
      await song.release();
      expect(owner.state, PhoneAudioState.callTalking);
    });

    test('letting a hold go twice does nothing the second time', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final song = await owner.need(AudioNeed.playing);
      final click = await owner.need(AudioNeed.playing);
      await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(owner.state, PhoneAudioState.callWithMusic);
      await song.release();
      await song.release();
      // The click is still holding, so the phone is still playing music.
      expect(owner.state, PhoneAudioState.callWithMusic);
      await click.release();
      expect(owner.state, PhoneAudioState.callTalking);
    });

    test('the session is handed back only when a call ends', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.need(AudioNeed.readyToRecord);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(wrote.handedBack, everyElement(isFalse));
      await call.release();
      expect(wrote.handedBack.last, isTrue);
      // And not again on the next ordinary transition.
      await owner.need(AudioNeed.playing);
      expect(wrote.handedBack.last, isFalse);
    });

    test('a session the phone refuses does not leave the owner believing the old one is on', () async {
      final wrote = _WroteItDown()..refuses = PhoneAudioState.callTalking;
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      // The phone threw, but the owner knows what it asked for -- so the
      // next transition is worked out from the call being up, not from the
      // music session that is no longer what anybody wants.
      expect(owner.state, PhoneAudioState.callTalking);
      await owner.need(AudioNeed.playing);
      expect(owner.state, PhoneAudioState.callWithMusic);
      await call.release();
      expect(owner.state, PhoneAudioState.music);
      expect(wrote.handedBack.last, isTrue);
    });

    test('two transitions at once never apply two configurations at once', () async {
      // The ordinary case: the click and the song, a call and a take. Two
      // configurations written on top of each other is how a phone ends up
      // in a state nobody asked for.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      final song = owner.need(AudioNeed.playing);
      final take = owner.need(AudioNeed.recording);
      await song;
      final holding = await take;
      expect(wrote.everTwoAtOnce, isFalse);
      // And what the phone is left in is what the holds add up to.
      expect(wrote.applied.last, PhoneAudioState.callWithTake);
      expect(owner.state, PhoneAudioState.callWithTake);
      await holding.release();
      await call.release();
      expect(wrote.everTwoAtOnce, isFalse);
      expect(owner.state, PhoneAudioState.music);
    });

    test('a state nothing wants any more is not applied on the way past', () async {
      // A phone applies a route change audibly, so a configuration that is
      // already stale by the time its turn comes is a click in somebody's
      // headphones for nothing.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      final song = owner.need(AudioNeed.playing);
      final take = owner.need(AudioNeed.recording);
      await song;
      await take;
      expect(wrote.applied, isNot(contains(PhoneAudioState.callWithMusic)));
      await call.release();
    });
  });

  group('what each state actually applies', () {
    test('ordinary playback plays, and asks Android for the whole phone', () {
      final music = AudioSetup.of(PhoneAudioState.music);
      expect(music.players.iOS.category, AVAudioSessionCategory.playback);
      expect(music.players.android.audioFocus, AndroidAudioFocus.gain);
      expect(music.callOwnsSession, isFalse);
    });

    test('a take plays and records, and asks Android for no focus at all', () {
      // A focus request made while this app is holding the microphone is
      // what silenced the capture: 2,486 bytes for 4,000 ms.
      final take = AudioSetup.of(PhoneAudioState.take);
      expect(take.players.iOS.category, AVAudioSessionCategory.playAndRecord);
      expect(take.players.iOS.options, contains(AVAudioSessionOptions.defaultToSpeaker));
      expect(take.players.android.audioFocus, AndroidAudioFocus.none);
    });

    test('a plain call is left sounding exactly as LiveKit makes it sound', () {
      final talking = AudioSetup.of(PhoneAudioState.callTalking).call;
      expect(talking, isNotNull);
      expect(talking!.apple.mode, lk.AppleAudioMode.videoChat);
      expect(talking.android.audioMode, lk.AndroidAudioMode.inCommunication);
    });

    test('a call with music turns Apple voice processing off at the platform', () {
      // videoChat is what selects Apple's voice-processing I/O, and no
      // WebRTC capture option can switch it off. default_ is the half of
      // Music mode that was missing.
      final music = AudioSetup.of(PhoneAudioState.callWithMusic).call;
      expect(music, isNotNull);
      expect(music!.apple.mode, lk.AppleAudioMode.default_);
      expect(music.apple.category, lk.AppleAudioCategory.playAndRecord);
      expect(music.android.audioMode, lk.AndroidAudioMode.normal);
      expect(music.android.contentType, lk.AndroidAudioAttributesContentType.music);
      // Headset handling has to keep working although the mode is no longer
      // a communication mode: unplugging headphones mid-call still routes.
      expect(music.android.forceAudioRouting, isTrue);
      // One focus request on the phone, and it is the call's. The song under
      // it asks for none, which is what stops it taking focus away.
      expect(music.android.manageAudioFocus, isTrue);
      expect(
        AudioSetup.of(PhoneAudioState.callWithMusic).players.android.audioFocus,
        AndroidAudioFocus.none,
      );
    });

    test('a take during a call is recorded on a music session, not a voice one', () {
      final take = AudioSetup.of(PhoneAudioState.callWithTake).call;
      expect(take, isNotNull);
      expect(take!.apple.mode, lk.AppleAudioMode.default_);
      expect(take.apple.category, lk.AppleAudioCategory.playAndRecord);
      expect(take.android.audioMode, lk.AndroidAudioMode.normal);
    });

    test('nothing on the phone asks Android for focus while the microphone is open', () {
      // The one condition the takes bug needed: a focus request made while
      // this app is holding the microphone. 2,486 bytes for 4,000 ms.
      for (final state in <PhoneAudioState>[
        PhoneAudioState.take,
        PhoneAudioState.callWithTake,
      ]) {
        final setup = AudioSetup.of(state);
        expect(setup.players.android.audioFocus, AndroidAudioFocus.none, reason: '$state');
        expect(setup.call?.android.manageAudioFocus ?? false, isFalse, reason: '$state');
      }
    });

    test('no player asks Android for focus while a call holds the session', () {
      for (final state in <PhoneAudioState>[
        PhoneAudioState.callTalking,
        PhoneAudioState.callWithMusic,
        PhoneAudioState.callWithTake,
      ]) {
        expect(
          AudioSetup.of(state).players.android.audioFocus,
          AndroidAudioFocus.none,
          reason: '$state',
        );
      }
    });

    test('a voice among several asks for no focus in every state', () {
      // The drone under a song, the click under a take. Each new focus
      // request takes focus off the last one, and audioplayers pauses a
      // player that loses focus and never starts it again.
      for (final state in PhoneAudioState.values) {
        final setup = AudioSetup.of(state);
        expect(
          setup.playersAmongOthers.android.audioFocus,
          AndroidAudioFocus.none,
          reason: '$state',
        );
        // Only the focus changes: the rest of the session is the phone's.
        expect(setup.playersAmongOthers.iOS, setup.players.iOS);
      }
    });

    test('every state has a configuration, and a call state always has a call', () {
      for (final state in PhoneAudioState.values) {
        final setup = AudioSetup.of(state);
        expect(setup.state, state);
        final inACall = state == PhoneAudioState.callTalking ||
            state == PhoneAudioState.callWithMusic ||
            state == PhoneAudioState.callWithTake;
        expect(setup.callOwnsSession, inACall, reason: '$state');
      }
    });
  });
}

/// A call whose microphone will not stand down.
class _ARefusingMicrophone implements CallMicrophone {
  @override
  Future<void> letGo() async => throw StateError('Not letting go.');

  @override
  Future<void> takeBack() async => throw StateError('Not taking back.');
}
