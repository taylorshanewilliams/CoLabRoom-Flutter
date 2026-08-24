import 'package:colabroom/services/audio_analysis_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('requireAnalyzableDuration', () {
    test('lets a song through', () {
      expect(() => requireAnalyzableDuration(const Duration(minutes: 3, seconds: 57)),
          returnsNormally);
      expect(() => requireAnalyzableDuration(maxAnalyzableDuration), returnsNormally);
    });

    test('refuses an hour of rehearsal tape', () {
      expect(
        () => requireAnalyzableDuration(const Duration(minutes: 61)),
        throwsA(isA<StateError>()),
      );
    });

    test('says how long it is and what the limit is', () {
      // The message has to be actionable at the moment somebody picked the
      // wrong file — "too long" alone leaves them guessing by how much.
      try {
        requireAnalyzableDuration(const Duration(minutes: 47));
        fail('expected a rejection');
      } on StateError catch (error) {
        expect(error.message, contains('47'));
        expect(error.message, contains('${maxAnalyzableDuration.inMinutes}'));
      }
    });

    test('allows a length it could not read', () {
      // A decoder that can't report duration must not become a reason to
      // refuse a recording that would analyze perfectly well.
      expect(() => requireAnalyzableDuration(Duration.zero), returnsNormally);
      expect(() => requireAnalyzableDuration(const Duration(seconds: -1)), returnsNormally);
    });
  });
}
