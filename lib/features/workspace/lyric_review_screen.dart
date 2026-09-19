import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';
import '../../services/song_language.dart';
import '../../widgets/text_measures.dart';
import '../../widgets/note_that_fits.dart';

/// Lets the user proofread and correct the transcript before it becomes the
/// project's actual lyrics — the direct "Replace project lyrics with this"
/// action on the Analyze screen skips this step for anyone who already
/// trusts the transcript; this is for cleaning up mis-heard words first.
///
/// Saving here overwrites the stored transcript itself (ReferenceTrack.
/// transcriptWords/transcriptText), not project.contributions — the Song
/// Sheet and Live Performance's "Song Sheet" source both read from the
/// transcript, never from the manual workspace (see
/// musician_sheet_logic.dart's buildMusicianSheetLines), so that's the only
/// place an edit here can land and actually be reflected there. Pushing a
/// (now-corrected) transcript into the manual workspace afterward is a
/// separate, explicit step — "Replace project lyrics with this".
class LyricReviewScreen extends StatefulWidget {
  const LyricReviewScreen({required this.project, required this.reference, super.key});

  final SongProject project;
  final ReferenceTrack reference;

  @override
  State<LyricReviewScreen> createState() => _LyricReviewScreenState();
}

/// The one labelled action in the bar across the top. Named so the bar can be
/// measured with the same style it draws.
const TextStyle _saveStyle =
    TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700);

class _LyricReviewScreenState extends State<LyricReviewScreen> {
  final SongAnalysisService _service = SongAnalysisService();
  late final List<List<TranscriptWord>> _originalLines;
  late final List<TextEditingController> _controllers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _originalLines = _service.groupTranscriptWords(widget.reference.transcriptWords);
    // Written the way the song is written (0163): a space between words, and
    // nothing between two characters of a script that does not space them.
    // Correcting a Chinese line spaced out into single characters is reading
    // it in a form nobody writes it in (review, 18 September 2026).
    _controllers = _originalLines
        .map((line) => TextEditingController(
              text: joinLyricUnits(
                line.map((word) => word.word).toList(growable: false),
                widget.project.language,
              ),
            ))
        .toList();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Takes a line out, and lets go of it.
  ///
  /// [dispose] above only reaches the controllers still in the list, so a
  /// removed line has to be disposed here or it is never disposed at all.
  /// It is safe to do it at this moment: the fields are positional, so the
  /// rebuild hands every element below this one its neighbour's controller
  /// and drops the last element, and the only thing either does with the
  /// controller that has gone is `removeListener`, which a disposed
  /// [ChangeNotifier] allows by design. Asserted in
  /// the_lyric_review_names_its_lines_test.dart, including for a line that
  /// had the keyboard on it when it was removed.
  void _removeLine(int index) {
    setState(() {
      _originalLines.removeAt(index);
      _controllers.removeAt(index).dispose();
    });
  }

  /// Rebuilds a flat, timed word list from the (possibly edited) line texts:
  /// each line keeps its original start/end span from the transcript, and
  /// its words — however many there now are — are spread evenly across
  /// that span. Exact per-word timestamps from the original recording are
  /// lost for any line whose word count changed, but the line still lands
  /// in the right place in the song, which is what scrolling/highlighting
  /// actually depends on.
  List<TranscriptWord> _rebuildWords() {
    final result = <TranscriptWord>[];
    for (var i = 0; i < _originalLines.length; i += 1) {
      final original = _originalLines[i];
      final text = _controllers[i].text.trim();
      if (text.isEmpty) continue;
      // Split back into the pieces the song is read in, which is splitting on
      // white space in every language that has any — and by character in one
      // that does not, where splitting on white space would hand the whole
      // corrected line back as a single word with a single timestamp.
      final words = lyricUnits(text, language: widget.project.language);
      if (words.isEmpty) continue;
      final startMs = original.first.startMs;
      final endMs = math.max(original.last.endMs, startMs + 120);
      final span = endMs - startMs;
      final step = span / words.length;
      for (var w = 0; w < words.length; w += 1) {
        result.add(TranscriptWord(
          word: words[w],
          startMs: (startMs + step * w).round(),
          endMs: (startMs + step * (w + 1)).round(),
        ));
      }
    }
    return result;
  }

  Future<void> _save() async {
    if (_saving) return;
    final words = _rebuildWords();
    if (words.isEmpty) return;
    setState(() => _saving = true);
    try {
      await _service.updateTranscript(projectId: widget.project.id, words: words);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showNote('Could not save: $error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        title: const Text('Review lyrics'),
        backgroundColor: AppColors.deepNavy,
        // As tall as the Save label, rather than Material's 56. An action's
        // words are not held to any ceiling the way a title's are, so at the
        // largest text sizes this one lost its bottom — silently, because a
        // toolbar clips rather than overflows — on the only button that keeps
        // the corrections somebody has just typed.
        toolbarHeight: appBarHighEnoughFor(
          context,
          actions: const <TextStyle>[_saveStyle],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: TextButton(
              key: const Key('save_reviewed_lyrics'),
              onPressed: _saving || _controllers.isEmpty ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
                    )
                  : const Text('Save', style: _saveStyle),
            ),
          ),
        ],
      ),
      body: SafeArea(
        // The sentence scrolls with the lines it is about, as the first thing
        // in the list rather than as an unflexed child of a Column above it.
        //
        // Every Musician, Same Song, 17 September 2026: the phone's own text
        // size is honoured, never clamped. Held out of the scroll, that
        // sentence took whatever height its words wanted: at the largest text
        // size it wrapped to taller than the screen, the body overflowed by
        // 376, and the correction fields — the entire point of the screen —
        // were off the bottom of it with no way to reach them.
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          itemCount: _controllers.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 12),
                child: Text(
                  'These are the words heard in the recording, split into lines by the pauses in the singing. '
                  'Fix anything mis-heard, then save to update the Song Sheet and Live Performance.',
                  style:
                      TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
                ),
              );
            }
            final line = index - 1;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    // The line says which line it is. Every field here opens
                    // with the mis-heard words already in it, and an
                    // `InputDecorator` stops building `hintText` the moment
                    // there is any text — so the hint below, which was this
                    // field's only name, was never built and a reader heard
                    // field after field read its words out with nothing
                    // saying which of them it was on (#411's own report, 18
                    // September 2026).
                    //
                    // The name only, with no role beside it, for the reason
                    // the song editor gives: two semantics configurations
                    // claiming `isTextField` cannot merge, so repeating it
                    // would split this into an empty "Line 3" node above the
                    // real one. A plain label folds into the field's own node
                    // and adds no height at all, which `labelText` would.
                    //
                    // The hint stays as well, because it is what the screen
                    // shows on a line somebody has emptied. On that one line
                    // it folds in and the name is heard twice; on every other
                    // line it is not built and this is the only name there is.
                    child: Semantics(
                      label: 'Line ${line + 1}',
                      child: TextField(
                        key: Key('review_lyric_line_$line'),
                        controller: _controllers[line],
                        style: const TextStyle(color: AppColors.text),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Line ${line + 1}',
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _removeLine(line),
                    // Which line it removes. A column of buttons that all say
                    // "Remove line" is one a reader cannot choose from.
                    tooltip: 'Remove line ${line + 1}',
                    icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
