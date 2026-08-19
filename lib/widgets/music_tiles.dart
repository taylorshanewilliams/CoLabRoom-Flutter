import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';
import 'app_surface.dart';
import 'bloom_tap.dart';

class RoomTile extends StatelessWidget {
  const RoomTile({required this.room, required this.onTap, super.key});

  final MusicRoom room;
  final VoidCallback onTap;

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
                const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.muted),
              ],
            ),
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
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class SongTile extends StatelessWidget {
  const SongTile({
    required this.project,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    super.key,
  });

  final SongProject project;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: 'Open ${project.title}',
      child: AppSurface(
        padding: const EdgeInsets.all(12),
        color: selected ? const Color(0xFF0C2341) : AppColors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.music_note_rounded,
                    color: AppColors.cyan,
                    size: 21,
                  ),
                ),
                const Spacer(),
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.arrow_outward_rounded,
                  color: selected ? AppColors.cyan : AppColors.muted,
                  size: 19,
                ),
              ],
            ),
            const Spacer(),
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
            const SizedBox(height: 4),
            Text('${setlist.projectIds.length} ${setlist.projectIds.length == 1 ? 'song' : 'songs'}'),
          ],
        ),
      ),
    );
  }
}
