import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/widgets/offer_to_be_found.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asking somebody whether they would like to be findable.
///
/// Zero of the real accounts in production are discoverable, against
/// seventy-five seeded ones — so every result the search returns today is a
/// bot, and the person running the search is invisible to the room they are
/// standing in. `discoverable` defaulting to false is right; never asking is
/// not, and the only place that asked was a button on your own profile page.
///
/// The rules worth testing are the ones that keep it from being a nag or a
/// trick: it never appears for somebody already findable, it says what it
/// will claim about them before it claims it, and no is an answer it
/// remembers.
Future<void> _run(WidgetTester tester, InMemoryMusicRepository repository) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => BeFound.offer(context, repository),
          child: const Text('go'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('it says what it will claim, from what they actually recorded',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _run(tester, repository);

    expect(find.text('Can they find you too?'), findsOneWidget);
    // The preview account has recorded bass and never said it plays bass,
    // which is the state this exists for. Said out loud rather than done
    // quietly: it is a claim about somebody, made from their own takes.
    expect(find.textContaining('you play bass'), findsOneWidget);
  });

  testWidgets('yes turns it on and claims the part', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _run(tester, repository);
    await tester.tap(find.text('Let them find me'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final me = await repository.loadMusician(repository.currentUserId);
    expect(me!.discoverable, isTrue);
    expect(me.plays, contains('bass'),
        reason: 'findable with an empty plays list is findable by nobody — '
            'find_musicians matches on what you say you do');
  });

  testWidgets('and never asks somebody who is already findable',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await repository.setOpenMicPresence(discoverable: true);
    await _run(tester, repository);
    expect(find.text('Can they find you too?'), findsNothing);
  });

  testWidgets('no is an answer, and it is remembered', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _run(tester, repository);
    await tester.tap(find.text('Not now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await _run(tester, repository);
    expect(find.text('Can they find you too?'), findsNothing,
        reason: 'a decline that is forgotten on the next search is a nag');
  });
}
