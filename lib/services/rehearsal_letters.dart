import '../domain/song_analysis_models.dart';

/// Letters on the form, and a short code for the whole song.
///
/// Every Musician, Same Song, 17 September 2026: a band at rehearsal does not
/// say "from the second chorus", it says "from B", and the shape of an
/// arrangement fits on one line as "I A A B A C B B O". Both are older than
/// any of this and both are read the same way in a jazz band, a pit band, a
/// wedding band and a school orchestra, which is why they are worth having:
/// the letter is the one name for a part that everybody in the room already
/// shares.
///
/// Derived, never stored. The analysis already says which parts of the song
/// are the same idea ([StructureSection.label] carries the repeat — see the
/// separation worker, which gives every occurrence of one part the same
/// name), so the letters fall out of it. That has two consequences worth
/// saying out loud:
///
/// * A rename does not move a letter. Calling the chorus "the big one"
///   ([StructureSection.customLabel]) changes what is printed beside B; it
///   does not make it C.
/// * A re-analysis re-derives them, the same way it re-derives everything
///   else on the page.

/// One part of the song, and the letter a band would call it by.
class RehearsalLetter {
  const RehearsalLetter({
    required this.letter,
    required this.label,
    required this.startMs,
    required this.endMs,
  });

  /// "A", "B", "I", "O" — what somebody says out loud.
  final String letter;

  /// What the part is called on this page: the band's name for it when they
  /// have given one, the model's word when they have not.
  final String label;

  final int startMs;
  final int endMs;

  @override
  bool operator ==(Object other) =>
      other is RehearsalLetter &&
      other.letter == letter &&
      other.label == label &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(letter, label, startMs, endMs);

  @override
  String toString() => '$letter $label';
}

/// An intro and an outro are named rather than lettered, everywhere charts
/// are written. "From the top" and "from the tag" are the sentences; nobody
/// counts the intro as A.
const String introLetter = 'I';
const String outroLetter = 'O';

/// The letters the run through the song uses, in order.
///
/// I and O are not in it. They are taken by the intro and the outro above,
/// and a printed I next to a 1 and a printed O next to a 0 are the two
/// letters every engraver has skipped for a century anyway.
const String _run = 'ABCDEFGHJKLMNPQRSTUVWXYZ';

/// A, B, ... Z, then AA, BB, ... — the way a chart that runs past the
/// alphabet is marked up. A song with two dozen distinct parts is not a
/// thing that happens, but a beat grid that came back wrong can make one.
String _letterAt(int index) =>
    _run[index % _run.length] * (index ~/ _run.length + 1);

/// A letter for every section, repeats sharing theirs.
///
/// The letter is keyed on [StructureSection.label] — the analysis's own word
/// for the part, not [StructureSection.displayLabel] — because that is what
/// carries the repeat, and because a name somebody typed must not renumber
/// the form underneath them.
List<RehearsalLetter> rehearsalLetters(List<StructureSection> sections) {
  if (sections.isEmpty) return const <RehearsalLetter>[];
  final ordered = List<StructureSection>.of(sections)
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  final byLabel = <String, String>{};
  final letters = <RehearsalLetter>[];
  var next = 0;
  for (final section in ordered) {
    final key = section.label.trim().toLowerCase();
    var letter = byLabel[key];
    if (letter == null) {
      if (key == 'intro') {
        letter = introLetter;
      } else if (key == 'outro') {
        letter = outroLetter;
      } else {
        letter = _letterAt(next);
        next += 1;
      }
      byLabel[key] = letter;
    }
    letters.add(
      RehearsalLetter(
        letter: letter,
        label: section.displayLabel,
        startMs: section.startMs,
        endMs: section.endMs,
      ),
    );
  }
  return List<RehearsalLetter>.unmodifiable(letters);
}

/// The whole arrangement on one line: "I A A B A C B B O".
///
/// Empty for a song with no sections, which is how every page that shows it
/// knows to show nothing at all rather than an empty heading.
String arrangementCode(List<RehearsalLetter> letters) =>
    letters.map((letter) => letter.letter).join(' ');

/// Where a jump to a part lands: the downbeat its section begins on.
///
/// Sections are found on downbeats, but a boundary that drifted by a few
/// milliseconds would drop the player a hair inside the previous bar and the
/// first chord of the part would arrive already sounding. Going back to the
/// downbeat at or before the section's start costs at most a lead-in, which
/// is what a musician asking for a part wants anyway.
///
/// Where bar 1 is (0161) does not come into it. Saying "this is bar 1" moves
/// the numbers in the margin and not one millisecond of the recording, so a
/// part that begins in the pickup is still jumped to: the pickup is music
/// somebody plays.
///
/// Without a beat grid the section's own start stands, which is the only
/// honest answer available.
int sectionDownbeatMs(int startMs, List<int> downbeatsMs) {
  var best = -1;
  for (final downbeat in downbeatsMs) {
    if (downbeat <= startMs && downbeat > best) best = downbeat;
  }
  return best < 0 ? startMs : best;
}
