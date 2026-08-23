import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';

/// The shape of the song: which parts it's built from and the order they
/// come in.
///
/// Deliberately abstract — "Part A", never "Chorus". The analysis can tell
/// that two stretches are the same musical idea; it cannot tell which one is
/// the chorus, and guessing would be worse than staying honest.
///
/// Reads as a form ("A B A B C B") rather than a list of boundaries, because
/// that is how a musician describes a song to another musician. Repeats share
/// a colour and a letter, so the pattern is visible before a single word is
/// read.
class StructureTimeline extends StatelessWidget {
  const StructureTimeline({required this.sections, super.key});

  final List<StructureSection> sections;

  static const _palette = <Color>[
    AppColors.cyan,
    AppColors.gold,
    AppColors.green,
    Color(0xFFB993FF),
    Color(0xFFFF7A7A),
    Color(0xFF7C8CFF),
  ];

  Color _colorFor(StructureSection section) =>
      _palette[section.groupIndex % _palette.length];

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

    // One entry per distinct part, in order of first appearance, with how
    // many times it comes round.
    final playCounts = <int, int>{};
    final firstSeen = <int, StructureSection>{};
    for (final section in sections) {
      playCounts.update(section.groupIndex, (value) => value + 1, ifAbsent: () => 1);
      firstSeen.putIfAbsent(section.groupIndex, () => section);
    }
    final parts = firstSeen.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 40,
            child: Row(
              children: <Widget>[
                for (var i = 0; i < sections.length; i += 1) ...<Widget>[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: math.max(1, sections[i].durationMs),
                    child: Container(
                      color: _colorFor(sections[i]).withValues(alpha: 0.3),
                      alignment: Alignment.center,
                      // FittedBox rather than a fixed size: a short part still
                      // shows its letter instead of a clipped fragment, which
                      // is what made narrow blocks read as noise.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Text(
                            sections[i].label,
                            style: TextStyle(
                              color: _colorFor(sections[i]),
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // The form, spelled out. This is the line a musician would actually
        // say out loud about the song.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            const Text(
              'Form',
              style: TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w800),
            ),
            for (final section in sections)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _colorFor(section).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  section.label,
                  style: TextStyle(
                    color: _colorFor(section),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (final entry in parts)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: <Widget>[
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: _palette[entry.key % _palette.length],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  'Part ${entry.value.label}',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_duration(entry.value.durationMs)} · first at ${_clock(entry.value.startMs)}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ),
                Text(
                  playCounts[entry.key] == 1
                      ? 'once'
                      : '${playCounts[entry.key]}×',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _clock(int ms) {
    final totalSeconds = ms ~/ 1000;
    return '${totalSeconds ~/ 60}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
  }

  String _duration(int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }
}
