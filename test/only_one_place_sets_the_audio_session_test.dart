import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One owner for the phone's audio session, checked against the source.
///
/// The state machine in one_owner_for_the_phones_audio_test proves that the
/// owner decides the right thing. This proves that it is the only thing
/// deciding — which is the part that rots, because the next screen that
/// wants a sound will reach for an AudioPlayer, and the next feature that
/// wants the microphone will reach for an AudioRecorder, and neither will
/// think about a call being up.
///
/// A phone has one audio session, global to the app process. Before
/// lib/services/phone_audio.dart there were three libraries writing it: a
/// LiveKit call setting iOS to playAndRecord/videoChat and Android to
/// MODE_IN_COMMUNICATION, audioplayers writing a category with no mode on
/// iOS and `audioManager.mode` on Android, and record opening the microphone
/// underneath both. Whoever wrote last won, and the loser failed silently.
void main() {
  /// Where the one owner lives, and the only file these rules exempt.
  const owner = 'lib/services/phone_audio.dart';

  /// Every .dart file under lib/, as (path, source).
  final sources = <String, String>{
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        entity.path.replaceAll(r'\', '/'): entity.readAsStringSync(),
  };

  setUpAll(() {
    // A guard on the guard: a scan that found no files would pass every test
    // below without reading a line.
    expect(sources.length, greaterThan(100));
    expect(sources.keys, contains(owner));
  });

  test('nothing but the owner writes an audio session', () {
    // Each of these is a way to write the phone's one session:
    // - AudioContext( builds one for audioplayers,
    // - setAudioContext( applies it, globally on iOS either way,
    // - AudioPlayer.global is the app-wide default,
    // - AudioManager is LiveKit's, which owns the session during a call.
    const ways = <String>[
      'AudioContext(',
      'setAudioContext(',
      'AudioPlayer.global',
      'AudioManager',
    ];
    final elsewhere = <String>[];
    sources.forEach((path, source) {
      if (path == owner) return;
      for (final way in ways) {
        if (source.contains(way)) elsewhere.add('$path uses $way');
      }
    });
    expect(
      elsewhere,
      isEmpty,
      reason: 'The phone has one audio session. Ask $owner for it instead.',
    );
  });

  test('everything that makes a sound or opens the microphone asks the owner', () {
    // Constructing one of these is the moment a file becomes an audio user:
    // a player that sounds during a call must not ask Android for the focus
    // the call is holding, and a recorder that opens must first have the
    // call let the microphone go. The speech recognizer counts because
    // dictation opens the microphone too, and on iOS takes the shared
    // session for itself.
    //
    // flutter_tts is deliberately not here. It writes no configuration: the
    // one thing it is asked for is `autoStopSharedSession(false)`, which
    // tells it *not* to take the session down at the end of an utterance —
    // see chord_voice.dart, which found that collision before this owner
    // existed and is already on the right side of this rule.
    const users = <String>[
      'AudioPlayer(',
      'AudioRecorder(',
      'package:speech_to_text/',
    ];
    final silent = <String>[];
    sources.forEach((path, source) {
      if (path == owner) return;
      final usesAudio = users.any(source.contains);
      if (usesAudio && !source.contains('phone_audio.dart')) silent.add(path);
    });
    expect(
      silent,
      isEmpty,
      reason: 'These build a player or a recorder without asking $owner.',
    );
  });

  test('the owner says why, at length, because the next person will doubt it', () {
    // The evidence cost three rounds of fixes to find, and the file it lived
    // in is gone. It is load bearing: without it the obvious reading of the
    // no-focus request below is that it is superstition.
    final source = sources[owner]!;
    expect(source, contains('2,486 bytes'));
    expect(source, contains('41,073 bytes'));
  });
}
