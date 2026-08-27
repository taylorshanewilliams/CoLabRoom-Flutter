import 'package:colabroom/features/workspace/music_reference_sheets.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';

/// A "physical paper" chord+lyric sheet — chords sit directly above the word
/// they land on. Deliberately takes already-built [lines] rather than a
/// SongProject/SongAnalysisBundle: the per-project Song Sheet and The
/// Studio's pre-project drafts both need this exact rendering, but only one
/// of them has a project to wrap the data in (see transcriptSheetLines in
/// musician_sheet_logic.dart, which both callers build [lines] from).
class MusicianSongSheet extends StatelessWidget {
  const MusicianSongSheet({
    required this.title,
    required this.lines,
    required this.musicalKey,
    required this.transpose,
    required this.fontScale,
    required this.showChords,
    this.editableChords = false,
    this.onEditChord,
    this.onAddChord,
    super.key,
  });

  final String title;
  final List<MusicianSheetLine> lines;
  final String? musicalKey;
  final int transpose;
  final double fontScale;
  final bool showChords;
  final bool editableChords;
  final MusicianChordTap? onEditChord;
  final MusicianWordTap? onAddChord;

  @override
  Widget build(BuildContext context) {
    final key = musicalKey;
    final approximate = lines.any((line) => line.approximateTiming);
    return Container(
      key: const Key('musician_song_sheet'),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAEC),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: editableChords
              ? const Color(0x66197A74)
              : const Color(0x1A2A231B),
          width: editableChords ? 1.4 : 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 15),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: TextStyle(
                            color: const Color(0xFF241E18),
                            fontSize: 23 * fontScale,
                            height: 1.08,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.55,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: <Widget>[
                            Text(
                              'COLABROOM SONG SHEET',
                              style: TextStyle(
                                color: const Color(0xFF7A6C5A),
                                fontSize: 8.5 * fontScale,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4,
                              ),
                            ),
                            if (editableChords) ...<Widget>[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x16197A74),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Text(
                                  'EDITING CHORDS',
                                  style: TextStyle(
                                    color: Color(0xFF197A74),
                                    fontSize: 7.5,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (key != null && key.trim().isNotEmpty)
                    // The badge is a tap target, not decoration: the key is
                    // the one fact on the sheet that answers a question the
                    // reader actually has — which notes, which chords, and
                    // where to put the capo.
                    GestureDetector(
                      key: const Key('song_sheet_key_badge'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showKeyReference(
                        context,
                        transposeChord(key, transpose),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0E8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: <Widget>[
                            const Text(
                              'KEY',
                              style: TextStyle(
                                color: Color(0xFF667263),
                                fontSize: 7.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                            // Underlined like the chords, and for the same
                            // reason: a badge reads as a label, and nobody
                            // taps a label.
                            Text(
                              transposeChord(key, transpose),
                              style: TextStyle(
                                color: const Color(0xFF244A37),
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                decoration: TextDecoration.underline,
                                decorationStyle: TextDecorationStyle.dotted,
                                decorationColor: const Color(0xFF244A37)
                                    .withValues(alpha: 0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x142A231B)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: lines.isEmpty
                  ? Text(
                      'Nothing to show yet — analyze a recording with either singing or a clear instrument track.',
                      style: TextStyle(
                        color: const Color(0xFF6D6254),
                        fontSize: 13 * fontScale,
                        height: 1.45,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final line in lines)
                          if (line.section)
                            MusicianSectionLine(
                              line: line,
                              fontScale: fontScale,
                            )
                          else
                            MusicianChordLyricLine(
                              line: line,
                              transpose: transpose,
                              fontScale: fontScale,
                              showChords: showChords,
                              editable: editableChords,
                              onEditChord: onEditChord,
                              onAddChord: onAddChord,
                            ),
                        if (approximate) ...<Widget>[
                          const SizedBox(height: 16),
                          const Divider(
                            height: 1,
                            color: Color(0x142A231B),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Some chord positions use guided timing because the sung-word match was incomplete. You can still correct every chord and move it to the right word.',
                            style: TextStyle(
                              color: Color(0xFF8A7A66),
                              fontSize: 9.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
