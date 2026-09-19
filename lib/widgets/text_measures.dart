import 'dart:math' as math;

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
///
/// [scaler] is for the one caller that has to ask about a text size other
/// than the one this phone is set to: [appBarHighEnoughFor], because Flutter
/// draws an app bar's title at a scale of its own.
double linesOfTextHigh(
  BuildContext context,
  TextStyle style, {
  int lines = 1,
  TextScaler? scaler,
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
    textScaler: scaler ?? MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height * lines;
}

/// The most an [AppBar] will ever grow its own title by, however large the
/// reader has set their text.
///
/// Flutter's, not ours: `_kMaxTitleTextScaleFactor` in the framework's
/// app_bar.dart, which wraps every title in a clamped `MediaQuery` so that a
/// large text size does not turn the top of the screen into the whole of it.
/// Copied here because it is private there, and because measuring the title
/// at the reader's full scale instead would hand a bar forty pixels of empty
/// air at the accessibility sizes. Actions are not clamped, which is why a
/// labelled one is the part that loses its bottom.
const double _appBarClampsItsTitleAt = 1.34;

/// How tall an app bar has to be to hold what is in it, at the text size this
/// phone is set to — never less than Material's 56.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. A bar does not push back when the words in it
/// outgrow it: [AppBar] hands its title and its actions the toolbar height it
/// was given and draws whatever fits, so a labelled action loses the bottom of
/// its letters and a two-line title spills past the edge of the bar — both
/// silently, which is how this survived every test and the render harness.
/// So the height is measured from the styles the bar actually draws.
///
/// [title] is the styles of the lines stacked in the title, top to bottom, and
/// [actions] the styles of any labelled actions — an icon-only action is 48
/// square and needs nothing. Each is given as the caller writes it in the bar;
/// what the bar falls back to underneath is filled in here, because a line
/// height taken from whatever body style the screen happens to sit in is a
/// different number from the one the words are drawn at. 56 is the floor, so
/// nothing moves for a reader who has not turned their text up.
double appBarHighEnoughFor(
  BuildContext context, {
  List<TextStyle> title = const <TextStyle>[],
  List<TextStyle> actions = const <TextStyle>[],
}) {
  final scaler = MediaQuery.textScalerOf(context);
  final titleScaler = scaler.clamp(maxScaleFactor: _appBarClampsItsTitleAt);
  var high = kToolbarHeight;
  if (title.isNotEmpty) {
    final beneath = appBarTitleStyle(context);
    var stacked = 0.0;
    for (final style in title) {
      stacked +=
          linesOfTextHigh(context, beneath.merge(style), scaler: titleScaler);
    }
    // The 8 and the 16 are the air the Takes bar has kept since it was the
    // only bar that measured itself: enough that the words are not flush
    // against the edges of the bar they sit in.
    high = math.max(high, stacked + 8);
  }
  if (actions.isNotEmpty) {
    // An action is a button label, drawn in labelLarge unless it says
    // otherwise.
    final beneath = Theme.of(context).textTheme.labelLarge ??
        const TextStyle(fontSize: 14);
    for (final style in actions) {
      high = math.max(
        high,
        linesOfTextHigh(context, beneath.merge(style), scaler: scaler) + 16,
      );
    }
  }
  return high;
}

/// The style an [AppBar] draws its title in on this theme.
///
/// The fallbacks live inside [AppBar] where nothing can see them, and two
/// things need the answer: how tall the title is, and how wide, which decides
/// whether a bar's actions still fit beside it as words.
TextStyle appBarTitleStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.appBarTheme.titleTextStyle ??
      theme.textTheme.titleLarge ??
      const TextStyle(fontSize: 22);
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
