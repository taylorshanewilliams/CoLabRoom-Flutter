import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

class BloomTap extends StatefulWidget {
  const BloomTap({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.padding = EdgeInsets.zero,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  @override
  State<BloomTap> createState() => _BloomTapState();
}

class _BloomTapState extends State<BloomTap> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || (widget.onTap == null && widget.onLongPress == null)) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: widget.onTap != null || widget.onLongPress != null,
      label: widget.semanticLabel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          boxShadow: _pressed
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x263AD3FF),
                    blurRadius: 38,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: Color(0x242B6FFF),
                    blurRadius: 56,
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: widget.borderRadius,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            splashColor: AppColors.cyan.withValues(alpha: 0.06),
            highlightColor: Colors.transparent,
            borderRadius: widget.borderRadius,
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}
