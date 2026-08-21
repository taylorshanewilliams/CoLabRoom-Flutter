import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';

/// "Guitar/Keys" rather than "Guitar" — Demucs' "other" stem can't tell
/// those apart (see InstrumentSummary's doc comment), so the label says so.
/// Shared between The Studio's results screen and the existing per-project
/// Analyze Song screen, since both read the same InstrumentSummary shape.
class InstrumentChips extends StatelessWidget {
  const InstrumentChips({required this.instruments, super.key});

  final InstrumentSummary? instruments;

  @override
  Widget build(BuildContext context) {
    final summary = instruments;
    if (summary == null) {
      return const Text('Not available yet', style: TextStyle(color: AppColors.muted, fontSize: 12));
    }
    final entries = <(String, InstrumentPresence?)>[
      ('Vocals', summary.vocals),
      ('Guitar/Keys', summary.guitar),
      ('Bass', summary.bass),
      ('Drums', summary.drums),
    ];
    final present = entries.where((entry) => entry.$2?.present ?? false).toList(growable: false);
    if (present.isEmpty) {
      return const Text('Not available yet', style: TextStyle(color: AppColors.muted, fontSize: 12));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final entry in present)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            child: Text(
              entry.$1,
              style: const TextStyle(color: AppColors.gold, fontSize: 11.5, fontWeight: FontWeight.w800),
            ),
          ),
      ],
    );
  }
}
