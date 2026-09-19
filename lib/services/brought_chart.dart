/// Reading a chart somebody already has.
///
/// Taylor, 19 September 2026: can people practise any song they want in here,
/// the way they use a tab site? They can bring one. This app never fetches,
/// searches inside or downloads chart content from any tab or lyrics site —
/// there is no scraper here and no URL import, because tabs and lyrics of
/// commercial songs are licensed content and a site with no API has terms
/// that say so. What this does is what OnSong and SongbookPro do: take a
/// chart a person already has, for their own practice, into their own private
/// song.
///
/// Three shapes come in, and they are three spellings of one thing:
///
///  * ChordPro — `{title:}`, `{key:}`, `{start_of_chorus}` and the short
///    forms, with `[C]` chords inside the words.
///  * Chords over words — a line of chord names above a line of words, lined
///    up by column, under `[Verse 1]` headings. What every tab site prints.
///  * Words with the chords already bracketed inline, which is ChordPro's
///    body without its header.
///
/// All three come out as ChordPro, because one stored spelling means one
/// thing to draw, one thing to export, and one thing to test.
///
/// Two rules the reading obeys. A chord line is recognised by the app's own
/// chord grammar (see [isChordName]) rather than by a loose pattern, so "Am I
/// the only one" stays a lyric. And **no line is ever lost**: a line this
/// cannot make sense of — a tab block, a stray directive, a note to the
/// player — is kept exactly as it was written.
library;

import 'music_reference.dart';

/// How long a chart is allowed to be, in characters.
///
/// The same number as the check on `brought_charts.body` (0168), here as well
/// so somebody who pasted a whole songbook is told before the round trip
/// rather than after it. A very long song is a few thousand characters.
const int chartBodyLimit = 65536;

/// What one line of a brought chart is.
enum ChartLineKind {
  /// The name of a part: "Verse 1", "Chorus". A `{comment}` in ChordPro, a
  /// `[Verse 1]` on a tab site.
  heading,

  /// Words, with the chords that sit over them.
  words,

  /// Chords with no words under them — an intro, a turnaround, a solo.
  chords,

  /// A line of tablature, kept character for character.
  tab,

  /// A line this reader did not understand, kept exactly as it arrived.
  text,

  /// The space between two parts.
  blank,
}

/// One chord, and where in its line it sits.
class BroughtChord {
  const BroughtChord({required this.chord, required this.at});

  /// Written the way the chart wrote it — "Am7", "G/B" — never Harte.
  final String chord;

  /// How many characters into the line's words the chord belongs, which is
  /// where ChordPro puts its bracket. Zero on a line with no words.
  final int at;
}

/// One line of a chart somebody brought.
class BroughtChartLine {
  const BroughtChartLine({
    required this.kind,
    this.text = '',
    this.chords = const <BroughtChord>[],
  });

  final ChartLineKind kind;

  /// The words, the part's name, or the line kept verbatim.
  final String text;

  /// In the order they are played, left to right.
  final List<BroughtChord> chords;
}

/// A chart, read.
class BroughtChart {
  const BroughtChart({
    this.title,
    this.artist,
    this.key,
    this.capo,
    this.tuning,
    this.lines = const <BroughtChartLine>[],
  });

  /// The facts a chart states about itself, kept as the chart wrote them.
  /// Null for anything it did not say — nothing here is inferred.
  final String? title;
  final String? artist;
  final String? key;
  final String? capo;
  final String? tuning;

  final List<BroughtChartLine> lines;

  /// Whether there is anything here worth keeping.
  bool get isEmpty => lines
      .every((line) => line.text.trim().isEmpty && line.chords.isEmpty);

  /// How many chords were understood, which is what the preview counts.
  int get chordCount =>
      lines.fold(0, (total, line) => total + line.chords.length);

  /// Every chord the chart reaches for, once each, in the order they first
  /// appear. What the key sheet's capo rows are worked out from.
  List<String> get chordsUsed {
    final seen = <String>[];
    for (final line in lines) {
      for (final chord in line.chords) {
        if (!seen.contains(chord.chord)) seen.add(chord.chord);
      }
    }
    return seen;
  }

  /// The chart as ChordPro, which is the one spelling this app stores.
  ///
  /// Reading this back gives the same chart again, and writing that out gives
  /// the same text — so a chart that has been through here twice is the chart
  /// that went in once.
  String get chordPro {
    final out = StringBuffer();
    void directive(String name, String? value) {
      if (value == null || value.trim().isEmpty) return;
      out.writeln('{$name: ${_directiveSafe(value)}}');
    }

    directive('title', title);
    directive('artist', artist);
    directive('key', key);
    directive('capo', capo);
    directive('tuning', tuning);
    final hasHeader = out.isNotEmpty;

    var inTab = false;
    var first = true;
    void closeTab() {
      if (inTab) {
        out.writeln('{end_of_tab}');
        inTab = false;
      }
    }

    for (final line in lines) {
      if (first && hasHeader) {
        out.writeln();
        first = false;
      }
      switch (line.kind) {
        case ChartLineKind.tab:
          if (!inTab) {
            out.writeln('{start_of_tab}');
            inTab = true;
          }
          out.writeln(line.text);
        case ChartLineKind.heading:
          closeTab();
          out.writeln('{comment: ${_directiveSafe(line.text)}}');
        case ChartLineKind.blank:
          closeTab();
          out.writeln();
        case ChartLineKind.text:
          closeTab();
          out.writeln(line.text);
        case ChartLineKind.words:
        case ChartLineKind.chords:
          closeTab();
          out.writeln(writeLine(line));
      }
    }
    closeTab();
    return out.toString();
  }
}

/// One line written back out with its chords in brackets.
String writeLine(BroughtChartLine line) {
  final words = line.text;
  final out = StringBuffer();
  var cursor = 0;
  for (final chord in line.chords) {
    final at = chord.at.clamp(0, words.length).toInt();
    if (at > cursor) {
      out.write(words.substring(cursor, at));
      cursor = at;
    }
    out.write('[${_bracketSafe(chord.chord)}]');
  }
  if (cursor < words.length) out.write(words.substring(cursor));
  return out.toString();
}

/// A chart, whichever of the three shapes it came in.
BroughtChart readChart(String source) {
  // A file from a Windows machine, a paste from a browser and a file from a
  // phone are the same chart with three line endings.
  final raw = _plainSpaces(source)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .toList(growable: false);

  String? title;
  String? artist;
  // Whether the artist came from a `{subtitle}` rather than from a directive
  // that actually names one. A real `{artist}` takes the slot back off it.
  var artistIsBorrowed = false;
  String? key;
  String? capo;
  String? tuning;
  final lines = <BroughtChartLine>[];

  var index = 0;
  var inTab = false;
  while (index < raw.length) {
    final line = raw[index];
    final trimmed = line.trim();

    if (inTab) {
      final closing = _directiveOf(trimmed);
      if (closing != null && _tabEnd.contains(closing.$1)) {
        inTab = false;
        index += 1;
        continue;
      }
      lines.add(BroughtChartLine(kind: ChartLineKind.tab, text: line.trimRight()));
      index += 1;
      continue;
    }

    if (trimmed.isEmpty) {
      lines.add(const BroughtChartLine(kind: ChartLineKind.blank));
      index += 1;
      continue;
    }

    final directive = _directiveOf(trimmed);
    if (directive != null) {
      final (name, value) = directive;
      if (_titleNames.contains(name)) {
        if (_takesTheFact(title, value)) {
          title = value;
        } else {
          lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
        }
      } else if (_artistNames.contains(name)) {
        // A `{subtitle}` sits in the artist's slot because that is what most
        // charts use it for, but a directive that really does name the artist
        // takes it back rather than being dropped as a second answer.
        final borrowed = !const <String>{'artist', 'a'}.contains(name);
        if (artist != null && artistIsBorrowed && !borrowed) {
          // The subtitle that was standing in for the artist goes back on the
          // page rather than being thrown away for having been displaced.
          if (artist != value) {
            lines.add(BroughtChartLine(
              kind: ChartLineKind.text,
              text: '{subtitle: ${_directiveSafe(artist)}}',
            ));
          }
          artist = value;
          artistIsBorrowed = false;
        } else if (artist == null) {
          artist = value;
          artistIsBorrowed = borrowed;
        } else if (_takesTheFact(artist, value)) {
          artist = value;
        } else {
          lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
        }
      } else if (_keyNames.contains(name)) {
        if (_takesTheFact(key, value)) {
          key = value;
        } else {
          lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
        }
      } else if (name == 'capo') {
        if (_takesTheFact(capo, value)) {
          capo = value;
        } else {
          lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
        }
      } else if (name == 'tuning') {
        if (_takesTheFact(tuning, value)) {
          tuning = value;
        } else {
          lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
        }
      } else if (_tabStart.contains(name)) {
        inTab = true;
      } else if (_tabEnd.contains(name)) {
        // A stray close with nothing open. Nothing to do and nothing to say.
      } else if (_headingNames.contains(name)) {
        // A named part, or the plain name of the block it opens. ChordPro
        // has a shape for a chorus and a comment for everything else; both
        // are read as the one thing a reader wants, which is what to call
        // this part of the song.
        final label = value.isEmpty ? (_blockNames[name] ?? '') : value;
        if (label.isNotEmpty) {
          lines.add(BroughtChartLine(
            kind: ChartLineKind.heading,
            text: label,
          ));
        }
      } else if (_endNames.contains(name)) {
        // The end of a named block. The heading marked where it started and
        // the blank line after it is already in the file.
      } else {
        // A directive this does not know — `{tempo: 96}`, somebody's own
        // extension. Kept exactly as written rather than thrown away.
        lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
      }
      index += 1;
      continue;
    }

    // A part's name in square brackets, the way every tab site writes one.
    // `[C]` on its own is a chord and not a heading, which is the one case
    // the two spellings collide on.
    final bracketed = _bracketedHeading.firstMatch(trimmed);
    if (bracketed != null && !isChordName(bracketed.group(1)!.trim())) {
      lines.add(BroughtChartLine(
        kind: ChartLineKind.heading,
        text: bracketed.group(1)!.trim(),
      ));
      index += 1;
      continue;
    }

    // A chord row is read as one before tablature is looked for, because the
    // two spellings overlap: "G | C | D" is a row of chords written with bar
    // lines and not a string of a tab (review, 19 September 2026).
    if (_isChordLine(trimmed)) {
      final next = index + 1 < raw.length ? raw[index + 1] : null;
      if (next != null && _isWordsUnder(next)) {
        final married = _chordsOverWords(line, next);
        if (married != null) {
          lines.add(married);
          index += 2;
          continue;
        }
        // Nothing on that row came back as a chord, so it is kept as it was
        // written rather than thrown away. No line is ever lost.
        lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
        index += 1;
        continue;
      }
      final alone = _chordsAlone(trimmed);
      lines.add(alone ??
          BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
      index += 1;
      continue;
    }

    if (_looksLikeTab(trimmed)) {
      lines.add(BroughtChartLine(kind: ChartLineKind.tab, text: line.trimRight()));
      index += 1;
      continue;
    }

    final fact = _factIn(trimmed);
    if (fact != null) {
      final said = fact.$2;
      final kept = switch (fact.$1) {
        'capo' => _takesTheFact(capo, said),
        'key' => _takesTheFact(key, said),
        _ => _takesTheFact(tuning, said),
      };
      if (kept) {
        switch (fact.$1) {
          case 'capo':
            capo = said;
          case 'key':
            key = said;
          case 'tuning':
            tuning = said;
        }
      } else {
        // A written key change before the last chorus, a second capo: the
        // chart already said one of these and this is a different answer, so
        // it stays on the page where the player can see it.
        lines.add(BroughtChartLine(kind: ChartLineKind.text, text: trimmed));
      }
      index += 1;
      continue;
    }

    // "Intro: G  C  D" — a name for the part and the chords of it on one
    // line, which is how a tab site writes an intro. Read as the two things
    // it is, so the chords move with every other chord on the page when
    // somebody transposes (review, 19 September 2026).
    final labelled = _labelledChordRow(trimmed);
    if (labelled != null) {
      final row = _chordsAlone(labelled.$2);
      if (row != null) {
        lines
          ..add(BroughtChartLine(
            kind: ChartLineKind.heading,
            text: labelled.$1,
          ))
          ..add(row);
        index += 1;
        continue;
      }
    }

    lines.add(_wordsWithInlineChords(trimmed));
    index += 1;
  }

  // Blank lines at either end are the space around the chart rather than
  // part of it, and leaving them in would make writing the file out twice
  // give two different files.
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].kind == ChartLineKind.blank) {
    start += 1;
  }
  while (end > start && lines[end - 1].kind == ChartLineKind.blank) {
    end -= 1;
  }

  return BroughtChart(
    title: _cleanFact(title),
    artist: _cleanFact(artist),
    key: _cleanFact(key),
    capo: _cleanFact(capo),
    tuning: _cleanFact(tuning),
    lines: lines.sublist(start, end),
  );
}

// ---------------------------------------------------------------------
// The shapes
// ---------------------------------------------------------------------

/// A chord line over a words line, married by column.
///
/// Column arithmetic, which is the only thing holding these two lines
/// together: a chord name starts above the letter it changes on. Tabs are
/// spelled out to a stop of eight first, because a chart written in a text
/// editor lines its chords up with tabs and a tab counted as one character
/// puts every chord in the line over the wrong word.
/// Null when nothing on the row above came back as a chord, so the caller can
/// keep that row as it was written instead of losing it.
BroughtChartLine? _chordsOverWords(String chordLine, String wordLine) {
  final above = _tabsOut(chordLine);
  final below = _tabsOut(wordLine);
  final indent = below.length - below.trimLeft().length;
  final words = below.trim();
  final chords = <BroughtChord>[];
  for (final token in _tokensWithColumns(above)) {
    final name = _chordIn(token.$1);
    if (name == null) continue;
    chords.add(BroughtChord(
      chord: name,
      at: (token.$2 - indent).clamp(0, words.length).toInt(),
    ));
  }
  if (chords.isEmpty) return null;
  chords.sort((a, b) => a.at.compareTo(b.at));
  return BroughtChartLine(
    kind: ChartLineKind.words,
    text: words,
    chords: chords,
  );
}

/// A row of chords with nothing under it, or null when none of it read as a
/// chord after all.
BroughtChartLine? _chordsAlone(String line) {
  final chords = <BroughtChord>[];
  for (final token in _tokensWithColumns(_tabsOut(line))) {
    final name = _chordIn(token.$1);
    if (name != null) chords.add(BroughtChord(chord: name, at: 0));
  }
  if (chords.isEmpty) return null;
  return BroughtChartLine(kind: ChartLineKind.chords, chords: chords);
}

/// Words with their chords already in brackets.
///
/// A bracket holding something that is not a chord — `[x4]`, `[Riff]` — is
/// left in the words exactly as it was written. Guessing it was a chord would
/// put a chord nobody wrote on the page; dropping it would lose a line.
BroughtChartLine _wordsWithInlineChords(String line) {
  final words = StringBuffer();
  final chords = <BroughtChord>[];
  var index = 0;
  while (index < line.length) {
    final open = line.indexOf('[', index);
    if (open < 0) {
      words.write(line.substring(index));
      break;
    }
    final close = line.indexOf(']', open + 1);
    if (close < 0) {
      words.write(line.substring(index));
      break;
    }
    words.write(line.substring(index, open));
    final inside = line.substring(open + 1, close).trim();
    if (isChordName(inside)) {
      chords.add(BroughtChord(chord: inside, at: words.length));
    } else {
      words.write(line.substring(open, close + 1));
    }
    index = close + 1;
  }
  final text = words.toString();
  if (chords.isEmpty) {
    return BroughtChartLine(kind: ChartLineKind.words, text: text.trimRight());
  }
  if (text.trim().isEmpty) {
    return BroughtChartLine(
      kind: ChartLineKind.chords,
      chords: <BroughtChord>[
        for (final chord in chords) BroughtChord(chord: chord.chord, at: 0),
      ],
    );
  }
  return BroughtChartLine(
    kind: ChartLineKind.words,
    text: text.trimRight(),
    chords: chords,
  );
}

// ---------------------------------------------------------------------
// Telling one line from another
// ---------------------------------------------------------------------

/// Whether every token on this line is a chord or a mark a chart puts beside
/// one, and at least one of them is a chord.
///
/// The whole line has to agree. One chord-shaped word does not make a lyric
/// into music — which is exactly what "A" in "A man walks in" would do, and
/// what "Am" in "Am I the only one" would do.
bool _isChordLine(String line) {
  final tokens = line.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  if (tokens.isEmpty) return false;
  var chords = 0;
  for (final token in tokens) {
    final bare = _stripMarks(token);
    if (bare.isEmpty) continue;
    if (!isChordName(bare)) return false;
    chords += 1;
  }
  return chords > 0;
}

/// Whether the line under a chord line is words the chords belong over.
bool _isWordsUnder(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return false;
  if (_directiveOf(trimmed) != null) return false;
  if (_bracketedHeading.hasMatch(trimmed)) return false;
  if (_looksLikeTab(trimmed)) return false;
  if (_factIn(trimmed) != null) return false;
  if (_isChordLine(trimmed)) return false;
  // Words that already carry their own chords are not waiting for a row of
  // them above; the row above is an intro or a turnaround of its own.
  if (trimmed.contains('[') && trimmed.contains(']')) return false;
  return true;
}

/// Tablature, which is kept exactly as it is and never taken apart.
///
/// Six strings and a wall of dashes: read it or do not, but a reader that
/// "tidied" it would destroy the one thing it is.
///
/// A string's letter and a bar line are not enough on their own, because that
/// is also how a row of chords is written: "G | C | D | G" is an intro, and
/// reading it as a tab froze it in the original key while every other chord on
/// the page moved (review, 19 September 2026). A fret or a dash has to follow
/// the bar for the line to be tablature.
bool _looksLikeTab(String line) =>
    _tabLine.hasMatch(line) || _dashRun.hasMatch(line);

/// "Intro: G  C  D" — a part's name and the chords of it on one line.
///
/// Returns the name and the row, or null when what follows the colon is not a
/// row of chords, which is every ordinary line of words with a colon in it.
(String, String)? _labelledChordRow(String line) {
  final match = _labelled.firstMatch(line);
  if (match == null) return null;
  final rest = match.group(2)!.trim();
  if (!_isChordLine(rest)) return null;
  return (match.group(1)!.trim(), rest);
}

/// Whether a fact the chart has already stated can be written into its slot.
///
/// The first answer stays. A second one that says the same thing is absorbed,
/// and a second one that says something different is refused here so the
/// caller can keep it on the page: a key change written before the last
/// chorus is a line, and losing it would break the one rule this reader has.
bool _takesTheFact(String? already, String value) =>
    already == null || already.trim() == value.trim();

/// Every kind of space a paste can arrive with, written as the plain one.
///
/// A chart copied out of an email, a Word document or a web page keeps its
/// alignment with non-breaking spaces, because HTML collapses ordinary ones.
/// Every column here is counted in characters and one of these is one
/// character, so this changes what the row is made of and not where anything
/// sits (review, 19 September 2026). The zero-width ones are taken out
/// instead, for the same reason: they occupy no column.
String _plainSpaces(String source) => source
    .replaceAll(RegExp(r'[​‌‍﻿]'), '')
    .replaceAll(RegExp(r'[   -   　]'), ' ');

/// What a chart says about itself on a line of its own.
///
/// A colon is required for the key and the tuning, because "Key to my heart"
/// and "Tuning out the world" are lyrics. A capo is allowed without one, and
/// only when a number follows, because "Capo 2" is how every tab site writes
/// it and there is no line of words shaped like that.
(String, String)? _factIn(String line) {
  final capo = _capoLine.firstMatch(line);
  if (capo != null) return ('capo', capo.group(1)!.trim());
  final stated = _statedFact.firstMatch(line);
  if (stated != null) {
    return (stated.group(1)!.toLowerCase(), stated.group(2)!.trim());
  }
  return null;
}

/// The name and value of a `{directive}`, or null for a line that is not one.
(String, String)? _directiveOf(String line) {
  if (!line.startsWith('{') || !line.endsWith('}')) return null;
  final inside = line.substring(1, line.length - 1).trim();
  if (inside.isEmpty) return null;
  final colon = inside.indexOf(':');
  if (colon < 0) return (inside.toLowerCase(), '');
  return (
    inside.substring(0, colon).trim().toLowerCase(),
    inside.substring(colon + 1).trim(),
  );
}

/// The chord inside a token from a chord line, or null when the token is only
/// a mark — a bar line, a repeat, "x4", "N.C.".
String? _chordIn(String token) {
  final bare = _stripMarks(token);
  if (bare.isEmpty || !isChordName(bare)) return null;
  return bare;
}

/// A token with the marks a chart puts around a chord taken off.
///
/// Returns an empty string for a token that is nothing but marks, which is
/// how a bar line or a repeat count passes through a chord line without
/// making it a line of words.
String _stripMarks(String token) {
  var bare = token;
  while (bare.isNotEmpty && _leadingMark.hasMatch(bare[0])) {
    bare = bare.substring(1);
  }
  while (bare.isNotEmpty && _trailingMark.hasMatch(bare[bare.length - 1])) {
    bare = bare.substring(0, bare.length - 1);
  }
  if (_repeatMark.hasMatch(bare)) return '';
  return bare;
}

/// Every token on a line, with the column it starts in.
List<(String, int)> _tokensWithColumns(String line) {
  final tokens = <(String, int)>[];
  var at = 0;
  while (at < line.length) {
    if (line[at] == ' ') {
      at += 1;
      continue;
    }
    final start = at;
    while (at < line.length && line[at] != ' ') {
      at += 1;
    }
    tokens.add((line.substring(start, at), start));
  }
  return tokens;
}

/// Tabs written out as spaces to a stop of eight, so a column means the same
/// thing on the chord line and the words line under it.
String _tabsOut(String line) {
  if (!line.contains('\t')) return line;
  final out = StringBuffer();
  for (final rune in line.runes) {
    if (rune == 9) {
      final next = ((out.length ~/ 8) + 1) * 8;
      out.write(' ' * (next - out.length));
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

String? _cleanFact(String? value) {
  final said = value?.trim();
  if (said == null || said.isEmpty) return null;
  return said;
}

/// A directive value with the two characters that would end it early taken
/// out. The same guard the ChordPro export uses (chord_sheet_export.dart).
String _directiveSafe(String value) =>
    value.replaceAll('}', ')').replaceAll(RegExp(r'\s+'), ' ').trim();

/// A chord name with the bracket that holds it taken out of it.
String _bracketSafe(String chord) =>
    chord.replaceAll('[', '(').replaceAll(']', ')');

const Set<String> _titleNames = <String>{'title', 't'};
const Set<String> _artistNames = <String>{'artist', 'a', 'subtitle', 'st'};
const Set<String> _keyNames = <String>{'key', 'k'};
const Set<String> _tabStart = <String>{'start_of_tab', 'sot'};
const Set<String> _tabEnd = <String>{'end_of_tab', 'eot'};
const Set<String> _headingNames = <String>{
  'comment', 'c', 'comment_italic', 'ci', 'comment_box', 'cb',
  'start_of_chorus', 'soc',
  'start_of_verse', 'sov',
  'start_of_bridge', 'sob',
};
const Set<String> _endNames = <String>{
  'end_of_chorus', 'eoc',
  'end_of_verse', 'eov',
  'end_of_bridge', 'eob',
};

/// What an unnamed block is called, for the readers that open one without
/// saying which it is.
const Map<String, String> _blockNames = <String, String>{
  'start_of_chorus': 'Chorus',
  'soc': 'Chorus',
  'start_of_bridge': 'Bridge',
  'sob': 'Bridge',
};

final RegExp _bracketedHeading = RegExp(r'^\[([^\[\]]{1,60})\]$');
// A string's letter, a bar, and then a fret or a dash — see [_looksLikeTab].
final RegExp _tabLine = RegExp(r'^[eEaAdDgGbB][#b]?\s*[|:]\s*[-–\d]');
// A short name, a colon, and something after it. Whether the something is a
// row of chords is [_labelledChordRow]'s question, not this one's.
final RegExp _labelled = RegExp(r"^([A-Za-z][A-Za-z0-9 '’.#\-]{0,24}):\s*(\S.*)$");
final RegExp _dashRun = RegExp(r'[-–]{5,}');
final RegExp _capoLine =
    RegExp(r'^capo\s*:?\s*(\d{1,2}[^,;]{0,20})$', caseSensitive: false);
final RegExp _statedFact =
    RegExp(r'^(key|tuning)\s*:\s*(.{1,40})$', caseSensitive: false);
final RegExp _leadingMark = RegExp(r'[|(\[:.,*%"“”]');
final RegExp _trailingMark = RegExp(r'[|)\]:.,*%"“”]');
final RegExp _repeatMark =
    RegExp(r'^(x\s*\d{1,2}|\d{1,2}\s*x|N\.?C\.?|-+|~+)$', caseSensitive: false);
