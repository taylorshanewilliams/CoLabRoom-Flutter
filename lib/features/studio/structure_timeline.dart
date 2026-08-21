import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';

/// Boundaries only, generic labels — never asserted as Verse/Chorus/Bridge
/// (see StructureSection's doc comment). A same-label block always gets the
/// same color so repeated sections read visually as "this shape again"
/// without claiming to know what that shape actually is.
class StructureTimeline extends StatelessWidget {
  const StructureTimeline({required this.sections, super.key});

  final List<StructureSection> sections;

  static const _palette = <Color>[
    AppColors.gold,
    AppColors.cyan,
    AppColors.green,
    Color(0xFFB993FF),
    Color(0xFFFF7A7A),
    Color(0xFF7C8CFF),
  ];

  @override
  Widget build(BuildContext context) {
    if (sections.isEmpty) {
      return Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: const Text(
          'Structure not detected for this recording',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      );
    }

    final colorByLabel = <String, Color>{};
    for (final section in sections) {
      colorByLabel.putIfAbsent(
        section.label,
        () => _palette[colorByLabel.length % _palette.length],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 34,
            child: Row(
              children: <Widget>[
                for (final section in sections)
                  Expanded(
                    flex: math.max(1, section.endMs - section.startMs),
                    child: Container(
                      color: colorByLabel[section.label]!.withValues(alpha: 0.32),
                      alignment: Alignment.center,
                      child: Text(
                        section.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          color: colorByLabel[section.label],
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: <Widget>[
            for (final section in sections)
              Text(
                section.repeatsSectionLabel != null
                    ? '${section.label} (${_formatMs(section.startMs)}) ↻ repeats ${section.repeatsSectionLabel}'
                    : '${section.label} (${_formatMs(section.startMs)})',
                style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
              ),
          ],
        ),
      ],
    );
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
