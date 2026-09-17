import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../domain/calls.dart';

/// One phone in one call, as the call screen sees it.
///
/// An interface so the screen can be tested without a network, a camera or a
/// LiveKit server; [LiveKitCallSession] is the real one.
enum CallState { connecting, connected, ended }

class CallPerson {
  const CallPerson({
    required this.userId,
    required this.name,
    required this.isYou,
    required this.micOn,
    required this.cameraOn,
    this.video,
  });

  final String userId;
  final String name;
  final bool isYou;
  final bool micOn;
  final bool cameraOn;

  /// What to draw when the camera is on. Null in tests and before it arrives.
  final lk.VideoTrack? video;
}

abstract class CallSession extends ChangeNotifier {
  CallState get state;
  List<CallPerson> get people;
  bool get micOn;
  bool get cameraOn;

  /// Headphones on, instrument as it is: no echo cancelling, no noise gate,
  /// no gain riding, and a music bitrate. See [captureFor].
  bool get musicMode;

  /// Why this phone is not sending sound, said to the person: no microphone,
  /// or one the browser or phone has blocked. Null when it works. A call with
  /// no microphone is still a call -- you can listen and watch.
  String? get microphoneProblem => null;

  /// The same for the camera. Null when it works.
  String? get cameraProblem => null;

  Future<void> setMic(bool on);
  Future<void> setCamera(bool on);
  Future<void> flipCamera();
  Future<void> setMusicMode(bool on);
  Future<void> leave();
}

/// This phone, for as long as the app is open: two phones signed in as one
/// person are two people in a call, and one leaving is not the other leaving.
final String callDevice = List<String>.generate(
  16,
  (_) => math.Random.secure().nextInt(16).toRadixString(16),
).join();

/// How a phone listens.
///
/// A voice call's processing is built for speech and is exactly wrong for an
/// instrument: echo cancelling eats a held note the moment it sounds like the
/// room, noise suppression gates the quiet end of a phrase, and automatic gain
/// flattens dynamics. Music mode turns all of it off and relies on headphones
/// to keep the other person's sound out of the microphone.
lk.AudioCaptureOptions captureFor({required bool music}) => music
    ? const lk.AudioCaptureOptions(
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        highPassFilter: false,
        voiceIsolation: false,
        typingNoiseDetection: false,
      )
    : const lk.AudioCaptureOptions();

/// How a phone sends. Silence suppression (DTX) is off in music mode, because
/// the tail of a note and the breath before the next are not silence.
lk.AudioPublishOptions publishFor({required bool music}) => music
    ? const lk.AudioPublishOptions(encoding: lk.AudioEncoding.presetMusicHighQuality, dtx: false)
    : const lk.AudioPublishOptions(encoding: lk.AudioEncoding.presetSpeech);

/// Why a microphone or camera would not start, in words for the person.
///
/// Found on 17 September 2026: Taylor's computer has no microphone, the
/// browser answered `NotFoundError: Requested device not found`, and the
/// whole call failed. Now the call goes on and the button says why.
String deviceProblem(Object error, {required String device}) {
  final said = error.toString();
  final name = device[0].toUpperCase() + device.substring(1);
  if (said.contains('NotAllowedError') || said.contains('Permission') || said.contains('denied')) {
    return '$name is blocked. Allow it for CoLabRoom, then join again.';
  }
  if (said.contains('NotFoundError') || said.contains('not found') || said.contains('OverconstrainedError')) {
    return 'No $device found on this device. You can still listen and watch.';
  }
  if (said.contains('NotReadableError')) {
    return 'Another app is using the $device.';
  }
  return 'The $device would not start.';
}

/// Who a LiveKit identity belongs to: call-token writes `<user id>:<device>`.
String personOfIdentity(String identity) => identity.split(':').first;

class LiveKitCallSession extends CallSession {
  LiveKitCallSession._(this._room, this._musicMode);

  final lk.Room _room;
  bool _musicMode;
  String? _microphoneProblem;
  String? _cameraProblem;
  CallState _state = CallState.connecting;
  List<CallPerson> _people = const <CallPerson>[];
  lk.EventsListener<lk.RoomEvent>? _events;

  /// Connects with the ticket, then turns on the microphone and camera. A
  /// camera that will not start leaves a voice call rather than no call.
  static Future<LiveKitCallSession> join(CallTicket ticket, {bool music = false}) async {
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: lk.CameraCaptureOptions(params: lk.VideoParametersPresets.h540_169),
      ),
    );
    final session = LiveKitCallSession._(room, music);
    session._events = room.createListener()..listen((event) => session._eventArrived(event));
    try {
      await room.connect(ticket.url, ticket.token);
    } catch (_) {
      await session._close();
      rethrow;
    }
    session._state = CallState.connected;
    // Neither a microphone nor a camera is needed to be in a call: somebody
    // on a computer with neither can still listen to a lesson and watch it.
    try {
      await session._publishMicrophone(on: true);
    } catch (error) {
      session._microphoneProblem = deviceProblem(error, device: 'microphone');
    }
    try {
      await room.localParticipant?.setCameraEnabled(true);
    } catch (error) {
      session._cameraProblem = deviceProblem(error, device: 'camera');
    }
    session._refresh();
    return session;
  }

  void _eventArrived(lk.RoomEvent event) {
    if (event is lk.RoomDisconnectedEvent) _state = CallState.ended;
    _refresh();
  }

  void _refresh() {
    final local = _room.localParticipant;
    _people = <CallPerson>[
      if (local != null) _personFrom(local, isYou: true),
      for (final remote in _room.remoteParticipants.values) _personFrom(remote, isYou: false),
    ];
    notifyListeners();
  }

  CallPerson _personFrom(lk.Participant<lk.TrackPublication> participant, {required bool isYou}) {
    lk.VideoTrack? video;
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (publication.source == lk.TrackSource.camera && !publication.muted && track is lk.VideoTrack) {
        video = track;
      }
    }
    return CallPerson(
      userId: personOfIdentity(participant.identity),
      name: participant.name.isEmpty ? 'Somebody' : participant.name,
      isYou: isYou,
      micOn: participant.isMicrophoneEnabled(),
      cameraOn: video != null,
      video: video,
    );
  }

  Future<void> _publishMicrophone({required bool on}) async {
    final local = _room.localParticipant;
    if (local == null) return;
    for (final publication in List<lk.LocalTrackPublication>.of(local.audioTrackPublications)) {
      await local.removePublishedTrack(publication.sid);
    }
    final track = await lk.LocalAudioTrack.create(captureFor(music: _musicMode));
    await local.publishAudioTrack(track, publishOptions: publishFor(music: _musicMode));
    if (!on) await local.setMicrophoneEnabled(false);
  }

  @override
  CallState get state => _state;

  @override
  List<CallPerson> get people => _people;

  @override
  bool get micOn => _room.localParticipant?.isMicrophoneEnabled() ?? false;

  @override
  bool get cameraOn => _room.localParticipant?.isCameraEnabled() ?? false;

  @override
  bool get musicMode => _musicMode;

  @override
  String? get microphoneProblem => _microphoneProblem;

  @override
  String? get cameraProblem => _cameraProblem;

  @override
  Future<void> setMic(bool on) async {
    if (_microphoneProblem != null) return;
    await _room.localParticipant?.setMicrophoneEnabled(on);
    _refresh();
  }

  @override
  Future<void> setCamera(bool on) async {
    try {
      await _room.localParticipant?.setCameraEnabled(on);
      _cameraProblem = null;
    } catch (error) {
      _cameraProblem = deviceProblem(error, device: 'camera');
    }
    _refresh();
  }

  @override
  Future<void> flipCamera() async {
    final local = _room.localParticipant;
    if (local == null) return;
    for (final publication in local.videoTrackPublications) {
      final track = publication.track;
      final options = track?.currentOptions;
      if (track is lk.LocalVideoTrack && options is lk.CameraCaptureOptions) {
        await track.setCameraPosition(options.cameraPosition.switched());
      }
    }
    _refresh();
  }

  @override
  Future<void> setMusicMode(bool on) async {
    if (on == _musicMode) return;
    _musicMode = on;
    if (_microphoneProblem != null) {
      notifyListeners();
      return;
    }
    await _publishMicrophone(on: micOn);
    _refresh();
  }

  @override
  Future<void> leave() async {
    if (_state == CallState.ended) return;
    _state = CallState.ended;
    await _close();
    notifyListeners();
  }

  Future<void> _close() async {
    await _events?.dispose();
    _events = null;
    try {
      await _room.disconnect();
    } finally {
      unawaited(_room.dispose());
    }
  }
}
