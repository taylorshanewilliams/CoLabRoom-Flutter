import 'package:flutter/material.dart';

/// How tall [lines] lines of [style] actually are, at the text size this
/// phone is set to.
///
/// For the one layout Flutter cannot size intrinsically: a list that runs
/// sideways. A horizontal ListView has to be given a height, and every one of
/// them in this app was given the height somebody measured on their own phone
/// — 74 for a face and a first name, 92 for a card with a title and a line
/// under it. Every Musician, Same Song, 17 September 2026: the phone's own
/// text size is honoured, never clamped, so those numbers are now wrong for
/// anybody who has turned their text up and the name under the face is cut
/// off.
///
/// Measured rather than guessed at with a line-height multiplier. The
/// multiplier is a property of the font, so a guess would be wrong the day
/// the theme changes family, and wrong silently — the kind of number nobody
/// re-derives.
///
/// Cheap: one layout of two glyphs, once per build of the strip.
double linesOfTextHigh(
  BuildContext context,
  TextStyle style, {
  int lines = 1,
}) {
  // Merged with the default the way Text merges it, or the answer is short
  // by whatever line height the theme sets and the row overflows by four
  // pixels at every text size — which is exactly what it did.
  final merged = style.inherit
      ? DefaultTextStyle.of(context).style.merge(style)
      : style;
  // "Ag" rather than the real words: an ascender and a descender, which is
  // what decides the line box, and no dependence on what anybody is called.
  final painter = TextPainter(
    text: TextSpan(text: 'Ag', style: merged),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height * lines;
}

/// How wide one line of [text] is in [style], at the text size this phone is
/// set to.
///
/// For deciding whether words still fit somewhere that cannot wrap — an app
/// bar is one row and Flutter will not fold it. Measuring beats a threshold
/// on the scale factor: "bigger than 1.3x" is a guess about a font, a phone
/// width and a word length all at once, and it is wrong for at least one of
/// them.
double textWidthOf(BuildContext context, String text, TextStyle style) {
  final merged = style.inherit
      ? DefaultTextStyle.of(context).style.merge(style)
      : style;
  final painter = TextPainter(
    text: TextSpan(text: text, style: merged),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// How much bigger this phone draws [fontSize] than the layout around it was
/// drawn for, never below 1.
///
/// Two jobs. The widths that have to grow with the text as well as the
/// heights do — a 58-pixel column under a face is enough for a first name at
/// 11px and enough for one letter and an ellipsis at 22px, and a row of faces
/// with nothing readable under them is not a row of people. And the handful of
/// headers that are laid out one way while the words fit beside each other and
/// another way when they do not; those switch at 1.5, so that a reader who
/// nudged their text size one step does not find the screen rearranged.
///
/// Never below 1 because a reader who has turned their text *down* has asked
/// for smaller text, not for a narrower app.
double textGrowth(BuildContext context, double fontSize) {
  final grown = MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
  return grown < 1 ? 1 : grown;
}
