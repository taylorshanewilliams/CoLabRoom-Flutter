import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/widgets/profile_face.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A musician's page with a musician on it.
///
/// This screen had no avatar at all — not a small one, not a fallback,
/// nothing. Which makes it a database row with headings, and a picture is the
/// first thing anybody deciding whether to work with a stranger looks for.
void main() {
  testWidgets('somebody has a face on their own page', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: MusicianProfileScreen(
        profileId: 'preview-mara',
        repository: InMemoryMusicRepository.seeded(),
      ),
    ));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.byType(ProfileFace), findsOneWidget);
    expect(find.text('ME'), findsOneWidget,
        reason: 'almost nobody has uploaded a picture, so the fallback is the '
            'common case and has to be worth looking at');
  });

  testWidgets('and their record is a shape as well as a number',
      (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: MusicianProfileScreen(
        profileId: 'preview-mara',
        repository: InMemoryMusicRepository.seeded(),
      ),
    ));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.byType(PartsSignature), findsOneWidget);
    // The chips stay. The shape is what you see first and the number is what
    // you read second; replacing one with the other would lose the count.
    expect(find.text('vocal · 9'), findsOneWidget);
  });

  test('a colour belongs to a person and does not wander', () {
    // Derived rather than stored, so it costs no column and can never
    // disagree with itself between two screens.
    expect(colourFor('preview-mara'), colourFor('preview-mara'));
    expect(colourFor('preview-mara'), isNot(colourFor('preview-dev')));
  });

  testWidgets('nobody with an empty record gets an empty chart',
      (tester) async {
    // Sam has recorded nothing. A signature with no bars in it is a smudge
    // where a heading should be.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PartsSignature(parts: <String, int>{}, seed: 'preview-sam'),
      ),
    ));
    await tester.pump();

    expect(tester.getSize(find.byType(PartsSignature)), Size.zero);
  });

  testWidgets('somebody can say something in their own words', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: MusicianProfileScreen(
        profileId: 'preview-mara',
        repository: InMemoryMusicRepository.seeded(),
      ),
    ));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(
      find.textContaining('write when nobody is listening'),
      findsOneWidget,
      reason: 'every other field on this page is either counted by the app or '
          'picked from a list; this is the only one that is a sentence',
    );
  });

  testWidgets('a stranger is never told what is missing from their page',
      (tester) async {
    // "Say something about yourself" is an offer, and an offer only makes
    // sense to the person who could accept it. On somebody else's page it
    // would say nothing except that the app expected more of them.
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: MusicianProfileScreen(
        // Dev has no bio.
        profileId: 'preview-dev',
        repository: InMemoryMusicRepository.seeded(),
      ),
    ));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Say something about yourself'), findsNothing);
  });

  test('an empty bio clears the field rather than storing a blank', () async {
    final repository = InMemoryMusicRepository.seeded();
    await repository.setBio('  Plays bass, mostly badly.  ');
    var me = await repository.loadMusician(repository.currentUserId);
    expect(me!.bio, 'Plays bass, mostly badly.',
        reason: 'trimmed, the way set_bio does it on the server');

    await repository.setBio('   ');
    me = await repository.loadMusician(repository.currentUserId);
    expect(me!.bio, isNull,
        reason: 'a field you can fill in and not empty is not a field');
  });
}
