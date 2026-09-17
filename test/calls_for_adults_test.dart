import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/calls/call_screen.dart';
import 'package:colabroom/features/calls/room_call_bar.dart';
import 'package:colabroom/services/call_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// Calls for adults.
///
/// Slice 4, stage A, agreed with Taylor on 16 September 2026: live voice and
/// video between adults who share a room, music mode for instruments, report
/// and block inside the call, nothing recorded. 13-17 come next, through a
/// parent or guardian.
class _FakeCall extends CallSession {
  _FakeCall(this._people);

  final List<CallPerson> _people;
  bool _mic = true;
  bool _camera = true;
  bool _music = false;
  CallState _state = CallState.connected;
  bool left = false;

  @override
  CallState get state => _state;
  @override
  List<CallPerson> get people => _people;
  @override
  bool get micOn => _mic;
  @override
  bool get cameraOn => _camera;
  @override
  bool get musicMode => _music;

  @override
  Future<void> setMic(bool on) async {
    _mic = on;
    notifyListeners();
  }

  @override
  Future<void> setCamera(bool on) async {
    _camera = on;
    notifyListeners();
  }

  @override
  Future<void> flipCamera() async {}

  @override
  Future<void> setMusicMode(bool on) async {
    _music = on;
    notifyListeners();
  }

  @override
  Future<void> leave() async {
    if (left) return;
    left = true;
    _state = CallState.ended;
    notifyListeners();
  }
}

const _you = CallPerson(userId: 'preview-user', name: 'Taylor', isYou: true, micOn: true, cameraOn: false);
const _jess = CallPerson(userId: 'preview-jess', name: 'Jess', isYou: false, micOn: false, cameraOn: false);

Future<MusicBetaController> _boot(WidgetTester tester, InMemoryMusicRepository repository, Widget home) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('the sound of a call', () {
    test('music mode turns off everything that eats a held note', () {
      final music = captureFor(music: true);
      expect(music.echoCancellation, isFalse);
      expect(music.noiseSuppression, isFalse);
      expect(music.autoGainControl, isFalse);
      expect(music.highPassFilter, isFalse);
      expect(music.voiceIsolation, isFalse);
      expect(music.typingNoiseDetection, isFalse);

      final sent = publishFor(music: true);
      expect(sent.dtx, isFalse, reason: 'the tail of a note is not silence');
      expect(sent.encoding, lk.AudioEncoding.presetMusicHighQuality);
    });

    test('a voice call keeps the processing voices need', () {
      final voice = captureFor(music: false);
      expect(voice.echoCancellation, isTrue);
      expect(voice.noiseSuppression, isTrue);
      expect(publishFor(music: false).encoding, lk.AudioEncoding.presetSpeech);
    });

    test('an identity says whose phone it is', () {
      expect(personOfIdentity('0f0e0d0c-0000-4000-8000-000000000001:abc123'),
          '0f0e0d0c-0000-4000-8000-000000000001');
      expect(callStandingFrom('adult'), CallStanding.adult);
      expect(callStandingFrom('minor'), CallStanding.minor);
      expect(callStandingFrom('unknown'), CallStanding.unknown);
      expect(notificationTypeFromSql('call_started'), NotificationType.callStarted);
    });
  });

  group('getting in', () {
    Future<(InMemoryMusicRepository, String)> room(WidgetTester tester, {CallStanding? standing}) async {
      final repository = InMemoryMusicRepository.seeded();
      if (standing != null) repository.callStanding = standing;
      final controller = MusicBetaController(repository);
      await controller.load();
      final roomId = controller.rooms.first.id;
      controller.dispose();
      await _boot(
        tester,
        repository,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(18),
            child: RoomCallBar(
              roomId: roomId,
              roomName: 'Guitar lessons · Jess',
              repository: repository,
              me: repository.currentUserId,
              join: (_) async => _FakeCall(<CallPerson>[_you]),
            ),
          ),
        ),
      );
      return (repository, roomId);
    }

    Future<void> chooseBirth(WidgetTester tester, {required int year, required int month}) async {
      tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('birth_month'))).onChanged!(month);
      tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('birth_year'))).onChanged!(year);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('birth_save')));
      await tester.pumpAndSettle();
    }

    testWidgets('a first call asks for a birth month, once, and then connects an adult', (tester) async {
      final (repository, roomId) = await room(tester);
      await tester.tap(find.byKey(const Key('room_call_start')));
      await tester.pumpAndSettle();
      expect(find.text('Before your first call'), findsOneWidget);

      await chooseBirth(tester, year: 1990, month: 5);

      expect(find.byType(CallScreen), findsOneWidget);
      expect(find.byKey(const Key('call_waiting')), findsOneWidget);
      expect(await repository.myCallStanding(), CallStanding.adult);
      expect((await repository.roomCall(roomId)).map((p) => p.userId), contains(repository.currentUserId),
          reason: 'the phone says it is in the call, which is how the room shows Join');
    });

    testWidgets('under 13 is refused and not kept', (tester) async {
      final (repository, _) = await room(tester);
      await tester.tap(find.byKey(const Key('room_call_start')));
      await tester.pumpAndSettle();
      await chooseBirth(tester, year: DateTime.now().year - 6, month: 1);

      expect(find.text('CoLabRoom is for people 13 and over.'), findsOneWidget);
      expect(await repository.myCallStanding(), CallStanding.unknown);
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('a teenager is told why, and what is coming, instead of a call', (tester) async {
      await room(tester, standing: CallStanding.minor);
      await tester.tap(find.byKey(const Key('room_call_start')));
      await tester.pumpAndSettle();

      expect(find.text('Calls are 18+ for now'), findsOneWidget);
      expect(find.textContaining('parent or guardian'), findsOneWidget);
      await tester.tap(find.byKey(const Key('call_minor_ok')));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('somebody already in the call shows at the top of the room, with Join', (tester) async {
      final repository = InMemoryMusicRepository.seeded()..callStanding = CallStanding.adult;
      final controller = MusicBetaController(repository);
      await controller.load();
      final roomId = controller.rooms.first.id;
      controller.dispose();
      repository.somebodyInCall(roomId: roomId, userId: 'preview-jess', displayName: 'Jess');

      await _boot(
        tester,
        repository,
        Scaffold(
          body: RoomCallBar(
            roomId: roomId,
            roomName: 'Band',
            repository: repository,
            me: repository.currentUserId,
            join: (_) async => _FakeCall(<CallPerson>[_you, _jess]),
          ),
        ),
      );

      expect(find.text('Jess is in a call'), findsOneWidget);
      await tester.tap(find.byKey(const Key('room_call_join')));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsOneWidget);
      expect(find.text('Jess'), findsOneWidget);
    });
  });

  group('in the call', () {
    Future<(InMemoryMusicRepository, String, _FakeCall)> inCall(WidgetTester tester) async {
      final repository = InMemoryMusicRepository.seeded()..callStanding = CallStanding.adult;
      final controller = MusicBetaController(repository);
      await controller.load();
      final roomId = controller.rooms.first.id;
      controller.dispose();
      final call = _FakeCall(<CallPerson>[_you, _jess]);
      await _boot(
        tester,
        repository,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => CallScreen(
                    roomId: roomId,
                    roomName: 'Band',
                    repository: repository,
                    join: (_) async => call,
                  ),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (repository, roomId, call);
    }

    testWidgets('says nothing is recorded, and mutes, and turns on music mode with a word about headphones',
        (tester) async {
      final (_, _, call) = await inCall(tester);
      expect(find.text('Call · nothing is recorded'), findsOneWidget);

      await tester.tap(find.byKey(const Key('call_mic')));
      await tester.pump();
      expect(call.micOn, isFalse);

      await tester.tap(find.byKey(const Key('call_music')));
      await tester.pump();
      expect(call.musicMode, isTrue);
      expect(find.textContaining('Wear headphones'), findsOneWidget);
    });

    testWidgets('leaving leaves the call and the room stops showing you in it', (tester) async {
      final (repository, roomId, call) = await inCall(tester);
      expect((await repository.roomCall(roomId)).map((p) => p.userId), contains(repository.currentUserId));

      await tester.tap(find.byKey(const Key('call_leave')));
      await tester.pumpAndSettle();

      expect(call.left, isTrue);
      expect(find.byType(CallScreen), findsNothing);
      expect((await repository.roomCall(roomId)).map((p) => p.userId), isNot(contains(repository.currentUserId)));
    });

    testWidgets('blocking somebody in the call blocks them and leaves', (tester) async {
      final (repository, _, call) = await inCall(tester);
      await tester.tap(find.byKey(const Key('call_about_preview-jess')));
      await tester.pumpAndSettle();
      expect(find.text('Report Jess'), findsOneWidget);

      await tester.tap(find.byKey(const Key('call_block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('call_block_confirm')));
      await tester.pumpAndSettle();

      expect((await repository.peopleIBlocked()).map((person) => person.id), contains('preview-jess'));
      expect(call.left, isTrue);
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('a call that will not let somebody in says why', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final controller = MusicBetaController(repository);
      await controller.load();
      final roomId = controller.rooms.first.id;
      controller.dispose();
      await _boot(
        tester,
        repository,
        CallScreen(roomId: roomId, roomName: 'Band', repository: repository, join: (_) async => _FakeCall(<CallPerson>[_you])),
      );
      expect(find.byKey(const Key('call_problem')), findsOneWidget);
      expect(find.text('Your birth month first.'), findsOneWidget);
    });
  });

  group('the phones and the server', () {
    test('both phones may use the camera, and iPhones are told why', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android.permission.CAMERA'));
      expect(manifest, contains('android:name="android.hardware.camera" android:required="false"'));
      final ios = File('.github/workflows/build-ios-testflight.yml').readAsStringSync();
      expect(ios, contains('NSCameraUsageDescription'));
      expect(ios, contains('never recorded'));
    });

    test('call-token is deployed, with its secrets, and grants no recording', () {
      final deploy = File('.github/workflows/deploy-analyze-chords.yml').readAsStringSync();
      expect(deploy, contains('supabase functions deploy call-token'));
      expect(deploy, contains('LIVEKIT_API_SECRET'));
      final token = File('supabase/functions/call-token/index.ts').readAsStringSync();
      expect(token, contains("rpc('may_join_call'"));
      expect(token, contains("rpc('blocked_with_any'"));
      expect(token, isNot(contains('roomRecord: true')));
      expect(token, isNot(contains('recorder: true')));
    });
  });
}
