import 'package:colabroom/services/arrival_code.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// An invitation that opens.
///
/// The code becomes a link into the web app, and the web app reads it back
/// off the address. Nothing else on the address is trusted.
void main() {
  test('a code becomes a link that opens the web app and says where it came from', () {
    final link = inviteLink(' AB12-CD34 ');
    expect(link, 'https://app.colabroom.com/invite/AB12-CD34');
    expect(inviteCodeFrom(Uri.parse(link)), 'AB12-CD34');
    expect(arrivalCodeFrom(Uri.parse(link)), 'invite');
  });

  test('a link sent before the code moved into the path still opens', () {
    final old = Uri.parse('https://app.colabroom.com/?invite=AB12-CD34&from=invite');
    expect(inviteCodeFrom(old), 'AB12-CD34');
    expect(arrivalCodeFrom(old), 'invite');
  });

  test('anything but a plain code is ignored', () {
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/')), isNull);
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/?invite=')), isNull);
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/?invite=a%20b')), isNull);
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/?invite=<x>')), isNull);
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/?invite=abc')), isNull,
        reason: 'shorter than any code the server makes');
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/invite/')), isNull);
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/invite/AB12-CD34/more')), isNull);
    expect(inviteCodeFrom(Uri.parse('https://app.colabroom.com/song/AB12-CD34')), isNull);
  });
}
