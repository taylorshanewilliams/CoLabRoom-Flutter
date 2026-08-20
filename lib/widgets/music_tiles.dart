import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';
import 'app_surface.dart';
import 'bloom_tap.dart';

class RoomTile extends StatelessWidget {
  const RoomTile({required this.room, required this.onTap, this.onMore, super.key});

  final MusicRoom room;
  final VoidCallback onTap;

  /// When set, shows a small overflow button (rename/delete) instead of the
  /// plain chevron. Left null on read-only previews (e.g. the Home screen's
  /// "My Rooms" strip) where those actions don't apply.
  final VoidCallback? onMore;

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
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x082B6FFF)],
                    ),
                  ),
                  child: Text(
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
            const Spacer(),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
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
  cozy(mainAxisExtent: 138, iconBox: 32, iconGlyph: 18, iconRadius: 12, padding: 10),
  compact(mainAxisExtent: 108, iconBox: 26, iconGlyph: 15, iconRadius: 10, padding: 8);

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

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: 'Open ${project.title}',
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
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(density.iconRadius),
                  ),
                  child: Icon(
                    Icons.music_note_rounded,
                    color: AppColors.cyan,
                    size: density.iconGlyph,
                  ),
                ),
                const Spacer(),
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
            const Spacer(),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${project.contributions.length} contributions',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
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
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    setlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${setlist.projectIds.length} ${setlist.projectIds.length == 1 ? 'song' : 'songs'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
