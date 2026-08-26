import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';
import 'app_surface.dart';
import 'bloom_tap.dart';

class RoomTile extends StatelessWidget {
  const RoomTile({required this.room, required this.onTap, this.onMore, this.logoBytes, super.key});

  final MusicRoom room;
  final VoidCallback onTap;

  /// When set, shows a small overflow button (rename/delete) instead of the
  /// plain chevron. Left null on read-only previews (e.g. the Home screen's
  /// "My Rooms" strip) where those actions don't apply.
  final VoidCallback? onMore;

  /// Custom logo image bytes for [room], or null to show the default
  /// [MusicRoom.icon] glyph. Left null while the image is still loading —
  /// see [MusicBetaController.roomLogoBytes].
  final Uint8List? logoBytes;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      semanticLabel: 'Open ${room.name}',
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x082B6FFF)],
                    ),
                  ),
                  child: logoBytes != null
                      ? Image.memory(logoBytes!, fit: BoxFit.cover, width: 42, height: 42)
                      : Text(
                          room.icon,
                          style: const TextStyle(fontSize: 23, color: AppColors.cyan),
                        ),
                ),
                const Spacer(),
                if (onMore != null)
                  InkResponse(
                    key: const Key('room_more_button'),
                    onTap: onMore,
                    radius: 18,
                    child: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                  )
                else
                  const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.muted),
              ],
            ),
            // The Spacer above takes whatever room is left over, and the two
            // lines below take exactly what they need. Wrapping them in a
            // Flexible instead made them a second flex child competing with
            // that Spacer for the same slack, so they were handed half of it
            // whether or not the text fitted in half — which is how a set
            // called "Friday Night Set" overflowed its card by five pixels.
            const Spacer(),
            Text(
              room.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 3),
            Text(
              '${room.projects.length} ${room.projects.length == 1 ? 'project' : 'projects'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// How much room a [SongTile] gets — a Room with only a handful of songs
/// can afford the spacious card; a Room with dozens shouldn't force endless
/// scrolling for what's ultimately the same glance-and-tap card, so it
/// steps down automatically as project count grows (see
/// RoomDetailScreen._densityFor).
enum SongTileDensity {
  spacious(mainAxisExtent: 172, iconBox: 40, iconGlyph: 21, iconRadius: 13, padding: 12),
  // cozy/compact previously overflowed by a couple of pixels (title +
  // caption text stays the same fixed font size at every density, so it
  // doesn't shrink along with the icon/padding) — this never surfaced
  // before because the old, higher project-count thresholds meant these
  // two tiers rarely got exercised. A few extra px of mainAxisExtent gives
  // the fixed-size text room regardless of density.
  cozy(mainAxisExtent: 146, iconBox: 32, iconGlyph: 18, iconRadius: 12, padding: 10),
  compact(mainAxisExtent: 116, iconBox: 26, iconGlyph: 15, iconRadius: 10, padding: 8);

  const SongTileDensity({
    required this.mainAxisExtent,
    required this.iconBox,
    required this.iconGlyph,
    required this.iconRadius,
    required this.padding,
  });

  final double mainAxisExtent;
  final double iconBox;
  final double iconGlyph;
  final double iconRadius;
  final double padding;
}

class SongTile extends StatelessWidget {
  const SongTile({
    required this.project,
    required this.onTap,
    this.onLongPress,
    this.onMore,
    this.selected = false,
    this.density = SongTileDensity.spacious,
    this.coverBytes,
    this.unheardTakes = 0,
    super.key,
  });

  final SongProject project;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// When set (and [selected] is false), shows a small overflow button
  /// (rename/delete/select) instead of the plain arrow — mirrors
  /// [RoomTile.onMore].
  final VoidCallback? onMore;
  final bool selected;
  final SongTileDensity density;

  /// Custom cover image bytes for [project], or null to show the default
  /// note-glyph icon — see [RoomTile.logoBytes].
  final Uint8List? coverBytes;

  /// Takes somebody else has added since this person last opened the song.
  ///
  /// The one number on this tile that is about a person rather than a file:
  /// somebody played something and you have not heard it yet. Shown in the
  /// corner where the arrow sits, because it replaces "there is more in here"
  /// with the reason there is more.
  final int unheardTakes;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: unheardTakes > 0
          ? 'Open ${project.title}, $unheardTakes new '
              '${unheardTakes == 1 ? 'take' : 'takes'} you have not heard'
          : 'Open ${project.title}',
      child: AppSurface(
        padding: EdgeInsets.all(density.padding),
        color: selected ? const Color(0xFF0C2341) : AppColors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: density.iconBox,
                  height: density.iconBox,
                  alignment: Alignment.center,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(density.iconRadius),
                  ),
                  child: coverBytes != null
                      ? Image.memory(
                          coverBytes!,
                          fit: BoxFit.cover,
                          width: density.iconBox,
                          height: density.iconBox,
                        )
                      : Icon(
                          Icons.music_note_rounded,
                          color: AppColors.cyan,
                          size: density.iconGlyph,
                        ),
                ),
                const Spacer(),
                if (unheardTakes > 0 && !selected) ...<Widget>[
                  UnheardTakesBadge(count: unheardTakes),
                  const SizedBox(width: 6),
                ],
                if (selected)
                  const Icon(Icons.check_circle_rounded, color: AppColors.cyan, size: 19)
                else if (onMore != null)
                  InkResponse(
                    key: const Key('song_more_button'),
                    onTap: onMore,
                    radius: 18,
                    child: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                  )
                else
                  const Icon(Icons.arrow_outward_rounded, color: AppColors.muted, size: 19),
              ],
            ),
            // See RoomTile: the slack belongs to the Spacer, not to the text.
            const Spacer(),
            Text(
              project.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    // "Contribution" is the database's word for a row in the
                    // lyric document. What a musician sees is lines.
                    '${project.contributions.length} ${project.contributions.length == 1 ? 'line' : 'lines'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (project.hasAudioReference) ...<Widget>[
                  const SizedBox(width: 5),
                  const Icon(Icons.graphic_eq_rounded, size: 13, color: AppColors.muted),
                ],
                if (project.status == SongStatus.completed) ...<Widget>[
                  const SizedBox(width: 4),
                  const Icon(Icons.check_circle_rounded, size: 13, color: AppColors.cyan),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A count of takes nobody has played to this person yet.
///
/// Cyan rather than red. This is somebody sharing their playing, not an
/// error and not a demand — red would make a bandmate's guitar part look
/// like a problem to clear.
class UnheardTakesBadge extends StatelessWidget {
  const UnheardTakesBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.cyan,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.graphic_eq_rounded, size: 11, color: AppColors.ink),
          const SizedBox(width: 3),
          Text(
            // Capped so a long silence cannot widen the tile.
            count > 9 ? '9+' : '$count',
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class SetlistTile extends StatelessWidget {
  const SetlistTile({required this.setlist, required this.onTap, super.key});

  final Setlist setlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      semanticLabel: 'Open ${setlist.name}',
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.queue_music_rounded, color: AppColors.cyan),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
              ],
            ),
            const Spacer(),
            Text(
              setlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 3),
            Text(
              '${setlist.projectIds.length} ${setlist.projectIds.length == 1 ? 'song' : 'songs'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // Matches its sibling tiles. Left at the default body size this
              // line was two points larger than the same line on every other
              // card, which is where the five pixels came from.
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
