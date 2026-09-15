import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where you are in the song.
///
/// Taylor, performing: "the highlighted words are always at the very top ...
/// it would be nice if the highlighted words were maybe a little above the
/// middle of the screen, so this way you can always know where you are in
/// the song, what you just played and where you're going."
///
/// The anchor is the whole fix, so the arithmetic is pinned here: a line
/// lands a little above the middle, the opening lines are not dragged below
/// the top of the song, and the closing lines are not pulled past its end.
void main() {
  test('a line lands a little above the middle', () {
    final target = scrollToPutLineAtAnchor(
      lineOffset: 1000,
      viewportHeight: 800,
      maxExtent: 4000,
    );
    // 800 * 0.38 = 304 of screen above the line, 496 below it.
    expect(target, 696);
    expect(1000 - target, 800 * kSingingLineFraction);
  });

  test('the anchor is above the middle, not on it', () {
    expect(kSingingLineFraction, lessThan(0.5));
    expect(kSingingLineFraction, greaterThan(0.25),
        reason: 'enough of the song behind you to find your place again');
  });

  test('the first lines sit where they can rather than above the song', () {
    expect(
      scrollToPutLineAtAnchor(lineOffset: 40, viewportHeight: 800, maxExtent: 4000),
      0,
    );
  });

  test('the last lines are not pulled past the end', () {
    expect(
      scrollToPutLineAtAnchor(lineOffset: 3990, viewportHeight: 800, maxExtent: 4000),
      3686,
    );
    expect(
      scrollToPutLineAtAnchor(lineOffset: 9000, viewportHeight: 800, maxExtent: 4000),
      4000,
    );
  });

  test('a sheet shorter than the screen does not scroll at all', () {
    expect(
      scrollToPutLineAtAnchor(lineOffset: 300, viewportHeight: 800, maxExtent: 0),
      0,
    );
  });
}
