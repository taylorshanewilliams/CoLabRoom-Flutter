import 'package:colabroom/features/help/help_answers.dart';
import 'package:flutter_test/flutter_test.dart';

/// Does the help answer the question that was asked?
///
/// The failure that matters here is not silence. It is answering the wrong
/// question confidently — telling somebody how to delete their account when
/// they asked how to delete a take, or inventing a refund policy for an app
/// with nothing to pay for. A shrug and a route to a person costs almost
/// nothing; a wrong answer costs trust and a support message anyway.
///
/// So these assert both halves: the questions people actually type reach the
/// right card, and questions this app has no answer for return null rather
/// than the nearest thing.
void main() {
  group('it finds the right answer', () {
    const cases = <String, String>{
      'how do i add another take': 'take',
      'how do i overdub': 'take',
      'how do i see the chords for my song': 'sheet',
      'where are the lyrics and chords': 'sheet',
      'who can hear my songs': 'audience',
      'is my music private': 'audience',
      'how do i put a song on the open mic': 'openmic',
      'how do i take my song off the open mic': 'takedown',
      'how do i find a bass player': 'ask',
      'how do i invite my bandmate to a room': 'invite-room',
      'how do i remove someone from my band': 'remove-member',
      'what does sounds like mean': 'sounds-like',
      'how do i make a setlist for a gig': 'sets',
      'i cannot find my song': 'missing-song',
      'someone posted something offensive': 'report',
      'how do i get a refund': 'refund',
      'what does this cost': 'refund',
      'how do i delete my account': 'delete-account',
      'what is a demo account': 'demo',
      // Added after the audit of 17 September 2026, which asked "how do I
      // start a video call" and was told how to record.
      'how do i start a video call': 'calls',
      'can we rehearse on a call': 'calls',
      'how do i add someone i met at a gig': 'your-code',
      'scan a qr code': 'your-code',
      'where do i paste an invitation link': 'join-code',
      'how do i teach a lesson': 'lessons',
      'how do my students follow along': 'follow',
      'where is my homework from my teacher': 'practise',
      'why is my guitar out of tune': 'tuner',
      'is there a metronome': 'tuner',
      'how do i mute notifications': 'notifications',
      'can i use this on my laptop': 'web',
    };

    cases.forEach((typed, expected) {
      test('"$typed" → $expected', () {
        final found = bestHelpAnswer(typed);
        expect(found, isNotNull, reason: 'nothing matched "$typed"');
        expect(found!.id, expected,
            reason: '"$typed" answered with "${found.question}"');
      });
    });
  });

  group('it admits when it does not know', () {
    const unanswerable = <String>[
      // Real questions this app genuinely cannot answer, and must not
      // pretend to. Each one is close enough to a real card to be tempting.
      'why does my amp hum',
      'can you write me a chorus',
      'what time is the show',
      'asdfghjkl',
    ];

    for (final typed in unanswerable) {
      test('"$typed" is not answered', () {
        final found = bestHelpAnswer(typed);
        expect(
          found,
          isNull,
          reason: 'answered "$typed" with "${found?.question}", which is worse '
              'than saying it does not know',
        );
      });
    }

    test('an empty question is not answered', () {
      expect(bestHelpAnswer(''), isNull);
      expect(bestHelpAnswer('   '), isNull);
      // Only the words every question contains, so nothing is left to match.
      expect(bestHelpAnswer('how do i'), isNull);
    });
  });

  group('the written answers hold together', () {
    test('every id is unique', () {
      final ids = helpAnswers.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'two answers share an id');
    });

    test('every answer has keywords to be found by', () {
      for (final answer in helpAnswers) {
        expect(answer.keywords, isNotEmpty,
            reason: '${answer.id} can never be matched');
        expect(answer.answer.trim(), isNotEmpty, reason: '${answer.id} is blank');
        expect(answer.question.trim(), isNotEmpty,
            reason: '${answer.id} has no question');
      }
    });

    test('the refund answer says there is nothing to refund', () {
      // The one answer where being wrong is a promise the app cannot keep.
      // There is no billing anywhere in this codebase; if that changes, this
      // test should fail and force the answer to change with it.
      final refund = helpAnswers.firstWhere((a) => a.id == 'refund');
      expect(refund.answer.toLowerCase(), contains('no paid tier'));
      expect(refund.answer, contains('support@colabroom.com'));
    });

    test('browsing without typing returns everything', () {
      expect(helpAnswersFor('').length, helpAnswers.length);
    });

    test('typing narrows the list rather than emptying it', () {
      final narrowed = helpAnswersFor('open mic');
      expect(narrowed, isNotEmpty);
      expect(narrowed.length, lessThan(helpAnswers.length));
      expect(narrowed.first.id, anyOf('openmic', 'takedown'));
    });
  });
}
