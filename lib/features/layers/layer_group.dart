import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/multitrack.dart';
import '../../services/take_naming.dart';

/// A heading over a handful of takes, with the one control that belongs to a
/// group rather than to a take: silence all of it.
///
/// "How does this sound without the guitars" is a question bands ask
/// constantly and a flat list answers badly — muting three takes one at a
/// time and then remembering to unmute exactly those three. One tap, and one
/// tap back.
class LayerGroupHeader extends StatelessWidget {
  const LayerGroupHeader({
    required this.group,
    required this.takes,
    required this.onToggleGroup,
    required this.collapsed,
    required this.onToggleCollapsed,
    super.key,
  });

  final TakeGroup group;
  final List<Take> takes;
  final VoidCallback onToggleGroup;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  bool get _anyOn => takes.any((take) => take.enabled);

  @override
  Widget build(BuildContext context) {
    final on = _anyOn;
    // "3 of 4" rather than "4", because with the group collapsed the count is
    // the only way to see that something inside it is muted.
    final playing = takes.where((take) => take.enabled).length;
    final summary =
        playing == takes.length ? '${takes.length}' : '$playing of ${takes.length}';

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onToggleGroup,
            visualDensity: VisualDensity.compact,
            tooltip: on ? 'Mute the ${group.label.toLowerCase()}' : 'Bring back the ${group.label.toLowerCase()}',
            icon: Icon(
              on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              size: 18,
              color: on ? AppColors.cyan : AppColors.muted,
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: onToggleCollapsed,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    Text(
                      group.label,
                      style: TextStyle(
                        color: on ? AppColors.text : AppColors.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      summary,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5),
                    ),
                    const Spacer(),
                    Icon(
                      collapsed
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      size: 20,
                      color: AppColors.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
