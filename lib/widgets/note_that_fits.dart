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
/// clamped). What is bounded is the box: it takes at most [_share] of the
/// screen's height and scrolls inside that, so the words are all still there
/// at the size that was asked for and the snackbar is somewhere they can be
/// read.
class NoteThatFits extends StatelessWidget {
  const NoteThatFits(this.note, {super.key});

  /// What the app is saying. One sentence or two, in the app's own voice.
  final String note;

  /// How much of the screen a passing sentence may take.
  ///
  /// Room has to be left for what a floating snackbar is measured against:
  /// the record button, the tab bar, and the now-playing bar above it when
  /// something is playing. That furniture is about 240 logical pixels on the
  /// shortest phone this app supports, which leaves well over half; 0.45 sits
  /// inside it with room to spare and is also, on its own terms, as much of
  /// somebody's screen as a message they did not ask for should ever cover.
  static const double _share = 0.45;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * _share,
      ),
      child: SingleChildScrollView(child: Text(note)),
    );
  }
}
