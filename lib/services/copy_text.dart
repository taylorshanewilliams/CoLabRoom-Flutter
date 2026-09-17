import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copying, and knowing whether it worked.
///
/// A browser can refuse the clipboard: inside another app's browser, in a
/// frame, without a fresh tap. `Clipboard.setData` then throws, and every
/// copy button in the app did nothing at all -- no copy, no message, only an
/// uncaught error (audit, 17 September 2026, on Your code).
Future<bool> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}

/// Copies [text] and says [copied], or, when the clipboard says no, shows the
/// text to copy by hand.
Future<void> copyAndSay(BuildContext context, String text, String copied) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (await copyText(text)) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(copied)));
    return;
  }
  if (!context.mounted) return;
  await showCopyByHand(context, text);
}

/// The words, selectable, for when copying them was not allowed.
Future<void> showCopyByHand(BuildContext context, String text) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Copy it by hand'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('This browser would not let CoLabRoom copy. Select it and copy it yourself:'),
          const SizedBox(height: 12),
          SelectableText(text, key: const Key('copy_by_hand_text')),
        ],
      ),
      actions: <Widget>[
        FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done')),
      ],
    ),
  );
}
