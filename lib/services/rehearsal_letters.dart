import 'dart:math' as math;

import '../domain/song_analysis_models.dart';
import 'chord_beat_grid.dart';

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
/// are the same idea — [StructureSection.label] carries the repeat on
/// everything the worker has written since the parts were named, and
/// [StructureSection.repeatsSectionLabel] carries it on the lettered
/// analyses before that (see [sectionFamily]) — so the letters fall out of
/// it. That has two consequences worth saying out loud:
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

/// Which part a section is a repeat of, as a key two sections can be
/// compared on.
///
/// Analyses since the parts were named share a label between repeats, so the
/// label is the answer. The lettered analyses before that gave every section
/// its own letter and pointed each repeat at the earlier section it
/// resembled, so there the pointer names the part and the label only names
/// this occurrence of it. Both are alive: chord_repeats.dart has read this
/// pointer since corrections learned to travel, and letters that ignored it
/// would show "A B C D" for a song whose form is "A B B C".
///
/// One step. [rehearsalLetters] follows a chain of them.
String sectionFamily(StructureSection section) {
  final pointer = section.repeatsSectionLabel?.trim() ?? '';
  return (pointer.isNotEmpty ? pointer : section.label.trim()).toLowerCase();
}

/// The part a section belongs to, following pointers back to the section
/// that starts the family.
///
/// A pointer at a section that itself points is followed; a pointer at
/// something this analysis does not contain stops where it is, because the
/// pointer still names the family even when the section it names is gone.
/// A ring of pointers — which nothing writes, but a hand-edited analysis
/// could — settles on the first of its keys in alphabetical order, so every
/// section in the ring lands on the same one instead of each picking
/// whichever it happened to start from.
String _familyOf(StructureSection section, Map<String, StructureSection> byLabel) {
  var at = section;
  final seen = <String>{at.label.trim().toLowerCase()};
  while (true) {
    final family = sectionFamily(at);
    if (family == at.label.trim().toLowerCase()) return family;
    final next = byLabel[family];
    if (next == null) return family;
    if (!seen.add(family)) return (seen.toList()..sort()).first;
    at = next;
  }
}

/// A letter for every section, repeats sharing theirs.
///
/// The letter is keyed on the part a section belongs to (see
/// [sectionFamily]) rather than on [StructureSection.displayLabel], because
/// that is what carries the repeat, and because a name somebody typed must
/// not renumber the form underneath them.
List<RehearsalLetter> rehearsalLetters(List<StructureSection> sections) {
  if (sections.isEmpty) return const <RehearsalLetter>[];
  final ordered = List<StructureSection>.of(sections)
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  final byLabel = <String, StructureSection>{};
  for (final section in ordered) {
    byLabel.putIfAbsent(section.label.trim().toLowerCase(), () => section);
  }
  final byFamily = <String, String>{};
  final letters = <RehearsalLetter>[];
  var next = 0;
  for (final section in ordered) {
    final key = _familyOf(section, byLabel);
    var letter = byFamily[key];
    if (letter == null) {
      if (key == 'intro') {
        letter = introLetter;
      } else if (key == 'outro') {
        letter = outroLetter;
      } else {
        letter = _letterAt(next);
        next += 1;
      }
      byFamily[key] = letter;
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

/// The part's name as it is written beside [letter], or empty when the
/// letter has already said it.
///
/// Plenty of analyses letter their parts themselves: the chroma fallback in
/// the worker calls them "A", "B", "C" in order of first appearance, and
/// every analysis from before the parts were named did the same. Printing
/// the derived letter beside a name like that gives "A  A", which says one
/// thing twice, and past the eighth part — where the old lettering reaches
/// "I", which the rehearsal letters skip — it gives "J  I", which says one
/// thing twice and disagrees with itself.
///
/// So a name that is a single letter is taken as lettering rather than as a
/// word, and the derived letter stands alone. That also covers a part
/// somebody renamed to a single letter by hand: two letters on one heading
/// would leave a band with no way to know which one "from B" means, and the
/// one that means anything to the rest of the room is the derived one.
String nameBeside(String? letter, String name) {
  final shown = name.trim();
  if (letter == null || letter.isEmpty || shown.isEmpty) return shown;
  if (shown.toUpperCase() == letter) return '';
  if (shown.length == 1 && RegExp('^[A-Za-z]\$').hasMatch(shown)) return '';
  return shown;
}

/// A section heading as a chart writes it: "B  CHORUS".
///
/// The letter first, because it is what gets said out loud, and the name
/// after it, because it is what the letter means. The letter alone where
/// the name would only repeat it, and the name alone where there is no
/// letter to give — a heading somebody typed into the song is their own
/// word for their own part and nothing says which part of the analysis it
/// belongs to.
String letteredHeading(String? letter, String name) {
  final shown = name.trim().toUpperCase();
  if (letter == null || letter.isEmpty) return shown;
  final beside = nameBeside(letter, name).toUpperCase();
  return beside.isEmpty ? letter : '$letter  $beside';
}

/// The whole arrangement on one line: "I A A B A C B B O".
///
/// Empty for a song with no sections, which is how every page that shows it
/// knows to show nothing at all rather than an empty heading.
String arrangementCode(List<RehearsalLetter> letters) =>
    letters.map((letter) => letter.letter).join(' ');

/// Where a jump to a part lands: the downbeat its section begins on.
///
/// Two things can be wrong with a section's start, and they want opposite
/// answers.
///
/// A boundary a hair *after* its bar drops the player inside the bar and the
/// first chord of the part arrives already sounding, so the answer is the
/// downbeat at or before the start: that costs at most a lead-in, which is
/// what a musician asking for a part wants anyway.
///
/// A boundary a hair *before* its bar is the other way round, and going back
/// from there lands a whole bar early. The worker's own structure model
/// snaps its boundaries onto downbeats (_snap_to_downbeats in handler.py),
/// but the chroma fallback it uses when that model is unavailable does not
/// snap at all, so its boundaries sit wherever the segmenter put them. So a
/// downbeat within [_snapMs] of the start — about half a beat in common
/// time — is taken as the bar the part begins on, whichever side of the
/// start it falls.
///

/// Where bar 1 is (0161) does not come into it. Saying "this is bar 1" moves
/// the numbers in the margin and not one millisecond of the recording, so a
/// part that begins in the pickup is still jumped to: the pickup is music
/// somebody plays.
///
/// Without a beat grid the section's own start stands, which is the only
/// honest answer available.
int sectionDownbeatMs(int startMs, List<int> downbeatsMs) {
  if (downbeatsMs.isEmpty) return startMs;
  final tolerance = _snapMs(downbeatsMs);
  var nearest = downbeatsMs.first;
  var best = -1;
  for (final downbeat in downbeatsMs) {
    if ((downbeat - startMs).abs() < (nearest - startMs).abs()) {
      nearest = downbeat;
    }
    if (downbeat <= startMs && downbeat > best) best = downbeat;
  }
  if ((nearest - startMs).abs() <= tolerance) return nearest;
  return best < 0 ? startMs : best;
}

/// How far from a downbeat a section's start can be and still be that
/// downbeat: half a beat of common time, and never more than a quarter of a
/// second.
///
/// Only the downbeats are known here, so a beat is taken as a quarter of a
/// bar. Half of one is the same window chord snapping uses — past it, the
/// start is nearer some other beat and the boundary is a real one rather
/// than a rounding of it.
int _snapMs(List<int> downbeatsMs) {
  final bar = medianBeatIntervalMs(downbeatsMs);
  if (bar <= 0) return 250;
  return math.min(250, (bar / 8).round());
}
