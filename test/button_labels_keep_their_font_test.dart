import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Button labels keep the font the theme handed them.
///
/// `ButtonStyleButton` resolves the style for its label as
/// `widgetStyle?.textStyle ?? themeStyle?.textStyle ?? defaultStyle.textStyle`
/// — a `??`, not a merge. So a `TextStyle` passed to `styleFrom(textStyle:)`
/// *replaces* the resolved style outright rather than adding to it, and takes
/// the font family away with it. The same style put on the label's own `Text`
/// merges into the style it inherits, which is what every one of these call
/// sites actually meant: a size and a weight, not a whole new font.
///
/// On a phone this hides. `CoLabRoomTheme.dark()` sets no `fontFamily`, so the
/// family being discarded is null anyway and the label lands on the platform
/// font looking exactly right. It stops hiding in two places — the day the
/// theme adopts a family, and every time the app is drawn under `test_render/`,
/// where these labels came out as rows of filled blocks because the font they
/// asked for was nobody in particular.
///
/// **Asserted against the source, deliberately.** Fifteen files had this at
/// once. Every one of them built, passed its widget tests and looked correct
/// on a device, because at runtime nothing was wrong yet — the bug is that the
/// call sites are holding a loaded gun that the theme has not yet pointed
/// anywhere. There is no widget assertion that catches a font family which is
/// null on both sides. Reading the file is cruder and actually checks it.
void main() {
  test('no button hands a textStyle to styleFrom', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = _withoutLineComments(entity.readAsStringSync());
      final count = _styleFromArguments(source)
          .where((String args) => args.contains('textStyle:'))
          .length;
      if (count > 0) {
        final path = entity.path.replaceAll(r'\', '/');
        offenders.add('$path ($count)');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These pass a textStyle to styleFrom, which replaces the '
          'button label style rather than merging into it and drops the font '
          'family. Move the size and weight onto the label Text instead — or '
          'onto a DefaultTextStyle, where the child is not a plain Text:\n  '
          '${offenders.join('\n  ')}',
    );
  });
}

/// The argument text of every `styleFrom(...)` call in [source].
///
/// Parenthesis matching, skipping over string literals so that a bracket
/// inside a label does not end the call early.
Iterable<String> _styleFromArguments(String source) sync* {
  const needle = 'styleFrom(';
  var at = source.indexOf(needle);
  while (at != -1) {
    final open = at + needle.length;
    var depth = 1;
    var i = open;
    String? quote;
    while (i < source.length && depth > 0) {
      final ch = source[i];
      if (quote != null) {
        if (ch == r'\') {
          i += 2;
          continue;
        }
        if (ch == quote) quote = null;
      } else if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '(') {
        depth += 1;
      } else if (ch == ')') {
        depth -= 1;
      }
      i += 1;
    }
    yield source.substring(open, i);
    at = source.indexOf(needle, i);
  }
}

/// [source] with `//` comments removed.
///
/// Needed because two files explain this rule in prose and quote
/// `styleFrom(textStyle:)` while doing it. A comment that describes the
/// mistake should not read as the mistake.
String _withoutLineComments(String source) {
  final out = StringBuffer();
  for (final line in const LineSplitter().convert(source)) {
    out.writeln(_stripLineComment(line));
  }
  return out.toString();
}

String _stripLineComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i += 1) {
    final ch = line[i];
    if (quote != null) {
      if (ch == r'\') {
        i += 1;
        continue;
      }
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      continue;
    }
    // Not a comment when it is a URL sitting in a string; the quote tracking
    // above has already ruled that out by the time we get here.
    if (ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}
