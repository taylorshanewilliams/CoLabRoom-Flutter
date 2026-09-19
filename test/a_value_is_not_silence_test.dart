import 'package:colabroom/app/colabroom_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_render/rules.dart';

/// What the report is allowed to call silent.
///
/// `auditLabels` prints "announces nothing" about a control, and that sentence
/// has to be true or the report stops being read. It was checking the label
/// and the tooltip only, while the rule beside it — the one that judges a
/// painting — counted the value and the hint as well. So a tuner announced as
/// "82 beats per minute" and a field announced as the words typed into it
/// were both reported as saying nothing, and the two rules in the same report
/// disagreed with each other. #403 wrote that down as debt; this is it paid.
///
/// WCAG 2.2 SC 4.1.2 still wants a name as well as a value, which is why the
/// lyric editor now has one. That is a different sentence from this one, and
/// this rule prints this one.
Future<void> _pumpControl(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(body: Center(child: child)),
  ));
}

void main() {
  testWidgets('a control that announces a value is not silent', (tester) async {
    await _pumpControl(
      tester,
      Semantics(
        value: '82 beats per minute',
        child: GestureDetector(
          onTap: () {},
          child: const SizedBox(width: 48, height: 48),
        ),
      ),
    );
    expect(auditLabels(tester), isEmpty);
  });

  testWidgets('a control whose only words are a hint is not silent',
      (tester) async {
    await _pumpControl(
      tester,
      Semantics(
        hint: 'Plays from here',
        child: GestureDetector(
          onTap: () {},
          child: const SizedBox(width: 48, height: 48),
        ),
      ),
    );
    expect(auditLabels(tester), isEmpty);
  });

  testWidgets('a text field holding words is not called silent',
      (tester) async {
    // The lyric editor's shape before it was named: a tappable node with the
    // text as its value and nothing else. It is still worth naming — and is
    // named now — but "announces nothing" was never a true description of it.
    final words = TextEditingController(text: 'Verse one, first line');
    addTearDown(words.dispose);
    await _pumpControl(tester, TextField(controller: words));
    expect(auditLabels(tester), isEmpty);
  });

  testWidgets('a control that says nothing at all still is', (tester) async {
    // The gate itself. Loosening what counts as speech is only safe if the
    // rule still catches the thing it was written for.
    await _pumpControl(
      tester,
      GestureDetector(
        onTap: () {},
        child: const SizedBox(width: 48, height: 48),
      ),
    );

    final found = auditLabels(tester);
    expect(found, hasLength(1));
    expect(found.single.rule, 'Unnamed control');
    expect(found.single.detail, contains('announces nothing'));
  });
}
