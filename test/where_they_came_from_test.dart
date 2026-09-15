import 'package:colabroom/services/arrival_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where they came from.
///
/// A flier carries a code, the address carries it on, and an account claims
/// it once. The address bar is not a place to be strict, so the rule here
/// is: a plain code or nothing.
void main() {
  test('a plain code on the address is kept, lower-cased', () {
    expect(arrivalCodeFrom(Uri.parse('https://app.colabroom.com/?from=ORL-WP')), 'orl-wp');
    expect(arrivalCodeFrom(Uri.parse('https://colabroom.com/chords.html?c=orl-wp')), 'orl-wp');
  });

  test('anything but a plain code is ignored', () {
    expect(arrivalCodeFrom(Uri.parse('https://app.colabroom.com/')), isNull);
    expect(arrivalCodeFrom(Uri.parse('https://app.colabroom.com/?from=')), isNull);
    expect(arrivalCodeFrom(Uri.parse('https://app.colabroom.com/?from=hello%20world')), isNull);
    expect(arrivalCodeFrom(Uri.parse('https://app.colabroom.com/?from=<script>')), isNull);
    expect(arrivalCodeFrom(Uri.parse('https://app.colabroom.com/?from=${'a' * 33}')), isNull);
  });

  test('from wins over c when both are present', () {
    expect(arrivalCodeFrom(Uri.parse('https://x/?c=board&from=video')), 'video');
  });
}
