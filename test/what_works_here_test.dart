import 'package:colabroom/services/what_works_here.dart';
import 'package:flutter_test/flutter_test.dart';

/// What would work here.
///
/// Taylor: "what if someone is stuck, and wants to know quickly, what cords
/// would go with this progression, what key or box would a lead work in. what
/// notes would harmony be... a help feature for any instrument or user."
///
/// The arithmetic already existed. `music_reference.dart` derives the scale,
/// the degrees, the diatonic chords and the pentatonic from a key, and
/// `chordReference` derives tones, shapes and root patterns from a chord.
/// What neither had was the song: tapping a chord told you what a C is, not
/// that it is the IV here, and not what this song has not used yet.
///
/// Deterministic on purpose. Given a key and a chord, "what else fits" has
/// exactly one right answer, and a language model would be a worse version of
/// arithmetic — right most of the time and confidently wrong occasionally.
/// Being wrong about a chord in front of a guitarist ends the feature in one
/// screen.
void main() {
  test('a chord knows where it sits in the song', () {
    final answer = whatWorksHere(chordLabel: 'C', keyLabel: 'G major');
    expect(answer, isNotNull);
    expect(answer!.degree, 'IV',
        reason: 'C is the fourth of G, and saying so is the orientation the '
            'old sheet could not give');
  });

  test('a borrowed chord is not given a number it does not have', () {
    // Playing something from outside the key is a thing musicians do on
    // purpose. Telling somebody it is the iii when it is not is worse than
    // saying nothing.
    final answer = whatWorksHere(chordLabel: 'Eb', keyLabel: 'G major');
    expect(answer!.degree, isNull);
  });

  test('spelling does not decide whether a chord is in the key', () {
    // A chart that says A# against a key that says Bb is the same chord.
    final sharp = whatWorksHere(chordLabel: 'A#', keyLabel: 'F major');
    final flat = whatWorksHere(chordLabel: 'Bb', keyLabel: 'F major');
    expect(sharp!.degree, flat!.degree);
    expect(flat.degree, 'IV');
  });

  test('it says what this song has not used, not what music contains', () {
    // The single most useful thing here. Seven diatonic chords is a list
    // anybody can look up; "your song uses three and here are the others" is
    // about their song.
    final answer = whatWorksHere(
      chordLabel: 'G',
      keyLabel: 'G major',
      used: <String>['G', 'C', 'D'],
    );
    final untouched =
        answer!.suggestions.firstWhere((s) => s.heading == 'Not in the song yet');

    expect(untouched.chords, contains('Em'));
    expect(untouched.chords, isNot(contains('G')));
    expect(untouched.chords, isNot(contains('C')));
    expect(untouched.chords, isNot(contains('D')));
  });

  test('a song using everything is not told to try what it already has', () {
    final answer = whatWorksHere(
      chordLabel: 'G',
      keyLabel: 'G major',
      used: <String>['G', 'Am', 'Bm', 'C', 'D', 'Em', 'F#dim'],
    );
    expect(
      answer!.suggestions.where((s) => s.heading == 'Not in the song yet'),
      isEmpty,
    );
  });

  test('the V is told where it wants to land', () {
    final answer = whatWorksHere(chordLabel: 'D', keyLabel: 'G major');
    final wants =
        answer!.suggestions.firstWhere((s) => s.heading == 'It wants to land');
    expect(wants.chords.first, 'G');
  });

  test('harmony is offered from the chord, and says so', () {
    // The app has lyrics with timing and chords with timing, and no pitch
    // line at all. A third above inside the chord is a real backing vocal; it
    // is not harmonising the tune somebody actually sang, and the difference
    // has to be on the screen.
    final answer = whatWorksHere(chordLabel: 'C', keyLabel: 'C major');
    final sing = answer!.suggestions
        .firstWhere((s) => s.heading == 'To sing against it');
    expect(sing.notes, containsAll(<String>['C', 'E', 'G']));
    expect(sing.detail.toLowerCase(), contains('not from the tune'));
  });

  test('what you play changes the order and hides nothing', () {
    final singer = whatWorksHere(
      chordLabel: 'C',
      keyLabel: 'C major',
      roles: <String>{'vocal'},
    );
    expect(singer!.suggestions.first.heading, 'To sing against it');

    final bassist = whatWorksHere(
      chordLabel: 'C',
      keyLabel: 'C major',
      roles: <String>{'bass'},
    );
    expect(bassist!.suggestions.first.heading, 'Under it');

    // Nobody is prevented from seeing the rest. People play more than one
    // thing, and a bass player asking about harmony is a bass player
    // arranging a backing vocal.
    expect(bassist.suggestions.length, singer.suggestions.length);
  });

  test('a song with no key still answers the questions it can', () {
    // Key detection fails on plenty of real recordings. What sits over this
    // chord is still true.
    final answer = whatWorksHere(chordLabel: 'Am');
    expect(answer, isNotNull);
    expect(answer!.degree, isNull);
    expect(
      answer.suggestions.any((s) => s.heading == 'To play over it'),
      isTrue,
    );
  });

  test('a chord nobody can parse gets no answer rather than a wrong one', () {
    expect(whatWorksHere(chordLabel: 'N.C.'), isNull);
  });
}
