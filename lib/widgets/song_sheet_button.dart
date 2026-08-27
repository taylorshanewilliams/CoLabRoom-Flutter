import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

/// The one button in the app that is a reward.
///
/// Everything else here is a verb you press to get on with something: record,
/// play, mute, send. This one is the end of the journey — the recording is
/// made, the takes are on it, and this is where the app hands back the thing
/// nobody wanted to sit down and work out by ear. It should look like that.
///
/// So: gold rather than cyan, because gold is already what this app uses for
/// the things that cost real machinery. A slow sheen crossing it, because a
/// surface that catches the light reads as valuable and a flat fill reads as
/// a form control. And a page for an icon, since a page is what you get.
///
/// Restrained on purpose despite all that. One moving element, once every few
/// seconds, at low contrast — anything more and it stops looking like a prize
/// and starts looking like an advert for one.
class SongSheetButton extends StatefulWidget {
  const SongSheetButton({
    required this.onPressed,
    this.label = 'Make the song sheet',
    this.subtitle,
    this.busy = false,
    super.key,
  });

  final VoidCallback? onPressed;
  final String label;

  /// The line that says who is doing the work.
  ///
  /// "Make the song sheet" names the thing you get, which is what a
  /// first-time user can picture. It does not say who makes it — read cold it
  /// could be an instruction to go and write one yourself. That belongs here,
  /// where there is room for a sentence.
  final String? subtitle;

  final bool busy;

  @override
  State<SongSheetButton> createState() => _SongSheetButtonState();
}

class _SongSheetButtonState extends State<SongSheetButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    _sheen.repeat();
  }

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    // Somebody who has asked their phone to stop animating things has asked
    // for that here too, however pleased this button is with itself.
    final still = MediaQuery.disableAnimationsOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          enabled: enabled,
          label: widget.subtitle == null
              ? widget.label
              : '${widget.label}. ${widget.subtitle}',
          child: ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                boxShadow: enabled
                    ? const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x55E3B34D),
                          blurRadius: 26,
                          spreadRadius: -6,
                          offset: Offset(0, 6),
                        ),
                      ]
                    : const <BoxShadow>[],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: enabled ? widget.onPressed : null,
                    child: Ink(
                      height: 58,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: enabled
                              ? const <Color>[
                                  Color(0xFFF0C766),
                                  AppColors.gold,
                                  Color(0xFFC9922F),
                                ]
                              : const <Color>[
                                  AppColors.raised,
                                  AppColors.raised,
                                ],
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          if (enabled && !still)
                            AnimatedBuilder(
                              animation: _sheen,
                              builder: (context, _) => _Sheen(at: _sheen.value),
                            ),
                          if (widget.busy)
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.ink),
                            )
                          else
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                Icon(
                                  Icons.article_rounded,
                                  size: 20,
                                  color: enabled
                                      ? AppColors.ink
                                      : AppColors.muted,
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    widget.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: enabled
                                          ? AppColors.ink
                                          : AppColors.muted,
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.subtitle != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            widget.subtitle!,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
        ],
      ],
    );
  }
}

/// A band of light crossing the face of the button.
///
/// Off-screen for most of each cycle: it sweeps, then waits. A sheen that
/// never stops is a loading spinner, and this button is not loading.
class _Sheen extends StatelessWidget {
  const _Sheen({required this.at});

  final double at;

  @override
  Widget build(BuildContext context) {
    // The pass takes the first third of the cycle; the rest is the pause.
    final travel = (at / 0.34).clamp(0.0, 1.0);
    if (at > 0.34) return const SizedBox.shrink();
    return FractionallySizedBox(
      widthFactor: 1,
      heightFactor: 1,
      child: ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          final centre = -0.4 + travel * 1.8;
          return LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: const <Color>[
              Color(0x00FFFFFF),
              Color(0x59FFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: <double>[
              (centre - 0.16).clamp(0.0, 1.0),
              centre.clamp(0.0, 1.0),
              (centre + 0.16).clamp(0.0, 1.0),
            ],
          ).createShader(rect);
        },
        child: const SizedBox.expand(
          child: ColoredBox(color: Color(0x01FFFFFF)),
        ),
      ),
    );
  }
}
