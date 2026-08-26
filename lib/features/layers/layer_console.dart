import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/multitrack.dart';
import '../../services/take_naming.dart';

/// The takes as a desk, for when the phone is turned sideways.
///
/// A list is the right shape for reading and the wrong shape for balancing.
/// Deciding whether the harmony is too loud against the lead means comparing
/// them, and comparing two things stacked vertically on a phone means
/// remembering the first one while you scroll to the second. Side by side,
/// the comparison is the picture.
///
/// It also earns the landscape orientation, which until now did nothing here.
/// Eight strips fit across a phone comfortably; past that it scrolls
/// horizontally, which is still a better hand movement than scrolling a
/// column of ninety-pixel rows.
class LayerConsole extends StatelessWidget {
  const LayerConsole({
    required this.takes,
    required this.onToggle,
    required this.onGain,
    this.silentIds = const <String>{},
    super.key,
  });

  final List<Take> takes;
  final void Function(Take) onToggle;

  /// Null for a take somebody else recorded — the fader still shows where
  /// they set it, and will not move.
  final void Function(Take, double)? Function(Take) onGain;

  final Set<String> silentIds;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: ConstrainedBox(
            // At least as wide as the screen, so a band with two takes gets
            // its desk in the middle rather than shoved into the left corner
            // of a landscape phone with nothing beside it.
            constraints: BoxConstraints(
              minWidth: constraints.maxWidth - 24,
              // The strips take the height they are given rather than
              // insisting on their own. They used to add up to a fixed 253
              // pixels — a fader, a button and two lines of label — which is
              // taller than a landscape phone has to spare, and the excess
              // had nowhere to go: this scrolls sideways, not down. The
              // bottom of every strip was cut off by 47 pixels and the name
              // fell out of the box it belonged to.
              minHeight: 0,
              maxHeight: constraints.maxHeight - 16,
            ),
            child: Row(
              mainAxisAlignment: takes.length > 4
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final take in takes)
                  _Strip(
                    take: take,
                    silent: silentIds.contains(take.id),
                    onToggle: () => onToggle(take),
                    onGain: onGain(take),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Strip extends StatefulWidget {
  const _Strip({
    required this.take,
    required this.silent,
    required this.onToggle,
    required this.onGain,
  });

  final Take take;
  final bool silent;
  final VoidCallback onToggle;
  final void Function(Take, double)? onGain;

  @override
  State<_Strip> createState() => _StripState();
}

class _StripState extends State<_Strip> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final take = widget.take;
    final gain = _dragging ?? take.gain;
    final name = TakeNaming.describe(take);
    final canAdjust = widget.onGain != null && take.enabled;

    return Container(
      width: 76,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: take.enabled ? AppColors.raised : AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.silent
              ? AppColors.orange.withValues(alpha: 0.5)
              : take.enabled
                  ? AppColors.cyan.withValues(alpha: 0.25)
                  : AppColors.line,
        ),
      ),
      child: Column(
        children: <Widget>[
          Text(
            '${(gain * 100).round()}%',
            style: TextStyle(
              color: take.enabled ? AppColors.muted : AppColors.line,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          Expanded(
            // The fader takes whatever height is left after the readout, the
            // mute button and the name, rather than claiming a fixed 150 and
            // pushing the rest off the bottom of the phone.
            //
            // A Slider laid on its side. Flutter has no vertical one, and a
            // quarter turn is the whole difference between a list control and
            // a fader — which is the entire point of this view.
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                ),
                child: Slider(
                  value: gain.clamp(0.0, 1.5),
                  max: 1.5,
                  divisions: 30,
                  activeColor: take.enabled ? AppColors.cyan : AppColors.muted,
                  inactiveColor: AppColors.line,
                  onChanged:
                      canAdjust ? (value) => setState(() => _dragging = value) : null,
                  onChangeEnd: canAdjust
                      ? (value) {
                          setState(() => _dragging = null);
                          widget.onGain!(take, value);
                        }
                      : null,
                  semanticFormatterCallback: (value) =>
                      '$name volume ${(value * 100).round()} percent',
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: widget.onToggle,
            visualDensity: VisualDensity.compact,
            tooltip: take.enabled ? 'Mute $name' : 'Unmute $name',
            icon: Icon(
              take.enabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              size: 19,
              color: take.enabled ? AppColors.cyan : AppColors.muted,
            ),
          ),
          SizedBox(
            height: 30,
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: take.enabled ? AppColors.text : AppColors.muted,
                fontSize: 10,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
