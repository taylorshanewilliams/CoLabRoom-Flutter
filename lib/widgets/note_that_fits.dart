import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A sentence in a snackbar, at a size that still lands on the screen.
///
/// A snackbar is as tall as its words. At the largest iOS accessibility text
/// size — 3.12x, which is a real phone somebody is holding — "The recording
/// could not be loaded. The words are here; the song is not." measures 744
/// logical pixels on a 390-wide phone, and a floating snackbar is positioned
/// upwards from whichever is higher of the record button and the tab bar. The
/// arithmetic runs out: Flutter positions the box above the top of the screen
/// and throws "Floating SnackBar presented off screen" while it lays out. In a
/// release build there is no assertion to throw, so what actually happens is
/// worse — the sentence is drawn where nobody can see it, and the one person
/// who most needs to be told why the song is silent is the one person who is
/// never told.
///
/// The text size is the reader's and is not touched (Every Musician, Same
/// Song, 17 September 2026: the phone's own text size is honoured, never
/// clamped). What is bounded is the box: it takes at most what is left of the
/// screen once the shell's furniture has had its share, and scrolls inside
/// that, so the words are all still there at the size that was asked for and
/// the snackbar is somewhere they can be read.
class NoteThatFits extends StatelessWidget {
  const NoteThatFits(this.note, {super.key});

  /// What the app is saying. One sentence or two, in the app's own voice.
  final String note;

  /// How much of the screen a passing sentence may cover, at most.
  ///
  /// This is not what keeps the note on the screen — [_everythingElse] is.
  /// It is the other question, which is how much of somebody's screen a
  /// message they did not ask for should ever take.
  static const double _share = 0.45;

  /// Everything on the screen that is not the sentence, at ordinary text size.
  ///
  /// This was a second fraction of the screen's height, and a fraction is the
  /// wrong shape for it. What a floating snackbar has to fit into is the
  /// screen *minus the shell's bottom furniture*, and that furniture is the
  /// same height on a short phone as on a tall one — so a fraction is far too
  /// generous exactly where there is least room, and a 375x667 phone at 3.12x
  /// with something playing was still drawing the note off the top.
  ///
  /// Measured on the real shell at 1.0x: 144 logical pixels for the record
  /// button and the tab bar, 66 more for the now-playing bar when something
  /// is playing, and 43 for the snackbar's own padding above and below the
  /// words. 265 is those three with a small cushion, and the room left for
  /// the now-playing bar is reserved whether it is up or not, because what is
  /// playing is not something a snackbar can ask.
  static const double _everythingElse = 265;

  /// How much more of the screen that furniture takes above ordinary size.
  ///
  /// It grows with the reader's text and not with the phone: at 3.12x the tab
  /// bar's three labels wrap onto their own lines, and the now-playing bar is
  /// carrying a title and a byline at 3.12x too, so on the narrowest phone
  /// the same furniture measures 517 rather than 253. A straight line through
  /// those two ends sits above every measurement in between, because the
  /// furniture grows faster the larger the text gets: 265 + 140 x 2.12 = 562,
  /// against a worst measured 517.
  ///
  /// Those are measured where they can be re-measured, in a widget test,
  /// whose placeholder face draws the tab bar's labels a good deal taller
  /// than a phone's own does — so on a phone this is generous rather than
  /// tight, which is the direction to be wrong in.
  /// `test/every_note_lands_on_the_screen_test.dart` takes them again on the
  /// real shell at every phone size the app is drawn for.
  static const double _everythingElsePerExtraScale = 140;

  /// The size [_everythingElse] and its slope are expressed against.
  ///
  /// A [TextScaler] is a curve rather than a number, so the number is read
  /// back off it at body size, which is roughly the size the furniture's own
  /// text is set at and so the growth this is tracking.
  static const double _bodySize = 14;

  /// A line of the reader's own text, near enough.
  static const double _lineFactor = 1.4;

  @override
  Widget build(BuildContext context) {
    final double screen = MediaQuery.sizeOf(context).height;
    final double atBodySize = MediaQuery.textScalerOf(context).scale(_bodySize);
    final double scale = atBodySize / _bodySize;
    final double taken =
        _everythingElse + _everythingElsePerExtraScale * math.max(0, scale - 1);
    // Never less than one line of the reader's own text. The allowance above
    // is deliberately generous, and on a phone held sideways at a large text
    // size it can ask for more room than the phone has; a box with nothing in
    // it would land on the screen and still tell nobody anything, which is
    // the bug this whole file is about wearing different clothes.
    final double ceiling = math.max(
      atBodySize * _lineFactor,
      math.min(screen * _share, screen - taken),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: ceiling),
      child: SingleChildScrollView(child: Text(note)),
    );
  }
}

/// How the app says something in passing.
///
/// Every snackbar in CoLabRoom goes through here, and the reason is the one in
/// [NoteThatFits]: a floating snackbar is as tall as its words, and at a large
/// text size a long sentence is drawn off the top of the screen — silently in
/// release, as a layout throw in debug. Wrapping the words at 116 call sites
/// would fix the 116 and not the 117th. One door means the ceiling is decided
/// in one place, and a note written next year arrives already fitting.
///
/// Nothing else changes: the same words, the same action, the same duration
/// Flutter would have used. `test/every_note_lands_on_the_screen_test.dart`
/// reads `lib/` and fails if a snackbar is shown any other way.
extension SayIt on ScaffoldMessengerState {
  /// Shows [note], bounded so it lands on the screen at any text size.
  ///
  /// [action] is the one button somebody has a few seconds to find; [persist]
  /// and [duration] mean what they mean on [SnackBar], including its rule that
  /// a snackbar with an action persists unless it is told otherwise.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showNote(
    String note, {
    SnackBarAction? action,
    Duration? duration,
    bool? persist,
  }) {
    final NoteThatFits words = NoteThatFits(note);
    // Built two ways rather than writing four seconds down here. Saying
    // nothing about the duration has to keep meaning whatever [SnackBar]'s
    // own default is, and a second copy of that number in this file would
    // go quietly out of date the day the first one moved.
    return showSnackBar(
      duration == null
          ? SnackBar(content: words, action: action, persist: persist)
          : SnackBar(
              content: words,
              action: action,
              persist: persist,
              duration: duration,
            ),
    );
  }
}
