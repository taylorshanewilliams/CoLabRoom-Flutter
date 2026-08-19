import 'package:colabroom/domain/name_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NamePolicy', () {
    test('preserves capitalization while cleaning whitespace', () {
      expect(NamePolicy.clean('  After   Hours STUDIO  '), 'After Hours STUDIO');
    });

    test('compares names without case or repeated whitespace', () {
      expect(NamePolicy.same('After Hours', ' after   hours '), isTrue);
    });

    test('rejects empty names', () {
      expect(
        () => NamePolicy.requireUsable('   ', label: 'Room name'),
        throwsA(isA<NameConflict>()),
      );
    });
  });
}
