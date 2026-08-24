import 'dart:typed_data';

import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bug report that says "the chord line is wrong" is a guess; one with a
/// picture of the actual screen is a fact. This covers the one thing that
/// changed: a screenshot, if attached, has to actually reach the repository
/// alongside the rest of the report rather than being silently dropped.
void main() {
  group('a feedback screenshot', () {
    test('is optional and defaults to nothing', () {
      const draft = FeedbackDraft(
        category: 'general',
        message: 'The chord line looks wrong on this song.',
        route: 'account',
        platform: 'android',
        appVersion: '0.4.0',
      );
      expect(draft.screenshot, isNull);
    });

    test('travels with the rest of the report when attached', () async {
      final repository = InMemoryMusicRepository.seeded();
      final picture = Uint8List.fromList(<int>[137, 80, 78, 71]);

      await repository.submitFeedback(FeedbackDraft(
        category: 'general',
        message: 'Here is what I saw.',
        route: 'account',
        platform: 'android',
        appVersion: '0.4.0',
        screenshot: picture,
      ));

      expect(repository.submittedFeedback, hasLength(1));
      expect(repository.submittedFeedback.single.screenshot, same(picture));
    });

    test('an empty report has nothing to attach to', () async {
      final repository = InMemoryMusicRepository.seeded();

      await repository.submitFeedback(const FeedbackDraft(
        category: 'general',
        message: 'No picture for this one.',
        route: 'account',
        platform: 'ios',
        appVersion: '0.4.0',
      ));

      expect(repository.submittedFeedback.single.screenshot, isNull);
    });
  });
}
