import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What the analysis screen says first.
///
/// The song sheet — the chords over the words, the one thing this app does
/// that nothing else does — was fifth on this page. Above it sat nine
/// measurements ("Lyric match 87%", "Chord changes 118"), a structure
/// breakdown, a stem player, and a badge reading PREMIUM PREVIEW.
///
/// Somebody had just sung into their phone and been handed back their own
/// music, and the first thing the app told them was how well it thought it
/// had done.
///
/// **Asserted against the source, deliberately.** Everything here lives
/// inside a branch that only renders once a finished analysis bundle exists,
/// which needs a reference recording, stems, chord cues and lyric cues to
/// reach. A widget test that cannot reach the branch passes whether or not
/// the badge is there — which is exactly how it survived the sweep that was
/// supposed to remove every piece of beta framing in the app. Reading the
/// file is cruder and actually checks the thing.
void main() {
  late String source;

  setUpAll(() {
    source = File('lib/features/workspace/song_analysis_screen.dart')
        .readAsStringSync();
  });

  test('the screen no longer calls its best moment a preview', () {
    // The quoted literal, not the word: a comment explaining why the badge
    // went would otherwise fail this forever.
    expect(
      source.contains("'PREMIUM PREVIEW'"),
      isFalse,
      reason: 'the song sheet screen calls itself a preview again',
    );
  });

  test('the sheet comes before the measurements', () {
    final sheet = source.indexOf('SongSheetPanel(');
    final details = source.indexOf('_TheDetails(');
    expect(sheet, greaterThan(-1), reason: 'the sheet panel is gone');
    expect(details, greaterThan(-1), reason: 'the details fold is gone');
    expect(
      sheet,
      lessThan(details),
      reason: 'the measurements are above the song sheet again',
    );
  });

  test('the measurements are behind a fold, not on the page', () {
    // All three of these were unconditional children of the ready branch.
    // They may only appear inside _TheDetails now, which starts closed.
    final fold = source.indexOf('class _TheDetails');
    expect(fold, greaterThan(-1), reason: 'the fold is gone');

    for (final buried in <String>[
      '_AnalysisSummary(bundle:',
      '_SongUnderstanding(',
      'StemPlayerPanel(',
    ]) {
      final where = source.indexOf(buried);
      expect(where, greaterThan(-1), reason: '$buried disappeared entirely');
      expect(
        where,
        greaterThan(fold),
        reason: '$buried is back on the page above the song sheet',
      );
    }

    expect(
      source.contains("Key('analysis_details_toggle')"),
      isTrue,
      reason: 'there is no way to open the details',
    );
    expect(
      source.contains('bool _open = false'),
      isTrue,
      reason: 'the details no longer start folded',
    );
  });
}
