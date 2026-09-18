import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

/// The small phone beside the title of a song that is kept on this phone.
///
/// The plain state, where the song is named rather than inside a menu: on
/// the song's own header, on a set's rows and in the Songs list, so that
/// checking a dozen songs before leaving for a basement is a glance down a
/// list and not a dozen menus opened one by one (review, 18 September 2026).
/// The same icon the menu entry and the offline list already use. No words
/// beside it and no count of anything; held down, or read aloud, it says
/// "On this phone".
class OnThisPhoneMark extends StatelessWidget {
  const OnThisPhoneMark({this.size = 15, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'On this phone',
      // The icon's own label says it; twice is once too many.
      excludeFromSemantics: true,
      child: Icon(
        Icons.phone_android_rounded,
        size: size,
        color: AppColors.muted,
        semanticLabel: 'On this phone',
      ),
    );
  }
}
