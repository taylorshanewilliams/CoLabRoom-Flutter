import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';

/// Lets the user proofread and correct the transcript before it becomes the
/// project's actual lyrics — the direct "Replace project lyrics with this"
/// action on the Analyze screen skips this step for anyone who already
/// trusts the transcript; this is for cleaning up mis-heard words first.
class LyricReviewScreen extends StatefulWidget {
  const LyricReviewScreen({required this.project, required this.reference, super.key});

  final SongProject project;
  final ReferenceTrack reference;

  @override
  State<LyricReviewScreen> createState() => _LyricReviewScreenState();
}

class _LyricReviewScreenState extends State<LyricReviewScreen> {
  final SongAnalysisService _service = SongAnalysisService();
  late final List<TextEditingController> _controllers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final lines = _service.transcriptLyricLines(widget.reference);
    _controllers = (lines.isEmpty ? <String>[''] : lines)
        .map((line) => TextEditingController(text: line))
        .toList();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addLine() {
    setState(() => _controllers.add(TextEditingController()));
  }

  void _removeLine(int index) {
    setState(() {
      _controllers.removeAt(index).dispose();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final lines = _controllers
        .map((controller) => controller.text.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return;
    final hasExisting = widget.project.contributions.any((line) => line.body.trim().isNotEmpty);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save to project lyrics?'),
        content: Text(
          hasExisting
              ? 'This replaces everything currently in the project\'s lyrics with these lines. This can\'t be undone.'
              : 'This writes these lines into the project\'s lyrics.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: AppColors.ink),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final controller = BetaScope.of(context);
      for (final line in widget.project.contributions) {
        await controller.deleteContribution(line);
      }
      await controller.importContributions(
        widget.project,
        lines.map((body) => ContributionDraft(body: body)).toList(growable: false),
      );
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
              onPressed: _saving ? null : _save,
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
                'Fix anything mis-heard, then save to replace the project\'s lyrics.',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 18, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addLine,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add line'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
