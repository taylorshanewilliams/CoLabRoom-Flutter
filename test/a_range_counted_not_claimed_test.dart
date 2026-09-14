import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A singer's range on their page, and the rules that keep it honest.
///
/// It is the first thing on a profile that the app *heard* rather than
/// counted from takes or read from a chip, and the rules are the same as for
/// everything else under "Played here": it appears only when there is
/// something behind it, it says how much is behind it, and nobody can type
/// it. The server decides who gets one (somebody who says they sing, from
/// recordings they uploaded); the app's job is to show it as what it is.
Future<void> _boot(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: screen,
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// The profile is a lazy list; what is below the fold has not been built.
Future<Finder> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return finder;
  await tester.scrollUntilVisible(finder, 220, maxScrolls: 12);
  await tester.pump(const Duration(milliseconds: 60));
  return finder;
}

Musician _somebody({int? low, int? high, int songs = 0}) => Musician(
      id: 'x',
      displayName: 'X',
      plays: const <String>['vocal'],
      partsRecorded: const <String, int>{},
      songsPlayedOn: 0,
      peopleWorkedWith: 0,
      vocalLowMidi: low,
      vocalHighMidi: high,
      vocalRangeSongs: songs,
    );

void main() {
  group('the range label', () {
    test('names both ends the way a singer would', () {
      expect(_somebody(low: 52, high: 69, songs: 3).vocalRangeLabel, 'E3 – A4');
    });

    test('is one note when the ends meet', () {
      expect(_somebody(low: 69, high: 69, songs: 1).vocalRangeLabel, 'A4');
    });

    test('is nothing until both ends were counted', () {
      // Half a range is not a range, and a range with nothing behind it is
      // exactly the kind of claim this section exists to keep out.
      expect(_somebody().vocalRangeLabel, isNull);
      expect(_somebody(low: 52).vocalRangeLabel, isNull);
      expect(_somebody(high: 69).vocalRangeLabel, isNull);
    });
  });

  testWidgets('a singer’s page says the range and where it came from',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    final mara = (await repository.loadMusician('preview-mara'))!;
    expect(mara.vocalRangeLabel, 'E3 – C5');

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: mara.id,
        repository: repository,
        initial: mara,
      ),
    );
    expect(tester.takeException(), isNull, reason: 'the profile did not draw');

    // Under the heading whose note is the whole point.
    expect(await _reveal(tester, find.text('counted, not claimed')),
        findsOneWidget);
    expect(
      await _reveal(
        tester,
        find.text('Sings E3 – C5 · heard on 5 songs', findRichText: true),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a page with no range says nothing about one', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    final dev = (await repository.loadMusician('preview-dev'))!;
    expect(dev.vocalRangeLabel, isNull);

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: dev.id,
        repository: repository,
        initial: dev,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(await _reveal(tester, find.text('counted, not claimed')),
        findsOneWidget);
    // Not a dash, not "no range yet": a drummer's page simply has no such
    // line, the same way it has no "vocal · 0" chip.
    expect(find.textContaining('Sings', findRichText: true), findsNothing);
    expect(find.textContaining('heard on', findRichText: true), findsNothing);
  });

  testWidgets('your own page keeps the range through a settings change',
      (tester) async {
    // Every preview mutation rebuilds the profile by hand; a field added to
    // the model and forgotten there would silently vanish after the first
    // edit, which is how "sounds like" went missing once already.
    final repository = InMemoryMusicRepository.seeded();
    final before = (await repository.loadMusician(repository.currentUserId))!;
    expect(before.vocalRangeLabel, 'D3 – G4');

    await repository.setBio('Plays late.');
    await repository.claimPart('bass');
    await repository.setOpenMicPresence(discoverable: true);
    final after = (await repository.loadMusician(repository.currentUserId))!;
    expect(after.vocalRangeLabel, 'D3 – G4');
    expect(after.vocalRangeSongs, 2);
  });
}
