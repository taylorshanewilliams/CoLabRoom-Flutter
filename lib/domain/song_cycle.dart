/// A cycle the band counts for itself: how many beats go round, and which of
/// them are stressed.
///
/// Every Musician, Same Song, 17 September 2026, decision 20. Half the world
/// does not count in bars of four, and the obvious way to serve it would be a
/// library of named cycles -- talas, compases, iqa'at, usul -- shipped with
/// the app. That library would be somebody's transcription of somebody else's
/// tradition, and nobody here has reviewed a line of it. What a musician
/// actually needs is smaller and truer: a count and its stresses, said by the
/// person who plays it. "7: 3+2+2" is a whole cycle, and nothing in it claims
/// to be the authoritative anything.
///
/// The first beat is the one everything comes back to -- the sam, the one,
/// the downbeat, depending on who is counting -- and it is always the
/// heaviest, so it is never one of [accents]: it is the cycle itself.
class SongCycle {
  const SongCycle._(this.beats, this.accents);

  /// The cycle as somebody counted it, tidied.
  ///
  /// Tidied rather than refused because this is read from a row as well as
  /// built from taps: a stress on a beat the cycle no longer has, said before
  /// somebody shortened the count, is a stale answer and not a broken song.
  /// The same stance barOneIndex takes towards a bar 1 past the end of a
  /// re-analysis.
  factory SongCycle(int beats, [Iterable<int> accents = const <int>[]]) {
    final counted = beats.clamp(minBeats, maxBeats).toInt();
    final kept = <int>{
      for (final beat in accents)
        if (beat > 1 && beat <= counted) beat,
    }.toList()
      ..sort();
    return SongCycle._(counted, List<int>.unmodifiable(kept));
  }

  /// A cycle from what a row or a message says, or null because nobody has
  /// counted one.
  ///
  /// A count below two is not a cycle anybody plays round, so it reads as
  /// nothing said rather than as an error -- there is nowhere on a music
  /// stand to say one.
  static SongCycle? of(int? beats, [Iterable<int>? accents]) =>
      beats == null || beats < minBeats
          ? null
          : SongCycle(beats, accents ?? const <int>[]);

  /// Two is the shortest thing that goes round. Sixty-four is past any cycle
  /// a person counts and well inside what a row of taps can be read at.
  static const int minBeats = 2;
  static const int maxBeats = 64;

  /// How many beats go round before the count starts again.
  final int beats;

  /// The beats after the first that are stressed, ascending, each of them
  /// inside the count. Empty is an ordinary answer: a cycle of seven with
  /// nothing said about its inner shape is still a cycle of seven.
  final List<int> accents;

  /// Whether this beat of the cycle is played heavier than the ones around
  /// it. Beat one always is.
  bool isAccented(int beat) => beat == 1 || accents.contains(beat);

  /// How hard this beat of the cycle is struck: the first heaviest, the
  /// stressed ones next, the rest even.
  CycleStroke strokeAt(int beat) {
    if (beat == 1) return CycleStroke.sam;
    return accents.contains(beat) ? CycleStroke.accent : CycleStroke.beat;
  }

  /// The count broken at its stresses: 3+2+2 for a seven stressed on 4 and 6.
  List<int> get groups {
    final marks = <int>[1, ...accents];
    return <int>[
      for (var i = 0; i < marks.length; i += 1)
        (i + 1 < marks.length ? marks[i + 1] : beats + 1) - marks[i],
    ];
  }

  /// How the cycle reads out loud: "7: 3+2+2", or just "7" when nothing
  /// inside it has been said.
  String get reading =>
      accents.isEmpty ? '$beats' : '$beats: ${groups.join('+')}';

  /// The stress on each beat in turn, beat one first. What the click is
  /// written from and what the count-in is felt through.
  List<CycleStroke> get schedule => <CycleStroke>[
        for (var beat = 1; beat <= beats; beat += 1) strokeAt(beat),
      ];

  /// The same count with this beat stressed, or unstressed if it already is.
  /// Beat one cannot be turned off: it is where the cycle starts.
  SongCycle toggle(int beat) {
    if (beat <= 1 || beat > beats) return this;
    return SongCycle(
      beats,
      accents.contains(beat)
          ? <int>[for (final at in accents) if (at != beat) at]
          : <int>[...accents, beat],
    );
  }

  /// The same stresses over a different count. The ones past the end fall
  /// away, which is what shortening a cycle means.
  SongCycle withBeats(int count) => SongCycle(count, accents);

  @override
  bool operator ==(Object other) =>
      other is SongCycle &&
      other.beats == beats &&
      other.accents.length == accents.length &&
      _sameAccents(other.accents);

  bool _sameAccents(List<int> other) {
    for (var i = 0; i < accents.length; i += 1) {
      if (other[i] != accents[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(beats, Object.hashAll(accents));

  @override
  String toString() => 'SongCycle($reading)';
}

/// How hard one beat of a cycle is played: the first beat, a stressed one, or
/// an even one. Three and not two, because a cycle of sixteen stressed every
/// four still has one beat the whole thing turns on.
enum CycleStroke { sam, accent, beat }
