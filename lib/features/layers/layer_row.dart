import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/multitrack.dart';
import '../../services/take_naming.dart';

/// One part in the list, with the controls that belong to it.
///
/// Shared by the project screen and the local scratch one so the two cannot
/// drift into disagreeing about what a layer looks like or what you can do
/// to it.
///
/// [onGain] and [onNudge] are nullable on purpose rather than absent. On a
/// shared song the volume and timing belong to whoever recorded the part, and
/// the values are still worth *showing* everyone — a disabled slider says
/// "this is where they put it" where a missing one says nothing at all.
class LayerRow extends StatefulWidget {
  const LayerRow({
    required this.take,
    required this.onToggle,
    this.onDelete,
    this.subtitle,
    this.silent = false,
    this.onGain,
    this.onNudge,
    super.key,
  });

  final Take take;
  final String? subtitle;
  final VoidCallback onToggle;
  final ValueChanged<double>? onGain;
  final ValueChanged<int>? onNudge;
  final VoidCallback? onDelete;

  /// This part contributed nothing to the mix — a missing file, or audio that
  /// would not decode. Said out loud, because a part that is in the list and
  /// cannot be heard is the most confusing failure there is: it looks
  /// identical to a bad recording, and the person who made it has no way to
  /// tell which.
  final bool silent;

  @override
  State<LayerRow> createState() => _LayerRowState();
}

class _LayerRowState extends State<LayerRow> {
  /// Where the thumb sits mid-drag.
  ///
  /// Committing on every change would rewrite state and rebuild the whole mix
  /// thirty times across one drag — a pass over every sample of every layer,
  /// per increment. Held here while the finger is down, written once when it
  /// lifts.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final take = widget.take;
    final gain = _dragging ?? take.gain;
    final name = TakeNaming.describe(take);
    final canAdjust = widget.onGain != null && take.enabled;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
      decoration: BoxDecoration(
        color: take.enabled ? AppColors.raised : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: take.enabled
              ? AppColors.cyan.withValues(alpha: 0.25)
              : AppColors.line,
        ),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                onPressed: widget.onToggle,
                tooltip: take.enabled ? 'Mute $name' : 'Unmute $name',
                icon: Icon(
                  take.enabled
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  color: take.enabled ? AppColors.cyan : AppColors.muted,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      style: TextStyle(
                        color: take.enabled ? AppColors.text : AppColors.muted,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (widget.silent)
                      const Text(
                        'Could not be played — try recording it again',
                        style: TextStyle(
                            color: AppColors.orange,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600),
                      )
                    else if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
              if (widget.onNudge != null) ...<Widget>[
                IconButton(
                  onPressed: () => widget.onNudge!(-10),
                  tooltip: 'Nudge $name 10 ms earlier',
                  icon: const Icon(Icons.remove_rounded,
                      size: 18, color: AppColors.muted),
                ),
                IconButton(
                  onPressed: () => widget.onNudge!(10),
                  tooltip: 'Nudge $name 10 ms later',
                  icon: const Icon(Icons.add_rounded,
                      size: 18, color: AppColors.muted),
                ),
              ],
              if (widget.onDelete != null)
                IconButton(
                  onPressed: widget.onDelete,
                  tooltip: 'Delete $name',
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 20, color: Color(0xFFFF718B)),
                ),
            ],
          ),
          Row(
            children: <Widget>[
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 16),
                  ),
                  child: Slider(
                    value: gain.clamp(0.0, 1.5),
                    max: 1.5,
                    divisions: 30,
                    activeColor:
                        take.enabled ? AppColors.cyan : AppColors.muted,
                    inactiveColor: AppColors.line,
                    label: '${(gain * 100).round()}%',
                    // Above 100% deliberately. A vocal sung further from the
                    // phone than the guitar needs lifting, and the mixer
                    // scales the whole mix if the sum overshoots — so pushing
                    // one part up costs headroom, never the take.
                    onChanged: canAdjust
                        ? (value) => setState(() => _dragging = value)
                        : null,
                    onChangeEnd: canAdjust
                        ? (value) {
                            setState(() => _dragging = null);
                            widget.onGain!(value);
                          }
                        : null,
                    semanticFormatterCallback: (value) =>
                        '$name volume ${(value * 100).round()} percent',
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(gain * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: take.enabled ? AppColors.muted : AppColors.line,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks what the part was, in the second after recording stops.
///
/// Dismissable. Somebody who does not care gets a generic name and can rename
/// it later — a sheet that cannot be escaped mid-session is worse than an
/// unnamed part.
Future<({TakePart part, String? performer})?> askWhatThatWas(
  BuildContext context, {
  String? performer,
}) {
  var name = performer ?? '';
  return showModalBottomSheet<({TakePart part, String? performer})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
          18, 0, 18, MediaQuery.of(sheetContext).viewInsets.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'What was that?',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'So the band can tell the parts apart.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Who played it',
              hintText: 'Dylan',
            ),
            onChanged: (value) => name = value,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final part in TakePart.values)
                ActionChip(
                  label: Text(part.label),
                  backgroundColor: AppColors.raised,
                  labelStyle:
                      const TextStyle(color: AppColors.text, fontSize: 13),
                  side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
                  onPressed: () => Navigator.pop(
                    sheetContext,
                    (
                      part: part,
                      performer: name.trim().isEmpty ? null : name.trim(),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(sheetContext),
            child: const Text('Skip'),
          ),
        ],
      ),
    ),
  );
}
