import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../services/audio_analysis_utils.dart';
import 'audio_privacy_note.dart';

/// Asks how much of the analysis to run.
///
/// Full is first and full is the default. Somebody who needs speed will go
/// looking for the other option; somebody who doesn't know the difference
/// should get the better answer without having to have an opinion about
/// source separation.
///
/// Returns null if dismissed, which means "don't analyze" rather than "use
/// the default" — closing a sheet should never start a multi-minute job.
Future<AnalysisDepth?> showAnalysisDepthSheet(
  BuildContext context, {
  required String title,
}) {
  return showModalBottomSheet<AnalysisDepth>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'Both listen to the whole recording. They differ in how much '
              'they work out from it.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 16),
            for (final depth in AnalysisDepth.values) ...<Widget>[
              _DepthOption(
                depth: depth,
                onTap: () => Navigator.pop(sheetContext, depth),
              ),
              const SizedBox(height: 10),
            ],
            // Said where it becomes true, rather than buried in a policy
            // nobody opens. Quiet on purpose — a fact, not a consent gate.
            const AudioJourneyLink(),
          ],
        ),
      ),
    ),
  );
}

class _DepthOption extends StatelessWidget {
  const _DepthOption({required this.depth, required this.onTap});

  final AnalysisDepth depth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recommended = depth == AnalysisDepth.full;
    final accent = recommended ? AppColors.gold : AppColors.cyan;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: recommended ? 0.09 : 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: recommended ? 0.4 : 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  recommended ? Icons.auto_awesome_rounded : Icons.bolt_rounded,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    depth.label,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (recommended)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Recommended',
                      style: TextStyle(
                        color: accent,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              depth.description,
              style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
