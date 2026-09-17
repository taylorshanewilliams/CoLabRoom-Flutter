import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether this device types on a keyboard.
///
/// Shared, because the rule is one rule: a key binding belongs on a desk and
/// a phone's own keyboard is left alone. Enter sends here, and N pins a note
/// at the playhead on the Takes screen (0141).
bool get typesOnAKeyboard =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
      _ => false,
    };

/// Enter sends, where there is a keyboard.
///
/// Every box for saying something in this app is several lines tall, so it
/// is a newline field, and a newline field never calls `onSubmitted`: on a
/// desk, Enter wrote a new line under the message and nothing was sent
/// (audit, 17 September 2026 -- Help, the threads, the song's side panel).
/// Shift+Enter still makes a new line. A phone's own keyboard is left alone,
/// where the return key writing a line is what people expect.
class SendOnEnter extends StatelessWidget {
  const SendOnEnter({required this.onSend, required this.child, this.onKeyboard, super.key});

  final VoidCallback onSend;
  final Widget child;

  /// Whether this device types on a keyboard. A test passes it.
  final bool? onKeyboard;

  @override
  Widget build(BuildContext context) {
    if (!(onKeyboard ?? typesOnAKeyboard)) return child;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): onSend,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onSend,
      },
      child: child,
    );
  }
}
