import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/features/calls/call_screen.dart';
import 'package:colabroom/features/calls/room_call_bar.dart';
import 'package:colabroom/services/call_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An under-13 answer is not a retry.
///
/// The audit of 17 September 2026 (CO1): a birth year that made somebody
/// under 13 said "CoLabRoom is for people 13 and over." and left the year
/// picker open, so the next try could pick an older year. The FTC's COPPA FAQ
/// (D.7, H.3) advises an age screen not to invite that, and to stop somebody
/// going back to enter a different age. Now the sheet closes, calls stay
/// closed on that account, and the picker is never offered again (0138).
class _NeverJoins extends CallSession {
  @override
  CallState get state => CallState.connected;
  @override
  List<CallPerson> get people => const <CallPerson>[];
  @override
  bool get micOn => false;
  @override
  bool get cameraOn => false;
  @override
  bool get musicMode => false;
  @override
  Future<void> setMic(bool on) async {}
  @override
  Future<void> setCamera(bool on) async {}
  @override
  Future<void> flipCamera() async {}
  @override
  Future<void> setMusicMode(bool on) async {}
  @override
  Future<void> leave() async {}
}

/// This account answered under 13 on another phone, after this one last
/// looked: the server refuses the answer and only then reads 'refused'.
class _AnsweredElsewhere extends InMemoryMusicRepository {
  _AnsweredElsewhere() : super.from(InMemoryMusicRepository.seeded());

  bool _answered = false;

  @override
  Future<CallStanding> myCallStanding() async => _answered ? CallStanding.refused : CallStanding.unknown;

  @override
  Future<CallStanding> setMyBirthMonth({required int year, required int month}) async {
    _answered = true;
    throw const NameConflict(callsClosedOnThisAccount);
  }
}

Future<String> _roomCallBar(WidgetTester tester, InMemoryMusicRepository repository) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  final roomId = controller.rooms.first.id;
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(18),
          child: RoomCallBar(
            roomId: roomId,
            roomName: 'Band',
            repository: repository,
            me: repository.currentUserId,
            join: (_) async => _NeverJoins(),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return roomId;
}

Future<void> _callTheRoom(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('room_call_start')));
  await tester.pumpAndSettle();
}

Future<void> _answer(WidgetTester tester, {required int year, required int month}) async {
  tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('birth_month'))).onChanged!(month);
  tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('birth_year'))).onChanged!(year);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('birth_save')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an under-13 answer closes the sheet, and the picker is never offered again', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _roomCallBar(tester, repository);

    await _callTheRoom(tester);
    expect(find.text('Before your first call'), findsOneWidget);
    await _answer(tester, year: DateTime.now().year - 9, month: 1);

    expect(find.text('Before your first call'), findsNothing, reason: 'the sheet closed');
    expect(find.byKey(const Key('birth_year')), findsNothing);
    expect(find.text(callsClosedOnThisAccount), findsOneWidget);
    expect(find.textContaining('13'), findsNothing, reason: 'no age to aim a second answer at');
    expect(await repository.myCallStanding(), CallStanding.refused);
    await tester.tap(find.byKey(const Key('call_closed_ok')));
    await tester.pumpAndSettle();

    // The second try the audit found.
    await _callTheRoom(tester);
    expect(find.text('Before your first call'), findsNothing);
    expect(find.byKey(const Key('birth_year')), findsNothing);
    expect(find.text(callsClosedOnThisAccount), findsOneWidget);
    expect(find.byType(CallScreen), findsNothing);
  });

  testWidgets('an answer refused because of one given elsewhere closes the sheet too', (tester) async {
    final repository = _AnsweredElsewhere();
    await _roomCallBar(tester, repository);

    await _callTheRoom(tester);
    await _answer(tester, year: 1990, month: 5);

    expect(find.byKey(const Key('birth_year')), findsNothing);
    expect(find.byKey(const Key('birth_problem')), findsNothing);
    expect(find.text(callsClosedOnThisAccount), findsOneWidget);
  });

  testWidgets('the call screen says the same sentence, and asks for nothing', (tester) async {
    final repository = InMemoryMusicRepository.seeded()..callStanding = CallStanding.refused;
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    final roomId = controller.rooms.first.id;
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: CallScreen(roomId: roomId, roomName: 'Band', repository: repository, join: (_) async => _NeverJoins()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call_problem')), findsOneWidget);
    expect(find.text(callsClosedOnThisAccount), findsOneWidget);
    expect(find.textContaining('birth month'), findsNothing);
  });

  group('the repository', () {
    test('reads refused from the server, and anything it does not know as never asked', () {
      expect(callStandingFrom('refused'), CallStanding.refused);
      expect(callStandingFrom('adult'), CallStanding.adult);
      expect(callStandingFrom('something newer'), CallStanding.unknown);
      expect(callStandingFrom(null), CallStanding.unknown);
    });

    test('an under-13 answer is remembered, and an adult answer after it is refused', () async {
      final repository = InMemoryMusicRepository.seeded();
      expect(await repository.setMyBirthMonth(year: DateTime.now().year - 9, month: 1), CallStanding.refused);
      await expectLater(
        repository.setMyBirthMonth(year: 1990, month: 5),
        throwsA(isA<NameConflict>().having((e) => e.message, 'message', callsClosedOnThisAccount)),
      );
      expect(await repository.myCallStanding(), CallStanding.refused);
    });

    test('a ticket is refused with the sentence, not a request for a birth month', () async {
      final repository = InMemoryMusicRepository.seeded()..callStanding = CallStanding.refused;
      final roomId = (await repository.loadRooms()).first.id;
      await expectLater(
        repository.callTicket(roomId: roomId, device: 'phone'),
        throwsA(isA<CallRefused>()
            .having((e) => e.message, 'message', callsClosedOnThisAccount)
            .having((e) => e.birthMonthNeeded, 'birthMonthNeeded', isFalse)),
      );
    });
  });

  test('the server says the words the app says, and keeps no month', () {
    final migration = File('supabase/migrations/0138_an_age_answer_stays.sql').readAsStringSync();
    expect(migration, contains("'$callsClosedOnThisAccount'"),
        reason: 'call-token passes may_join_call\'s words to the call screen as they are');
    expect(migration, contains("return 'refused'"));
  });
}
