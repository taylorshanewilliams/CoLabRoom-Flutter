import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/bloom_tap.dart';
import '../../widgets/music_tiles.dart';
import '../rooms/room_detail_screen.dart';
import 'music_templates_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.displayName,
    required this.onSeeRooms,
    required this.onJoinProject,
    required this.onOpenAccount,
    super.key,
  });

  final String displayName;
  final VoidCallback onSeeRooms;
  final VoidCallback onJoinProject;
  final VoidCallback onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final recentRooms = controller.rooms.take(4).toList(growable: false);
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

    void openMusic() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MusicTemplatesScreen()),
      );
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
                Text('Start a project', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                const Text('Choose what you’re working on', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                BloomTap(
                  onTap: openMusic,
                  semanticLabel: 'Open Music project options',
                  borderRadius: BorderRadius.circular(19),
                  child: const SizedBox(
                    height: 108,
                    child: AppSurface(
                      child: Row(
                        children: <Widget>[
                          _ProjectMark(icon: Icons.music_note_rounded),
                          SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              'Music',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                BloomTap(
                  onTap: onJoinProject,
                  borderRadius: BorderRadius.circular(17),
                  child: SizedBox(
                    height: 48,
                    child: AppSurface(
                      borderRadius: BorderRadius.circular(17),
                      padding: EdgeInsets.zero,
                      color: AppColors.raised,
                      child: const Center(
                        child: Text('Join Project', style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Text('My Rooms', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                TextButton(onPressed: onSeeRooms, child: const Text('See all  ›')),
              ],
            ),
          ),
        ),
        if (recentRooms.isEmpty)
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(18, 12, 18, 30),
            sliver: SliverToBoxAdapter(
              child: Text('Your Rooms will appear here.'),
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
                    mainAxisExtent: 134,
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
