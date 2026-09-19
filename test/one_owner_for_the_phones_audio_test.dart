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
      // And not again: an ordinary transition afterwards is not a hand-back.
      final second = await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(wrote.handedBack.last, isFalse);
      await second.release();
    });

    test('the session is handed back only once the song has finished', () async {
      // Handing back deactivates the process's one session, and on iOS
      // deactivating a session with running I/O stops that I/O. A song
      // playing under a call that the other person hangs up would go silent
      // with the bar still saying it was playing.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: true);
      final song = await owner.need(AudioNeed.playing);

      await call.release();
      expect(owner.state, PhoneAudioState.music);
      expect(wrote.applied.last, PhoneAudioState.music);
      expect(wrote.handedBack.last, isFalse, reason: 'the song is still playing');

      await song.release();
      expect(wrote.handedBack.last, isTrue);
      expect(owner.state, PhoneAudioState.music);
    });

    test('a call with nothing sounding hands the session straight back', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      await call.release();
      expect(wrote.handedBack.last, isTrue);
      // And a phone that never had a call never hands anything back.
      final second = _WroteItDown();
      final quiet = AudioSessionOwner(second);
      final song = await quiet.need(AudioNeed.playing);
      await song.release();
      expect(second.handedBack, everyElement(isFalse));
    });

    test('a hold taken twice at once is one hold, and one release lets it go', () async {
      // `_hold ??= await need(...)` reads the field, suspends, and assigns
      // afterwards, so two overlapping takes both see null and the second
      // orphans the first. An orphaned hold is never released, and every
      // later call on the phone is a call with music in it.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final holding = AudioHolding(owner, AudioNeed.playing);
      await Future.wait(<Future<void>>[holding.take(), holding.take()]);
      expect(owner.state, PhoneAudioState.music);
      await holding.letGo();
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(owner.state, PhoneAudioState.callTalking);
      await call.release();
    });

    test('letting go while the hold is still being taken leaves nothing held', () async {
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final holding = AudioHolding(owner, AudioNeed.playing);
      final taking = holding.take();
      await holding.letGo();
      await taking;
      await holding.letGo();
      await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(owner.state, PhoneAudioState.callTalking);
    });

    test('a session the phone refuses does not leave the owner believing the old one is on', () async {
      final wrote = _WroteItDown()..refuses = PhoneAudioState.callTalking;
      final owner = AudioSessionOwner(wrote);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      // The phone threw, but the owner knows what it asked for -- so the
      // next transition is worked out from the call being up, not from the
      // music session that is no longer what anybody wants.
      expect(owner.state, PhoneAudioState.callTalking);
      final song = await owner.need(AudioNeed.playing);
      expect(owner.state, PhoneAudioState.callWithMusic);
      await call.release();
      expect(owner.state, PhoneAudioState.music);
      await song.release();
      expect(wrote.handedBack.last, isTrue);
    });

    test('a refusal is written over on the very next transition, even an unchanged one', () async {
      // Nobody knows what session a phone that threw is actually on, so the
      // usual "this is the state you are already in" shortcut cannot be
      // taken until one configuration has landed.
      final wrote = _WroteItDown()..refuses = PhoneAudioState.take;
      final owner = AudioSessionOwner(wrote);
      final screen = await owner.need(AudioNeed.readyToRecord);
      final writes = wrote.applied.length;
      // The state the phone is already meant to be in, so ordinarily
      // nothing would be written at all.
      final song = await owner.need(AudioNeed.playing);
      expect(wrote.applied.length, greaterThan(writes));
      await song.release();
      await screen.release();
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

  group('nothing is written to the phone for nothing', () {
    test('a second sound in a state the phone is already in writes nothing', () async {
      // Every write is a setCategory on the process's one session, which is
      // a route change -- with Bluetooth headphones, an audible one.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final song = await owner.need(AudioNeed.playing);
      final writes = wrote.applied.length;
      final click = await owner.need(AudioNeed.playing);
      expect(wrote.applied.length, writes);
      await click.release();
      expect(wrote.applied.length, writes);
      await song.release();
      expect(wrote.applied.length, writes);
    });

    test('the click under a take does not rewrite the session mid-take', () async {
      // The takes screen holds readyToRecord for its whole life, the
      // recorder opens, and the count-in sounds after it. Before this, the
      // click's hold restated the session while the microphone was open: on
      // iOS a category change under a running recorder, which is a route
      // change in the middle of the take -- and with a Bluetooth headset an
      // A2DP-to-HFP flip in the middle of the take.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.need(AudioNeed.readyToRecord);
      await owner.need(AudioNeed.recording);
      final writes = wrote.applied.length;

      final click = await owner.need(AudioNeed.playing);
      expect(wrote.applied.length, writes, reason: 'the microphone is open');
      await click.release();
      expect(wrote.applied.length, writes);
    });

    test('a call state is restated, because two libraries write it', () async {
      // The exception to the rule above: in a call LiveKit and audioplayers
      // both write this session and either can be the last writer.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      await owner.callIsUp(_ACallsMicrophone(), music: true);
      final writes = wrote.applied.length;
      await owner.need(AudioNeed.playing);
      expect(wrote.applied.length, greaterThan(writes));
      expect(wrote.applied.last, PhoneAudioState.callWithMusic);
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
      // And nothing in a call with music asks Android for focus. Focus is
      // granted per request, not per app, so a call asking for it takes it
      // from this app's own music player when a song was already playing --
      // audioplayers pauses that player and tells Dart nothing.
      expect(music.android.manageAudioFocus, isFalse);
      expect(
        AudioSetup.of(PhoneAudioState.callWithMusic).players.android.audioFocus,
        AndroidAudioFocus.none,
      );
    });

    test('a song already playing is not asked to give up its audio focus', () async {
      // The device check this stands in for: start a song, then join a
      // call. Before this, the call asked for AUDIOFOCUS_GAIN, the player's
      // listener heard AUDIOFOCUS_LOSS, and the song stopped with the bar
      // still saying it was playing.
      final wrote = _WroteItDown();
      final owner = AudioSessionOwner(wrote);
      final song = await owner.need(AudioNeed.playing);
      final call = await owner.callIsUp(_ACallsMicrophone(), music: false);
      expect(owner.state, PhoneAudioState.callWithMusic);
      expect(wrote.setups.last.call?.android.manageAudioFocus, isFalse);
      await call.release();
      await song.release();
    });

    test('music-grade call states keep Bluetooth on A2DP, not the headset profile', () {
      // allowBluetooth is HFP: with playAndRecord and an open microphone iOS
      // takes any headset with a microphone in it over a 16 kHz mono link,
      // in both directions. That is the thin, narrow sound this whole class
      // exists to remove, on the one setting that says to wear headphones.
      for (final state in <PhoneAudioState>[
        PhoneAudioState.callWithMusic,
        PhoneAudioState.callWithTake,
      ]) {
        final call = AudioSetup.of(state).call!;
        expect(
          call.apple.categoryOptions,
          isNot(contains(lk.AppleAudioCategoryOption.allowBluetooth)),
          reason: '$state',
        );
        expect(
          call.apple.categoryOptions,
          contains(lk.AppleAudioCategoryOption.allowBluetoothA2DP),
          reason: '$state',
        );
      }
      // A plain talking call is left exactly as LiveKit makes it, headset
      // microphone included.
      expect(
        AudioSetup.of(PhoneAudioState.callTalking).call!.apple.categoryOptions,
        contains(lk.AppleAudioCategoryOption.allowBluetooth),
      );
    });

    test('the two writes a call state makes ask for the same thing', () {
      // audioplayers is written first and the call second, on every
      // transition and on every useOn. Two different option sets written
      // back to back are two route changes -- with a Bluetooth headset,
      // audibly one dropped and picked up again.
      const sameOption = <lk.AppleAudioCategoryOption, AVAudioSessionOptions>{
        lk.AppleAudioCategoryOption.allowBluetooth: AVAudioSessionOptions.allowBluetooth,
        lk.AppleAudioCategoryOption.allowBluetoothA2DP: AVAudioSessionOptions.allowBluetoothA2DP,
        lk.AppleAudioCategoryOption.allowAirPlay: AVAudioSessionOptions.allowAirPlay,
        lk.AppleAudioCategoryOption.defaultToSpeaker: AVAudioSessionOptions.defaultToSpeaker,
        lk.AppleAudioCategoryOption.mixWithOthers: AVAudioSessionOptions.mixWithOthers,
      };
      for (final state in <PhoneAudioState>[
        PhoneAudioState.callTalking,
        PhoneAudioState.callWithMusic,
        PhoneAudioState.callWithTake,
      ]) {
        final setup = AudioSetup.of(state);
        expect(
          setup.players.iOS.options,
          setup.call!.apple.categoryOptions!.map((o) => sameOption[o]).toSet(),
          reason: '$state',
        );
      }
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
