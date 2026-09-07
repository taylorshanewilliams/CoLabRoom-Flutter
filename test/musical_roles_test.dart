import 'package:colabroom/domain/musical_roles.dart';
import 'package:flutter_test/flutter_test.dart';

/// Is this app only for rock bands?
///
/// It was. Vocal, harmony, lead, rhythm, bass, drums, keys, percussion — the
/// same eight in five separate lists, each with a comment warning that they
/// had to agree. A rapper looking for a beat maker, a beat maker looking for
/// somebody to rap over it, a lyricist who records nothing at all, somebody
/// who only mixes: none of them could say what they do, so none of them could
/// be found for it.
///
/// And the five lists did not agree. The ask bar in the workspace offered
/// "vocals", "guitar" and "a bridge" — none of which are words the rest of the
/// app stores — so an ask made there could never be matched by the Open Mic
/// filter looking for "vocal". Nobody would have seen that happen; the ask
/// simply never reached anybody.
void main() {
  test('the roles nobody could claim are claimable', () {
    final offered = MusicalRole.offered.map((r) => r.value).toSet();
    for (final needed in <String>['rap', 'beat', 'lyrics', 'topline', 'mix']) {
      expect(offered, contains(needed),
          reason: 'somebody who does $needed cannot say so');
    }
  });

  test('what the app already stored is still offered', () {
    // These strings are in production data — in `plays` arrays and
    // `song_layers.part` rows already written. Dropping one would orphan
    // everybody who had ticked it.
    final offered = MusicalRole.offered.map((r) => r.value).toSet();
    for (final existing in <String>[
      'vocal', 'harmony', 'lead', 'rhythm', 'bass', 'drums', 'keys',
      'percussion',
    ]) {
      expect(offered, contains(existing),
          reason: '$existing is in the database and is no longer offered');
    }
  });

  test('"other" is never offered as a choice', () {
    // It is what an unrecognised value becomes, not something to tick.
    // "Something else" as a filter tells nobody anything and matches nothing.
    expect(MusicalRole.offered, isNot(contains(MusicalRole.other)));
    expect(MusicalRole.parse('a bridge'), MusicalRole.other);
    expect(MusicalRole.parse(null), MusicalRole.other);
  });

  test('every role has a label that is a person, not an instrument', () {
    for (final role in MusicalRole.offered) {
      expect(role.label.trim(), isNotEmpty, reason: '${role.value} has no label');
      // Somebody looking for help wants "a singer", not "vocal".
      expect(role.label, isNot(role.value),
          reason: '${role.value} is shown as its storage word');
    }
  });

  test('the ones that need explaining have it', () {
    // "Topline" means nothing to somebody who has never worked over a beat,
    // and that person is exactly who it is for.
    for (final role in <MusicalRole>[
      MusicalRole.topline,
      MusicalRole.beat,
      MusicalRole.lyrics,
      MusicalRole.mix,
    ]) {
      expect(role.note, isNotNull, reason: '${role.value} explains nothing');
    }
  });

  test('storage words never change once shipped', () {
    // The value is what is written to the database. A rename here silently
    // orphans every row that has the old one.
    expect(MusicalRole.vocal.value, 'vocal');
    expect(MusicalRole.rap.value, 'rap');
    expect(MusicalRole.beat.value, 'beat');
  });
}
