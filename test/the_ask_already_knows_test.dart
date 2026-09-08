import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/ask_musician_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the ask sheet already knows.
///
/// Somebody walks the Open Mic down to bass, listens to three people and taps
/// one. They have now said "bass" twice, in two screens. The sheet used to
/// open on a row of sixteen chips with nothing selected and ask them a third
/// time — the app making somebody re-enter a decision it watched them make.
///
/// Two things fill it in, in that order of authority: what they searched for,
/// and failing that, the first thing this person does that the song has not
/// got. Both are starting points. Neither is allowed to keep moving once
/// somebody has set the chips themselves.
const _mara = Musician(
  id: 'preview-mara',
  displayName: 'Mara Ellison',
  plays: <String>['bass', 'keys'],
  partsRecorded: <String, int>{},
  songsPlayedOn: 0,
  peopleWorkedWith: 0,
);

Future<void> _open(WidgetTester tester, {String? lookingFor}) async {
  tester.view.physicalSize = const Size(390, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: AskMusicianSheet(
        musician: _mara,
        repository: InMemoryMusicRepository.seeded(),
        suggestedPart: lookingFor,
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

/// Whether a chip reads as chosen.
///
/// Asked of the chip rather than of its label's colour: the sheet sets the
/// colour through `labelStyle`, so the Text inside carries no style of its
/// own and a test reading it would pass on a screen showing nothing lit.
bool _lit(WidgetTester tester, String label) {
  return tester
      .widgetList<FilterChip>(find.byType(FilterChip))
      .any((chip) =>
          chip.label is Text &&
          (chip.label as Text).data == label &&
          chip.selected);
}

void main() {
  testWidgets('what you searched for arrives already chosen', (tester) async {
    await _open(tester, lookingFor: 'bass');
    expect(_lit(tester, 'Bass'), isTrue,
        reason: 'the sheet asked again for something already said twice');
  });

  testWidgets('failing that, what this person does that the song lacks',
      (tester) async {
    // The preview song has a voice and a guitar on it. Mara plays bass and
    // keys, so bass is the first thing she does that it has not got.
    await _open(tester);
    expect(_lit(tester, 'Bass'), isTrue);
    expect(_lit(tester, 'Rhythm'), isFalse,
        reason: 'a part already on the song is not what it is short of');
  });

  testWidgets('and it is a suggestion, not a decision', (tester) async {
    await _open(tester, lookingFor: 'bass');
    // Tapping the lit chip turns it off, and it stays off. "Not sure yet" is
    // an honest state and the one most unfinished songs are in.
    await tester.tap(find.text('Bass'));
    await tester.pump();
    expect(_lit(tester, 'Bass'), isFalse);
  });
}
