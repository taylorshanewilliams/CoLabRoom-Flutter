import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';

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

class _LyricReviewScreenState extends State<LyricReviewScreen> {
  final SongAnalysisService _service = SongAnalysisService();
  late final List<List<TranscriptWord>> _originalLines;
  late final List<TextEditingController> _controllers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _originalLines = _service.groupTranscriptWords(widget.reference.transcriptWords);
    _controllers = _originalLines
        .map((line) => TextEditingController(text: line.map((word) => word.word).join(' ')))
        .toList();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

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
      final words = text.split(RegExp(r'\s+'));
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
          ..showSnackBar(SnackBar(content: Text('Could not save: $error')));
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
                  : const Text('Save', style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Text(
                'These are the words heard in the recording, split into lines by the pauses in the singing. '
                'Fix anything mis-heard, then save to update the Song Sheet and Live Performance.',
                style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                itemCount: _controllers.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            key: Key('review_lyric_line_$index'),
                            controller: _controllers[index],
                            style: const TextStyle(color: AppColors.text),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Line ${index + 1}',
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _removeLine(index),
                          tooltip: 'Remove line',
                          icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
