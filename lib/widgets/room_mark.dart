import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import 'player_face.dart';

/// A room, as a mark: its own picture, or its initials.
///
/// Taylor, on the first Messages tab: "the cheesy cheap looking emojis that
/// we had removed from the app are back though on room labels". They were
/// the `icon` column, which the rest of the app stopped drawing months ago
/// -- the songs screen draws a room's logo when it has one and nothing when
/// it does not, and the room screen draws the logo or an empty circle that
/// asks for one. A list of threads needs *something* to scan by, so this
/// draws the picture the room was given, and otherwise the room's initials
/// on the same gradient the room screen uses. Never the glyph.
///
/// Tappable when the caller has somewhere for a tap to go -- the room's
/// thread uses it as the way to give the room a picture.
class RoomMark extends StatelessWidget {
  const RoomMark({
    required this.name,
    this.logo,
    this.size = 42,
    this.onTap,
    this.tooltip,
    super.key,
  });

  final String name;
  final Uint8List? logo;
  final double size;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final initials = PlayerFace.initialsFor(name);
    final mark = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: const RadialGradient(
          colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x142B6FFF)],
        ),
        border: Border.all(color: AppColors.blue.withValues(alpha: 0.35)),
      ),
      child: logo != null
          ? Image.memory(logo!, fit: BoxFit.cover, width: size, height: size)
          : Text(
              initials,
              key: const Key('room_mark_initials'),
              style: TextStyle(
                color: AppColors.text,
                fontSize: size * 0.36,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
    );
    final labelled = Semantics(
      label: logo != null ? '$name, its picture' : '$name, no picture yet',
      child: tooltip == null ? mark : Tooltip(message: tooltip!, child: mark),
    );
    if (onTap == null) return labelled;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size * 0.3),
      child: labelled,
    );
  }
}
