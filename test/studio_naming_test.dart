import 'package:colabroom/services/studio_draft_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('looksAutoNamed', () {
    test('recognises the names capture apps generate', () {
      // The universal shape of an unusable idea library.
      for (final name in <String>[
        'Recording 8/23 11:40',
        'New Recording 12',
        'Voice Memo 47',
        'voice memo',
        'audio_2026_08_23',
        'Untitled',
        'Untitled 3',
        'Idea 4',
        'track 09.m4a',
        '   ',
      ]) {
        expect(looksAutoNamed(name), isTrue, reason: '"$name" should count as auto-named');
      }
    });

    test('leaves a name a musician actually chose alone', () {
      for (final name in <String>[
        'Long Lines',
        'Bridge idea for Mountains',
        'Chorus — faster',
        'Recording studio jam',
        'That riff Dave played',
        // Starts with a placeholder keyword but keeps going — real title.
        'Audiophile demo',
      ]) {
        expect(looksAutoNamed(name), isFalse, reason: '"$name" should be left alone');
      }
    });
  });

  group('nameFromTranscript', () {
    test('takes the opening words of what was sung', () {
      expect(
        nameFromTranscript('We wait in long lines nobody moves at all'),
        'We wait in long lines nobody',
      );
    });

    test('collapses whitespace', () {
      expect(nameFromTranscript('  We   wait\nin  long lines '), 'We wait in long lines');
    });

    test('does not end on punctuation', () {
      expect(nameFromTranscript('We wait, and wait,'), 'We wait, and wait');
    });

    test('returns null when there is nothing worth naming from', () {
      expect(nameFromTranscript(null), isNull);
      expect(nameFromTranscript(''), isNull);
      expect(nameFromTranscript('  '), isNull);
      expect(nameFromTranscript('ah'), isNull);
    });

    test('stays short enough to read in a list', () {
      final name = nameFromTranscript(
        'supercalifragilistic expialidocious extraordinarily lengthy opening phrase here',
      );
      expect(name!.length, lessThanOrEqualTo(48));
    });
  });
}
