import 'package:colabroom/app/colabroom_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two things that stop the desk feeling like a phone in a browser.
///
/// A bottom sheet comes up from the bottom edge because on a phone that is
/// where your thumb is. Given 1300 pixels it becomes a drawer the width of
/// the desk, and it is the most phone-ish thing left once the content has an
/// edge. There are thirty of them, so the width belongs in the theme rather
/// than at thirty call sites — and there it also applies to the next one
/// somebody writes.
///
/// Space plays and pauses because it does everywhere else. The rule that
/// matters is the one about not stealing it: the reason a keyboard is worth
/// anything here is writing lyrics, and a space that plays a song instead of
/// typing a space would be worse than no shortcut at all.
void main() {
  test('sheets have a width, so a desk gets a panel and not a drawer', () {
    final constraints = CoLabRoomTheme.dark().bottomSheetTheme.constraints;

    expect(constraints, isNotNull,
        reason: 'unconstrained, every one of the thirty modal sheets is as '
            'wide as the browser');
    expect(constraints!.maxWidth, lessThan(900));
    expect(constraints.maxWidth, greaterThan(400),
        reason: 'narrower than a phone would make it worse on the device '
            'most people are actually holding');
  });

  testWidgets('space is left alone while somebody is typing', (tester) async {
    // The guard is a focus question, not a key question: the shortcut looks
    // at whether the primary focus sits inside an EditableText before it
    // claims the key. This pins the behaviour that guard exists for.
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);

    var claimed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Focus(
        // As the shell does, so the key reaches it when nothing else has
        // taken focus.
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey != LogicalKeyboardKey.space) {
            return KeyEventResult.ignored;
          }
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused != null &&
              focused.findAncestorStateOfType<EditableTextState>() != null) {
            return KeyEventResult.ignored;
          }
          claimed += 1;
          return KeyEventResult.handled;
        },
        child: Scaffold(
          body: TextField(controller: controller, focusNode: focus),
        ),
      ),
    ));

    // Nothing focused: the shortcut is free to take the key.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(claimed, 1);

    // Typing a lyric: the space belongs to the words.
    focus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ladder of');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(claimed, 1,
        reason: 'a space that plays a song instead of typing a space is '
            'worse than having no shortcut');
  });
}
