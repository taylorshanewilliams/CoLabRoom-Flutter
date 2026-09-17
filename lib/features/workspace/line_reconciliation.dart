/// Which contribution each line of an edited song belongs to.
///
/// The song editor shows one flowing document, but a song is stored as one
/// contribution per line, and each one carries the person who wrote it, their
/// colour and any voice note recorded against it. A save has to decide, for
/// every line on screen, which of those rows it is.
///
/// It used to decide by position: the third line was whichever contribution
/// was third. Found in the audit of 17 September 2026: inserting one line near
/// the top of a band's song moved every later line's words into the
/// contribution above it. Each line after the insert was credited to the wrong
/// person, voice notes ended up beside somebody else's words, and the last
/// line became a new contribution in the name of whoever pressed Enter.
/// Deleting a line did the reverse, and deleted the last contribution instead
/// of the one that went.
///
/// So a save now compares what the editor was shown with what it holds, line
/// by line, the way a text diff does, and a line keeps its row for as long as
/// its words do.
///
/// Nothing in here knows about Flutter, a repository or the network, so every
/// case can be tested on its own.
library;

import 'dart:typed_data';

/// One line of the song as an editor last knew it: which contribution it is,
/// and its words in the form they are stored in.
class SeenLine {
  const SeenLine({required this.contributionId, required this.body});

  final String contributionId;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is SeenLine && other.contributionId == contributionId && other.body == body;

  @override
  int get hashCode => Object.hash(contributionId, body);

  @override
  String toString() => 'SeenLine($contributionId, "$body")';
}

/// What a save does with one line of the edited document.
enum LineChange {
  /// The same words, still between the same neighbours. Nothing to write.
  kept,

  /// Different words where a line stood. The contribution keeps its writer,
  /// colour and voice note, and takes the new words — the same as editing a
  /// line has always done.
  rewritten,

  /// The same words somewhere else in the song. The contribution goes with
  /// them, rather than being deleted in one place and written again in
  /// another under a different name.
  moved,

  /// Words that were not in the song before. A new contribution, in the name
  /// of whoever wrote them.
  added,
}

/// The plan for one line of the edited document.
class PlannedLine {
  const PlannedLine(this.change, this.body, {this.contributionId});

  final LineChange change;

  /// The line's words, in stored form.
  final String body;

  /// The contribution this line is. Null only for [LineChange.added].
  final String? contributionId;

  @override
  bool operator ==(Object other) =>
      other is PlannedLine &&
      other.change == change &&
      other.body == body &&
      other.contributionId == contributionId;

  @override
  int get hashCode => Object.hash(change, body, contributionId);

  @override
  String toString() => 'PlannedLine(${change.name}, "$body", $contributionId)';
}

class LineReconciliation {
  const LineReconciliation({required this.lines, required this.deleted});

  /// One entry per line of the edited document, in the document's order.
  final List<PlannedLine> lines;

  /// Contributions whose words are no longer anywhere in the document, in the
  /// order the editor saw them. Only ever lines the editor was shown.
  final List<String> deleted;

  bool get changesNothing =>
      deleted.isEmpty && lines.every((line) => line.change == LineChange.kept);
}

/// Past this many cells the middle of a document is not compared line by
/// line. About 1,400 changed lines against 1,400, far beyond any song; the
/// cap exists so a pasted book cannot stall a phone. Lines beyond it still
/// keep their contributions when their words reappear, through the same
/// matching that finds moved lines.
const int _maxComparedCells = 2000000;

/// Works out what a save must do to turn [seen] into [lines].
///
/// Both sides must already be in stored form (see `storedLineFor`), so a
/// blank line typed as '' compares equal to the marker it is stored as.
///
/// In order:
///
///   1. The longest run of lines common to both, in order, is kept. Those
///      lines keep their contributions and nothing is written for them.
///   2. What is left falls into hunks: lines that went and lines that
///      arrived between the same two kept lines. Words that went from one
///      hunk and arrived in another are a moved line.
///   3. Inside a hunk, a line that went is paired with a line that arrived,
///      in order, and that contribution is rewritten. When the counts differ,
///      each pairing goes to the line whose words it most resembles, so
///      typing a new line above one you are also editing does not hand the
///      edited line's contribution to the new words.
///   4. Anything unpaired that arrived is added, and anything unpaired that
///      went is deleted — exactly that contribution, never its neighbour.
LineReconciliation reconcileLines(List<SeenLine> seen, List<String> lines) {
  final seenCount = seen.length;
  final lineCount = lines.length;
  final seenForLine = List<int>.filled(lineCount, -1);

  var head = 0;
  while (head < seenCount && head < lineCount && seen[head].body == lines[head]) {
    seenForLine[head] = head;
    head += 1;
  }
  var tail = 0;
  while (tail < seenCount - head &&
      tail < lineCount - head &&
      seen[seenCount - 1 - tail].body == lines[lineCount - 1 - tail]) {
    seenForLine[lineCount - 1 - tail] = seenCount - 1 - tail;
    tail += 1;
  }
  _matchMiddle(
    seen,
    lines,
    seenStart: head,
    seenEnd: seenCount - tail,
    lineStart: head,
    lineEnd: lineCount - tail,
    seenForLine: seenForLine,
  );

  // Hunks: what went and what arrived between two consecutive kept lines.
  final hunks = <_Hunk>[];
  var seenCursor = 0;
  var lineCursor = 0;
  void closeHunk(int seenUntil, int lineUntil) {
    if (seenCursor == seenUntil && lineCursor == lineUntil) return;
    hunks.add(_Hunk(
      went: <int>[for (var i = seenCursor; i < seenUntil; i += 1) i],
      arrived: <int>[for (var j = lineCursor; j < lineUntil; j += 1) j],
    ));
  }

  for (var j = 0; j < lineCount; j += 1) {
    final match = seenForLine[j];
    if (match < 0) continue;
    closeHunk(match, j);
    seenCursor = match + 1;
    lineCursor = j + 1;
  }
  closeHunk(seenCount, lineCount);

  final change = List<LineChange>.filled(lineCount, LineChange.kept);
  final contributionFor = List<String?>.filled(lineCount, null);
  final claimed = List<bool>.filled(seenCount, false);
  for (var j = 0; j < lineCount; j += 1) {
    final match = seenForLine[j];
    if (match >= 0) {
      contributionFor[j] = seen[match].contributionId;
      claimed[match] = true;
    }
  }

  // Moves: the same words went from one place and arrived in another. Within
  // one hunk nothing that went can equal anything that arrived, because the
  // kept run would have been longer. The exception is a middle too large to
  // compare, and there matching equal words is exactly what keeps those lines
  // with their writers.
  final wentByBody = <String, List<int>>{};
  for (final hunk in hunks) {
    for (final i in hunk.went) {
      (wentByBody[seen[i].body] ??= <int>[]).add(i);
    }
  }
  for (final hunk in hunks) {
    for (final j in hunk.arrived) {
      final candidates = wentByBody[lines[j]];
      if (candidates == null || candidates.isEmpty) continue;
      final i = candidates.removeAt(0);
      claimed[i] = true;
      change[j] = LineChange.moved;
      contributionFor[j] = seen[i].contributionId;
    }
  }

  // Rewrites, then additions.
  for (final hunk in hunks) {
    final went = hunk.went.where((i) => !claimed[i]).toList(growable: false);
    final arrived = hunk.arrived
        .where((j) => change[j] != LineChange.moved)
        .toList(growable: false);
    for (final pair in _pairByResemblance(
      went.map((i) => seen[i].body).toList(growable: false),
      arrived.map((j) => lines[j]).toList(growable: false),
    )) {
      final i = went[pair.$1];
      final j = arrived[pair.$2];
      claimed[i] = true;
      change[j] = LineChange.rewritten;
      contributionFor[j] = seen[i].contributionId;
    }
    for (final j in arrived) {
      if (contributionFor[j] == null) change[j] = LineChange.added;
    }
  }

  return LineReconciliation(
    lines: List<PlannedLine>.unmodifiable(<PlannedLine>[
      for (var j = 0; j < lineCount; j += 1)
        PlannedLine(change[j], lines[j], contributionId: contributionFor[j]),
    ]),
    deleted: List<String>.unmodifiable(<String>[
      for (var i = 0; i < seenCount; i += 1)
        if (!claimed[i]) seen[i].contributionId,
    ]),
  );
}

class _Hunk {
  const _Hunk({required this.went, required this.arrived});

  /// Indexes into what the editor saw.
  final List<int> went;

  /// Indexes into the edited document.
  final List<int> arrived;
}

/// The longest common subsequence of the untrimmed middle, written into
/// [seenForLine]. The table holds, for each pair of positions, how many lines
/// the rest of both sides have in common; walking it forwards and taking
/// equal lines whenever they meet is always optimal, and on a tie it lets a
/// line go before another arrives, which keeps each hunk in one piece.
void _matchMiddle(
  List<SeenLine> seen,
  List<String> lines, {
  required int seenStart,
  required int seenEnd,
  required int lineStart,
  required int lineEnd,
  required List<int> seenForLine,
}) {
  final rows = seenEnd - seenStart;
  final columns = lineEnd - lineStart;
  if (rows <= 0 || columns <= 0) return;
  if (rows * columns > _maxComparedCells) return;

  final width = columns + 1;
  final common = Int32List((rows + 1) * width);
  for (var i = rows - 1; i >= 0; i -= 1) {
    for (var j = columns - 1; j >= 0; j -= 1) {
      common[i * width + j] = seen[seenStart + i].body == lines[lineStart + j]
          ? common[(i + 1) * width + j + 1] + 1
          : _larger(common[(i + 1) * width + j], common[i * width + j + 1]);
    }
  }

  var i = 0;
  var j = 0;
  while (i < rows && j < columns) {
    if (seen[seenStart + i].body == lines[lineStart + j]) {
      seenForLine[lineStart + j] = seenStart + i;
      i += 1;
      j += 1;
    } else if (common[(i + 1) * width + j] >= common[i * width + j + 1]) {
      i += 1;
    } else {
      j += 1;
    }
  }
}

int _larger(int a, int b) => a > b ? a : b;

/// Pairs lines that went with lines that arrived, keeping both in order.
///
/// Every line on the shorter side is paired. With equal counts that forces
/// first-with-first, which is what editing a run of lines in place means.
/// With unequal counts there is a choice, and it goes to the pairing whose
/// words most resemble each other, measured as the characters the two share
/// at the start and at the end. On a tie the earlier line wins, so splitting
/// "Hello world" into "Hello" and "world" keeps the contribution on "Hello".
List<(int, int)> _pairByResemblance(List<String> went, List<String> arrived) {
  if (went.isEmpty || arrived.isEmpty) return const <(int, int)>[];
  final wentIsShorter = went.length <= arrived.length;
  final short = wentIsShorter ? went : arrived;
  final long = wentIsShorter ? arrived : went;
  final shortCount = short.length;
  final longCount = long.length;
  if (shortCount == longCount || (shortCount + 1) * (longCount + 1) > _maxComparedCells) {
    return <(int, int)>[for (var i = 0; i < shortCount; i += 1) (i, i)];
  }

  // best[x][y]: the highest total resemblance pairing the first x of the
  // short side with lines among the first y of the long side. -1 where that
  // cannot be done, because x > y.
  final width = longCount + 1;
  final best = List<int>.filled((shortCount + 1) * width, -1);
  for (var y = 0; y <= longCount; y += 1) {
    best[y] = 0;
  }
  for (var x = 1; x <= shortCount; x += 1) {
    for (var y = x; y <= longCount; y += 1) {
      final skip = best[x * width + y - 1];
      final pairHere = best[(x - 1) * width + y - 1] + _resemblance(short[x - 1], long[y - 1]);
      best[x * width + y] = skip > pairHere ? skip : pairHere;
    }
  }

  final pairs = <(int, int)>[];
  var x = shortCount;
  var y = longCount;
  while (x > 0) {
    // Leaving the later long-side line unpaired whenever that costs nothing
    // is what pushes a tie towards the earlier line.
    if (y > x && best[x * width + y - 1] == best[x * width + y]) {
      y -= 1;
      continue;
    }
    pairs.add(wentIsShorter ? (x - 1, y - 1) : (y - 1, x - 1));
    x -= 1;
    y -= 1;
  }
  return pairs.reversed.toList(growable: false);
}

/// Characters two lines share at the start plus at the end, never counting
/// one character twice.
int _resemblance(String a, String b) {
  final shorter = a.length < b.length ? a.length : b.length;
  var start = 0;
  while (start < shorter && a.codeUnitAt(start) == b.codeUnitAt(start)) {
    start += 1;
  }
  var end = 0;
  while (end < shorter - start &&
      a.codeUnitAt(a.length - 1 - end) == b.codeUnitAt(b.length - 1 - end)) {
    end += 1;
  }
  return start + end;
}

/// How far apart new lines are spaced when there is room.
const double linePositionStep = 1024;

/// Where each line of a saved document goes.
class PositionPlan {
  const PositionPlan(this.positions, {required this.renumbered});

  /// One position per line, strictly between its neighbours.
  final List<double> positions;

  /// True when there was no room for a line between its neighbours, so every
  /// line was given a fresh, evenly spaced position. Lines that already
  /// existed then have to be moved as well as the new ones placed.
  final bool renumbered;
}

/// Positions for a document in order, given the positions its existing rows
/// already have and null for each row that needs one — a new line, or a line
/// that moved.
///
/// `contributions.position` is `numeric` (migration 0005) and both
/// repositories order by it and then by `created_at`, so a line goes between
/// its neighbours by taking the midpoint, or evenly spaced points when
/// several arrive together. At the ends there is always room: a step past the
/// last line, or before the first.
///
/// The app reads a position as a double, so halving a gap cannot go on
/// forever — a writer adding line after line in the same place runs out after
/// about fifty. Old rows can also share a position outright. When any line
/// has no room, every line is renumbered instead, which costs one write per
/// line once and leaves room for a long time after.
///
/// [before] is the position of the first row this editor was never shown.
/// Everything here stays below it, including when renumbering, so lines
/// somebody else added are never moved or overtaken.
PositionPlan planPositions(List<double?> existing, {double? before}) {
  final count = existing.length;
  final placed = List<double>.filled(count, 0);
  var fits = true;
  double? lower;
  var index = 0;
  while (index < count && fits) {
    final at = existing[index];
    if (at != null) {
      if (lower != null && at < lower) fits = false;
      placed[index] = at;
      lower = at;
      index += 1;
      continue;
    }
    var end = index;
    while (end < count && existing[end] == null) {
      end += 1;
    }
    final upper = end < count ? existing[end] : before;
    final run = end - index;
    var previous = lower;
    for (var k = 0; k < run; k += 1) {
      final double value;
      if (lower == null && upper == null) {
        value = linePositionStep * (k + 1);
      } else if (upper == null) {
        value = lower! + linePositionStep * (k + 1);
      } else if (lower == null) {
        value = upper - linePositionStep * (run - k);
      } else {
        value = lower + (upper - lower) * (k + 1) / (run + 1);
      }
      // `!(a > b)` rather than `a <= b`, so a NaN counts as no room too.
      if (previous != null && !(value > previous)) fits = false;
      placed[index + k] = value;
      previous = value;
    }
    if (upper != null && previous != null && !(upper > previous)) fits = false;
    lower = previous;
    index = end;
  }
  if (fits && before != null && lower != null && lower > before) fits = false;
  if (fits) return PositionPlan(List<double>.unmodifiable(placed), renumbered: false);

  return PositionPlan(
    List<double>.unmodifiable(<double>[
      for (var i = 0; i < count; i += 1)
        before == null
            ? linePositionStep * (i + 1)
            : before - linePositionStep * (count - i),
    ]),
    renumbered: true,
  );
}
