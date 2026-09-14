import 'package:colabroom/services/idea_naming.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rename studio_drafts used to do, restored. A recording called
/// "Idea 09/14 02:07:33" becomes the first words it sang the moment the sheet
/// lands; a title somebody typed is never touched.
void main() {
  group('betterNameFor', () {
    test('renames a dated placeholder from what was sung', () {
      expect(
        betterNameFor(
          current: 'Idea 09/14 02:07:33',
          transcript: 'took time to understand I\'m not the one who left',
        ),
        isNotNull,
      );
      expect(
        betterNameFor(
          current: 'Idea 09/14 02:07:33',
          transcript: 'took time to understand I\'m not the one who left',
        )!
            .toLowerCase(),
        startsWith('took time'),
      );
    });

    test('the collision suffix is still a placeholder', () {
      // startIdea appends the millisecond when two ideas land in one second.
      expect(looksAutoNamed('Idea 09/14 02:07:33 481'), isTrue);
      expect(
        betterNameFor(current: 'Idea 09/14 02:07:33 481', transcript: 'weathervane on the roof'),
        isNotNull,
      );
    });

    test('never replaces a real title', () {
      expect(
        betterNameFor(current: 'Weathervane', transcript: 'took time to understand'),
        isNull,
      );
    });

    test('leaves the placeholder when nothing usable was sung', () {
      expect(betterNameFor(current: 'Idea 09/14 02:07:33', transcript: null), isNull);
      expect(betterNameFor(current: 'Idea 09/14 02:07:33', transcript: ''), isNull);
      expect(betterNameFor(current: 'Idea 09/14 02:07:33', transcript: 'la'), isNull);
    });
  });
}
