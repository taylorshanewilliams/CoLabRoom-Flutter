import 'package:colabroom/services/clock_skew.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// "JWT issued at future" is a question about clocks, and the app used to
/// answer it by blaming the phone. Then it happened on an emulator whose
/// clock was eight seconds behind. Now the app measures which clock, says
/// so without swearing, and tries again first.
void main() {
  group('reading the server\'s clock', () {
    test('an HTTP date is read exactly', () {
      final when = ClockSkew.parseHttpDate('Sun, 14 Sep 2026 19:13:53 GMT');
      expect(when, DateTime.utc(2026, 9, 14, 19, 13, 53));
      expect(ClockSkew.parseHttpDate('yesterday'), isNull);
      expect(ClockSkew.parseHttpDate('Sun, 14 Xyz 2026 19:13:53 GMT'), isNull);
    });

    test('the skew is the phone minus the server, and says which is ahead', () async {
      final phone = DateTime.utc(2026, 9, 14, 19, 14, 0);
      final ahead = await ClockSkew.measure(
        server: () async => phone.subtract(const Duration(seconds: 30)),
        now: () => phone,
      );
      expect(ahead, const Duration(seconds: 30));
      expect(ClockSkew.describe(ahead!), contains('30 s ahead of'));

      final behind = await ClockSkew.measure(
        server: () async => phone.add(const Duration(seconds: 8)),
        now: () => phone,
      );
      expect(behind, const Duration(seconds: -8));
      expect(ClockSkew.describe(behind!), contains('8 s behind'));

      expect(ClockSkew.describe(Duration.zero), contains('agrees'));
      expect(await ClockSkew.measure(server: () async => null), isNull);
    });
  });

  test('the sentence no longer swears it is the phone', () {
    final sentence = describeForUser(
      PostgrestException(message: 'JWT issued at future', code: 'PGRST303'),
    );
    expect(sentence, contains('from the future'));
    expect(sentence, contains('automatic date and time'));
    expect(sentence, contains('on our side'));
    expect(sentence, isNot(contains('PGRST')));
  });
}
