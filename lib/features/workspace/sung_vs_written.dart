import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/continuous_song_editor.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/services/song_analysis_service.dart';

/// One word of a line, and whether the other side has it too.
class ComparedWord {
  const ComparedWord(this.text, {required this.shared});

  /// The word as it was written or transcribed, punctuation and all.
  final String text;

  /// Whether this word is on both sides. Always true for a token with no
  /// letters or digits in it — a dash on its own, a lone comma — which is not
  /// a word and cannot differ.
  final bool shared;
}

/// One row of the comparison: a written line and what was sung at it, either
/// of which can be missing.
class SungWrittenLine {
  const SungWrittenLine({
    required this.line,
    required this.writtenWords,
    required this.sungWords,
  });

  /// The typed line, or null for something sung that is not on the page.
  final Contribution? line;
  final List<ComparedWord> writtenWords;
  final List<ComparedWord> sungWords;

  String get written => writtenWords.map((word) => word.text).join(' ');

  /// What was sung, as the transcriber wrote it down — the same text "Fill
  /// in my lyrics from the Song Sheet" writes, so a line taken across reads
  /// the way the page would have read had the whole sheet been taken.
  String get sung => sungWords.map((word) => word.text).join(' ');

  bool get onThePage => line != null;
  bool get wasSung => sungWords.isNotEmpty;

  /// Both sides present, and every word on both of them.
  bool get readsTheSame =>
      onThePage &&
      wasSung &&
      writtenWords.every((word) => word.shared) &&
      sungWords.every((word) => word.shared);

  /// Both sides present, and at least one word on only one of them.
  bool get differs => onThePage && wasSung && !readsTheSame;
}

/// A word as it is compared: lower case, letters and digits only.
///
/// "Don't," and "dont" are the same word to this, and so are "Hold" and
/// "hold". The transcriber punctuates and capitalises as it likes, and a
/// comparison that lit up every comma would be a comparison of its habits.
String comparableWord(String word) =>
    word.toLowerCase().replaceAll(_notAWordCharacter, '');

final RegExp _notAWordCharacter = RegExp(r'[^\p{L}\p{N}]', unicode: true);
final RegExp _whitespace = RegExp(r'\s+');

/// What was sung, beside what was written: every typed line in page order
/// with what the recording says at it, and the sung phrases that are on no
/// line in their places between.
///
/// A song holds two sets of words: the transcript of what the recording says,
/// with a time on every word, and the lines somebody typed. The sheet reads
/// from the first and the writing space from the second, and nothing put them
/// side by side — so a writer who sang "cat" over a page that says "dog" had
/// to notice on their own (Every Musician, Same Song, 17 September 2026,
/// slice 37, finishing step 4 of "A Second Pair of Ears").
///
/// This is a comparison, not a mark. It says which words are on both sides
/// and which are on one; it never counts them, scores them or calls a side
/// right. Punctuation and case are not differences.
///
/// The pairing is by the words themselves, not by time. A typed line has no
/// timing of its own — lyric cues stopped being written when analysis stopped
/// aligning to typed lines (see SongAnalysisService.analyze) — and Perform's
/// even spread of the lines across the recording is a place to scroll to, not
/// a fact to compare a line against. So the two runs of words are aligned by
/// the longest run they have in common, each typed line takes the sung words
/// aligned to its own, and a sung word aligned to nothing goes with the line
/// it was sung in the same breath as. A breath with nothing on the page in it
/// is shown in place, as sung; a typed line with nothing sung against it is
/// shown as written. Where those two fall together — a line rewritten after
/// the recording — they are paired in order, so the old words sit beside the
/// new ones and can be taken across.
///
/// Empty when the song has no typed words or no transcript: with one side
/// missing there is nothing to put beside anything, and the sheet already
/// says where the words are when the page is empty.
List<SungWrittenLine> pairSungWithWritten(
  SongProject project,
  SongAnalysisBundle bundle,
) {
  final lines = visibleMusicianLyrics(project);
  final transcript =
      bundle.reference?.transcriptWords ?? const <TranscriptWord>[];
  if (lines.isEmpty || transcript.isEmpty) return const <SungWrittenLine>[];

  // Every typed word, remembering its line.
  final writtenByLine = <List<_Word>>[
    for (final line in lines)
      <_Word>[
        for (final token
            in displayContributionBody(line.body).trim().split(_whitespace))
          if (token.isNotEmpty) _Word(token),
      ],
  ];
  final written = <_Word>[];
  final lineOf = <int>[];
  for (var index = 0; index < writtenByLine.length; index += 1) {
    for (final word in writtenByLine[index]) {
      written.add(word);
      lineOf.add(index);
    }
  }
  // Every sung word, remembering its breath: the same grouping the sheet
  // draws its lines from and "Fill in my lyrics" writes.
  final sung = <_Word>[];
  final breathOf = <int>[];
  final breaths = groupTranscriptWordsIntoLines(transcript);
  for (var index = 0; index < breaths.length; index += 1) {
    for (final word in breaths[index]) {
      final text = word.word.trim();
      if (text.isEmpty) continue;
      sung.add(_Word(text));
      breathOf.add(index);
    }
  }
  if (written.isEmpty || sung.isEmpty) return const <SungWrittenLine>[];

  final (writtenMatch, sungMatch) = _align(written, sung);
  for (var i = 0; i < written.length; i += 1) {
    written[i].shared = writtenMatch[i] >= 0;
  }
  for (var j = 0; j < sung.length; j += 1) {
    sung[j].shared = sungMatch[j] >= 0;
  }

  // Which line each sung word goes with: the line of the typed word it was
  // aligned to, or, for a word aligned to nothing, the line of the nearest
  // aligned word sung in the same breath — the one before it first, then the
  // one after. A word in a breath with no aligned word in it is on no line.
  final nextAligned = List<int>.filled(sung.length, -1);
  for (var j = sung.length - 1, next = -1; j >= 0; j -= 1) {
    nextAligned[j] = next;
    if (sungMatch[j] >= 0) next = j;
  }
  final owner = List<int>.filled(sung.length, -1);
  for (var j = 0; j < sung.length; j += 1) {
    if (sungMatch[j] >= 0) owner[j] = lineOf[sungMatch[j]];
  }
  // For a word on no line: the line it comes after (-1 for before the first),
  // and whether it falls between two lines rather than inside one. The
  // aligned words' lines are all settled above first, because the word after
  // is looked at as well as the word before.
  final after = List<int>.filled(sung.length, -1);
  final betweenLines = List<bool>.filled(sung.length, true);
  var lastAligned = -1;
  for (var j = 0; j < sung.length; j += 1) {
    if (sungMatch[j] >= 0) {
      lastAligned = j;
      continue;
    }
    final before = lastAligned;
    final next = nextAligned[j];
    if (before >= 0 && breathOf[before] == breathOf[j]) {
      owner[j] = owner[before];
    } else if (next >= 0 && breathOf[next] == breathOf[j]) {
      owner[j] = owner[next];
    } else {
      after[j] = before < 0 ? -1 : owner[before];
      betweenLines[j] =
          before < 0 || next < 0 || owner[before] != owner[next];
    }
  }

  // The sung words each line took, in the order they were sung, and the
  // phrases on no line — one per breath — by the line they come after.
  final taken = List<List<int>>.generate(lines.length, (_) => <int>[]);
  final unwritten = <int, List<_Phrase>>{};
  for (var j = 0; j < sung.length; j += 1) {
    if (owner[j] >= 0) {
      taken[owner[j]].add(j);
      continue;
    }
    final phrases = unwritten.putIfAbsent(after[j], () => <_Phrase>[]);
    if (phrases.isNotEmpty && phrases.last.breath == breathOf[j]) {
      phrases.last.words.add(sung[j]);
    } else {
      phrases.add(_Phrase(breathOf[j], <_Word>[sung[j]], betweenLines[j]));
    }
  }

  // Page order. Lines nothing was sung at and phrases on no line wait in a
  // run until the next line that has both, then pair off in order: the
  // first waiting line with the first waiting phrase, and so on. What is
  // left over stays on its own.
  final rows = <SungWrittenLine>[];
  final unsungLines = <int>[];
  final unwrittenPhrases = <_Phrase>[];
  void flush() {
    final pairs = math.min(unsungLines.length, unwrittenPhrases.length);
    for (var k = 0; k < pairs; k += 1) {
      rows.add(_pairedInOrder(
        lines[unsungLines[k]],
        writtenByLine[unsungLines[k]],
        unwrittenPhrases[k].words,
      ));
    }
    for (var k = pairs; k < unwrittenPhrases.length; k += 1) {
      rows.add(_sungOnly(unwrittenPhrases[k].words));
    }
    for (var k = pairs; k < unsungLines.length; k += 1) {
      rows.add(SungWrittenLine(
        line: lines[unsungLines[k]],
        writtenWords: _compared(writtenByLine[unsungLines[k]]),
        sungWords: const <ComparedWord>[],
      ));
    }
    unsungLines.clear();
    unwrittenPhrases.clear();
  }

  for (final phrase in unwritten[-1] ?? const <_Phrase>[]) {
    unwrittenPhrases.add(phrase);
  }
  for (var index = 0; index < lines.length; index += 1) {
    if (taken[index].isEmpty) {
      unsungLines.add(index);
      continue;
    }
    flush();
    rows.add(SungWrittenLine(
      line: lines[index],
      writtenWords: _compared(writtenByLine[index]),
      sungWords: _compared(<_Word>[for (final j in taken[index]) sung[j]]),
    ));
    for (final phrase in unwritten[index] ?? const <_Phrase>[]) {
      // Sung in a breath of its own in the middle of this line: shown as
      // sung, straight after the line, and never paired with a later line
      // it was not sung anywhere near.
      if (phrase.betweenLines) {
        unwrittenPhrases.add(phrase);
      } else {
        rows.add(_sungOnly(phrase.words));
      }
    }
  }
  flush();
  return rows;
}

/// A line nothing was aligned to, beside a phrase on no line: compared on
/// their own, so a word they do share still reads as shared.
SungWrittenLine _pairedInOrder(
  Contribution line,
  List<_Word> written,
  List<_Word> sung,
) {
  final (writtenMatch, sungMatch) = _align(written, sung);
  for (var i = 0; i < written.length; i += 1) {
    written[i].shared = writtenMatch[i] >= 0;
  }
  for (var j = 0; j < sung.length; j += 1) {
    sung[j].shared = sungMatch[j] >= 0;
  }
  return SungWrittenLine(
    line: line,
    writtenWords: _compared(written),
    sungWords: _compared(sung),
  );
}

SungWrittenLine _sungOnly(List<_Word> words) => SungWrittenLine(
      line: null,
      writtenWords: const <ComparedWord>[],
      sungWords: _compared(words),
    );

List<ComparedWord> _compared(List<_Word> words) => <ComparedWord>[
      for (final word in words)
        ComparedWord(word.text, shared: word.shared || word.key.isEmpty),
    ];

/// The longest run of words the two sides have in common, in order: for each
/// word on one side, the index of the word it lines up with on the other, or
/// -1 for a word on one side only.
///
/// Counted from the end so the walk that reads the answer back runs forward
/// through the song and takes the earliest way of lining up; on a tie it
/// passes over a typed word rather than a sung one. Cells are sixteen-bit,
/// which holds any song: the count in a cell is at most the shorter side's
/// length, and a transcript of sixty-five thousand words is six hours of
/// singing.
(List<int>, List<int>) _align(List<_Word> written, List<_Word> sung) {
  final n = written.length;
  final m = sung.length;
  final longest = List<Uint16List>.generate(n + 1, (_) => Uint16List(m + 1));
  for (var i = n - 1; i >= 0; i -= 1) {
    final key = written[i].key;
    final row = longest[i];
    final below = longest[i + 1];
    for (var j = m - 1; j >= 0; j -= 1) {
      row[j] = key.isNotEmpty && key == sung[j].key
          ? below[j + 1] + 1
          : math.max(below[j], row[j + 1]);
    }
  }
  final writtenMatch = List<int>.filled(n, -1);
  final sungMatch = List<int>.filled(m, -1);
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    final key = written[i].key;
    if (key.isNotEmpty && key == sung[j].key) {
      writtenMatch[i] = j;
      sungMatch[j] = i;
      i += 1;
      j += 1;
    } else if (longest[i + 1][j] >= longest[i][j + 1]) {
      i += 1;
    } else {
      j += 1;
    }
  }
  return (writtenMatch, sungMatch);
}

class _Word {
  _Word(this.text) : key = comparableWord(text);

  final String text;
  final String key;
  bool shared = false;
}

/// One breath's worth of sung words that are on no line.
class _Phrase {
  _Phrase(this.breath, this.words, this.betweenLines);

  final int breath;
  final List<_Word> words;

  /// Whether the breath fell between two lines, or inside one — sung between
  /// two words of the same line, in a breath of its own.
  final bool betweenLines;
}
