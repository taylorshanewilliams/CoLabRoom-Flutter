import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/bloom_tap.dart';
import '../../widgets/music_tiles.dart';
import '../rooms/room_detail_screen.dart';
import '../songs/song_search.dart';
import '../workspace/song_workspace_screen.dart';
import 'new_song_flow.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.displayName,
    required this.onSeeSongs,
    required this.onOpenAccount,
    required this.onOpenNotifications,
    super.key,
  });

  final String displayName;
  final VoidCallback onSeeSongs;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenNotifications;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    // Songs, not Rooms. Coming back to the app almost always means returning
    // to something you were already writing, and a Room is a container you
    // then have to open to get at the actual work.
    final recentSongs = allSongsByRecency(controller.rooms).take(4).toList(growable: false);
    final recentRooms = (List<MusicRoom>.from(controller.rooms)
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
        .take(4)
        .toList(growable: false);
    // Pending invitations need action, so they count toward the badge
    // alongside unread activity — both now live in the same inbox.
    final inboxCount = controller.unreadNotificationCount + controller.invites.length;
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final initials = words.isEmpty
        ? 'CR'
        : words.length == 1
            ? words.first.substring(0, 1).toUpperCase()
            : '${words.first.substring(0, 1)}${words.last.substring(0, 1)}'.toUpperCase();

    Future<void> startSong() async {
      final project = await showNewSongFlow(context, controller);
      if (project != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => SongWorkspaceScreen(projectId: project.id)),
        );
      }
    }

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 8),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                const BrandMark(),
                const Spacer(),
                Semantics(
                  button: true,
                  label: 'Notifications',
                  child: InkResponse(
                    onTap: onOpenNotifications,
                    radius: 24,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          const Icon(Icons.notifications_outlined, color: AppColors.text, size: 26),
                          if (inboxCount > 0)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.error,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  inboxCount > 9 ? '9+' : '$inboxCount',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: 'Account',
                  child: InkResponse(
                    onTap: onOpenAccount,
                    radius: 28,
                    containedInkWell: true,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: <Color>[AppColors.blue, Color(0xFF124A80)]),
                        boxShadow: <BoxShadow>[
                          BoxShadow(color: Color(0x242B6FFF), blurRadius: 24),
                        ],
                      ),
                      child: Text(initials, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 23, 18, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // One action, straight to naming the song. This used to be a
                // card labelled "Music" that opened a picker with exactly one
                // option — a tap that taught nothing and delayed the thing
                // the person came to do.
                BloomTap(
                  key: const Key('home_new_song'),
                  onTap: startSong,
                  semanticLabel: 'Start a new song',
                  borderRadius: BorderRadius.circular(19),
                  child: SizedBox(
                    height: 84,
                    child: AppSurface(
                      child: Row(
                        children: <Widget>[
                          const _ProjectMark(icon: Icons.music_note_rounded),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Text(
                                  'Start a song',
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Write, record, and analyze',
                                  style: TextStyle(
                                    color: AppColors.muted,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (recentSongs.isNotEmpty) ...<Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 26, 18, 10),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: <Widget>[
                  Text('Jump back in', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  TextButton(onPressed: onSeeSongs, child: const Text('All songs  ›')),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
            sliver: SliverList.separated(
              itemCount: recentSongs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = recentSongs[index];
                return _RecentSongRow(
                  title: entry.project.title,
                  subtitle: '${entry.room.icon}  ${entry.room.name}',
                  hasRecording: entry.project.hasAudioReference,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SongWorkspaceScreen(projectId: entry.project.id),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 12),
          sliver: SliverToBoxAdapter(
            // Making a Room used to be reachable only by starting a song and
            // answering "where should this live" — so a Room you wanted for
            // its own sake, a band or a set of people, could only be created
            // as a side effect of writing something. There *was* a button for
            // it, on a Rooms screen that stopped being a destination and took
            // the button down with it.
            //
            // This is the Rooms surface now, so the action belongs here.
            // Expanded on the title rather than a Spacer so a long heading
            // ellipsizes instead of shoving the button off the edge.
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Your Rooms',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(onPressed: onSeeSongs, child: const Text('See all  ›')),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
                  onPressed: () => showCreateRoomDialog(context, controller),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New Room'),
                ),
              ],
            ),
          ),
        ),
        if (recentRooms.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
            sliver: SliverToBoxAdapter(
              // "Your Rooms will appear here" was a dead end. The one screen
              // where somebody new is certain to be looking for Rooms told
              // them to wait for one to turn up.
              child: AppSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'A Room is a band, a project, or just the people you write '
                      'with. Songs live in one, and it decides who can see them.',
                      style: TextStyle(color: AppColors.muted, height: 1.45, fontSize: 12.5),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => showCreateRoomDialog(context, controller),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Create your first Room'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final count = width >= 980 ? 4 : width >= 620 ? 3 : 2;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 10,
                    mainAxisExtent: 172,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final room = recentRooms[index];
                      return RoomTile(
                        room: room,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => RoomDetailScreen(roomId: room.id),
                          ),
                        ),
                        logoBytes: controller.roomLogoBytes(room),
                      );
                    },
                    childCount: recentRooms.length,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _RecentSongRow extends StatelessWidget {
  const _RecentSongRow({
    required this.title,
    required this.subtitle,
    required this.hasRecording,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool hasRecording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: AppSurface(
        borderRadius: BorderRadius.circular(17),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.raised,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.music_note_rounded, color: AppColors.cyan, size: 18),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            if (hasRecording)
              const Icon(Icons.graphic_eq_rounded, size: 15, color: AppColors.gold),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 19),
          ],
        ),
      ),
    );
  }
}

class _ProjectMark extends StatelessWidget {
  const _ProjectMark({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x082B6FFF)],
        ),
      ),
      child: Icon(icon, color: AppColors.cyan, size: 25),
    );
  }
}
