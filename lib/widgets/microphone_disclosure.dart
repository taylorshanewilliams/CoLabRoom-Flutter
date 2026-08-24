import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Explains what the microphone is for before the operating system asks for it.
///
/// Both stores require this, and for the same reason: the OS prompt is one
/// line with a yes and a no in it, and it cannot say where the recording goes
/// afterwards. Google Play calls it a prominent disclosure and wants it before
/// the runtime request, not after; Apple wants the same thing in the usage
/// description. Somebody deciding whether to let an app hear them deserves to
/// know it leaves their phone before they decide, not once it already has.
///
/// Shown only when the permission is not already in hand, which is what the
/// policy asks for — a disclosure in front of every recording would be noise,
/// and noise is what people click through.
abstract final class MicrophoneAccess {
  /// Whether the last request came back granted.
  ///
  /// Not a substitute for asking the OS, which stays the authority. It only
  /// decides whether this disclosure has already done its job, so that
  /// revoking the permission in Settings brings the explanation back with the
  /// prompt rather than leaving the prompt to arrive on its own.
  static const String _grantedKey = 'microphone_granted';

  /// Runs the disclosure, then [request], and reports whether recording may
  /// begin. [purpose] completes the sentence "CoLabRoom needs the microphone
  /// …" and belongs to the caller, because recording a take and leaving a
  /// voice note on a line are different enough to be worth saying out loud.
  static Future<bool> ensureGranted(
    BuildContext context, {
    required String purpose,
    required Future<bool> Function() request,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyGranted = prefs.getBool(_grantedKey) ?? false;

    if (!alreadyGranted) {
      if (!context.mounted) return false;
      final agreed = await _disclose(context, purpose);
      // Declining is an answer, not an error. The OS prompt is never reached,
      // which is the whole point of asking first.
      if (agreed != true) return false;
    }

    final granted = await request();
    await prefs.setBool(_grantedKey, granted);
    return granted;
  }

  static Future<bool?> _disclose(BuildContext context, String purpose) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Before the microphone turns on'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('CoLabRoom needs the microphone $purpose.'),
            const SizedBox(height: 14),
            const _Point(
              icon: Icons.fiber_manual_record_rounded,
              text: 'It records only while you hold the app on a recording '
                  'screen and have started a take. Never in the background.',
            ),
            const _Point(
              icon: Icons.cloud_upload_rounded,
              text: 'What you record is uploaded to this song, so the people '
                  'in the room can hear it.',
            ),
            const _Point(
              icon: Icons.graphic_eq_rounded,
              text: 'If you analyse it, the audio is sent to our processing '
                  'service to work out key, tempo, chords and lyrics.',
            ),
            const _Point(
              icon: Icons.delete_outline_rounded,
              text: 'You can delete a recording at any time, and deleting it '
                  'removes the file too.',
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(icon, size: 14),
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ],
      ),
    );
  }
}
