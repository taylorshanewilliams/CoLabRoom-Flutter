import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/musical_roles.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:colabroom/features/openmic/what_are_you_after.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The trail.
///
/// The Open Mic used to put four controls above the first person in the room
/// — a segmented button, a horizontal strip of sixteen role chips you could
/// see four of at a time, and two text fields — none of which showed an
/// answer. A phone does not work that way: one question per screen, the
/// specifics one level down, and the value readable on the row without
/// opening it.
///
/// Two things here are worth a test rather than a look. The first is that
/// every role still has a door: a role added to [MusicalRole] and forgotten
/// in [RoleFamily] would be in the data and unreachable from the only place
/// the app offers roles, which no screen would show. The second is that every
/// level is somewhere to stop — being made to pick a leaf to get an answer is
/// what makes a form a form.
Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OpenMicScreen(repository: InMemoryMusicRepository.seeded()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> _tap(WidgetTester tester, Finder what) async {
  await tester.tap(what);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
}

void main() {
  test('every role is behind a door', () {
    expect(
      RoleFamily.coversEveryRole,
      isTrue,
      reason: 'a role exists that the sheet can never reach',
    );
  });

  test('the line says what you are looking at, and which way', () {
    const everybody = OpenMicQuery();
    expect(everybody.sentence, 'Everybody who is here');

    const bass = OpenMicQuery(parts: <String>{'bass'});
    expect(bass.sentence, 'Bass players');
    expect(bass.copyWith(city: 'Leeds').sentence, 'Bass players near Leeds');

    // The same roles, the other way round. This is the whole reason the
    // sentence exists: as tabs, one chip meant "who plays this" under People
    // and "who needs this" under Asking, and nothing on screen said which.
    expect(
      bass.copyWith(looking: OpenMicLooking.songs).sentence,
      'Songs that need bass',
    );

    final family = OpenMicQuery(
      parts: <String>{for (final r in RoleFamily.voices.members) r.value},
    );
    expect(
      family.sentence,
      'Voices and words',
      reason: 'a whole door should read as itself, not as five roles',
    );
  });

  testWidgets('two taps reaches any role, and the line changes', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('Everybody who is here'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('open_mic_statement')));
    // Four doors, and no leaf on the first screen.
    expect(find.text('Instruments'), findsOneWidget);
    expect(find.text('Bass'), findsNothing);

    await _tap(tester, find.text('Instruments'));
    await _tap(tester, find.text('Bass'));

    expect(
      find.text('Bass players'),
      findsOneWidget,
      reason: 'picking a role did not reach the line',
    );
  });

  testWidgets('a door is somewhere to stop', (tester) async {
    await _open(tester);
    await _tap(tester, find.byKey(const Key('open_mic_statement')));
    await _tap(tester, find.text('Instruments'));

    // Wanting "an instrument" is a real thing to want. Making somebody
    // choose between six of them to get an answer is a form asking a
    // question the person does not have.
    await _tap(tester, find.text('Anyone in instruments'));
    expect(
      find.text('Instruments'),
      findsOneWidget,
      reason: 'stopping at a door did not reach the line',
    );
  });

  testWidgets('the direction lives where it is chosen', (tester) async {
    await _open(tester);
    // Not on the screen. As a tab it could sit there inverting every chip
    // below it while out of sight.
    expect(find.text('Who needs it'), findsNothing);

    await _tap(tester, find.byKey(const Key('open_mic_statement')));
    expect(find.text('Who needs it'), findsOneWidget);
    await _tap(tester, find.text('Who needs it'));
    await _tap(tester, find.text('Everybody'));

    expect(find.text('Songs asking for somebody'), findsOneWidget);
  });
}
