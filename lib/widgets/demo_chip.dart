import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

/// Says an account was seeded rather than joined.
///
/// The app needs a crowd to be judged against: a feed that leans towards
/// people like you, a wildcard every fourth card, taste matching, a list that
/// rotates daily — none of it means anything at four users. Seeding one is
/// the only way to look at any of it before there is a real one.
///
/// Seeding it *quietly* would be a different thing entirely. Three real
/// people use this app, and an App Store reviewer will open it: invented
/// accounts that read as real musicians would mislead all of them, and the
/// testing is worth exactly nothing if it costs that.
///
/// So the label is small, permanent, and everywhere the account is drawn.
class DemoChip extends StatelessWidget {
  const DemoChip({this.compact = false, super.key});

  /// Beside a name in a list, rather than under a heading on a profile.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'A seeded test account, not a real person',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: compact ? 1.5 : 3,
        ),
        decoration: BoxDecoration(
          color: AppColors.orange.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.orange.withValues(alpha: 0.5)),
        ),
        child: Text(
          'DEMO',
          style: TextStyle(
            color: AppColors.orange,
            fontSize: compact ? 8.5 : 9.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.9,
          ),
        ),
      ),
    );
  }
}
