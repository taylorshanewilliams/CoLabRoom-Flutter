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

/// Who a LiveKit identity belongs to: call-token writes `<user id>:<device>`.
String personOfIdentity(String identity) => identity.split(':').first;

class LiveKitCallSession extends CallSession {
  LiveKitCallSession._(this._room, this._musicMode);

  final lk.Room _room;
  bool _musicMode;
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
    await session._publishMicrophone(on: true);
    try {
      await room.localParticipant?.setCameraEnabled(true);
    } catch (_) {
      // No camera, or not allowed: the call goes on with sound.
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
  Future<void> setMic(bool on) async {
    await _room.localParticipant?.setMicrophoneEnabled(on);
    _refresh();
  }

  @override
  Future<void> setCamera(bool on) async {
    await _room.localParticipant?.setCameraEnabled(on);
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
