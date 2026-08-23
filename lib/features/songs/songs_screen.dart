import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';
import '../home/new_song_flow.dart';
import '../workspace/song_workspace_screen.dart';
import 'song_search.dart';

/// Every song the user can reach, in one place.
///
/// Songs are what this app is for, and until now they had no home of their
/// own — they lived two or three taps inside whichever Room they happened to
/// be filed under, and the only way to find one was to remember where you
/// put it. Rooms still exist and still control who can see what; they're a
/// filter here rather than a place you have to visit first.
class SongsScreen extends StatefulWidget {
  const SongsScreen({super.key});

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _roomFilterId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _open(SongProject project) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SongWorkspaceScreen(projectId: project.id)),
    );
  }

  Future<void> _newSong() async {
    final controller = BetaScope.of(context);
    final project = await showNewSongFlow(context, controller);
    if (project != null && mounted) _open(project);
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final rooms = controller.rooms;
    final searching = _query.trim().isNotEmpty;

    var results = searching ? searchSongs(rooms, _query) : allSongsByRecency(rooms);
    if (_roomFilterId != null) {
      results = results.where((r) => r.room.id == _roomFilterId).toList(growable: false);
    }

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('Songs', style: Theme.of(context).textTheme.displaySmall),
                ),
                FilledButton.icon(
                  key: const Key('songs_new_button'),
                  onPressed: _newSong,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New'),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          sliver: SliverToBoxAdapter(
            child: TextField(
              key: const Key('songs_search_field'),
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search songs, rooms, or a lyric you remember',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: searching
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
              ),
            ),
          ),
        ),
        if (rooms.length > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    _RoomChip(
                      label: 'All rooms',
                      selected: _roomFilterId == null,
                      onTap: () => setState(() => _roomFilterId = null),
                    ),
                    for (final room in rooms)
                      _RoomChip(
                        label: room.name,
                        selected: _roomFilterId == room.id,
                        onTap: () => setState(
                          () => _roomFilterId = _roomFilterId == room.id ? null : room.id,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (results.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 20, 30, 60),
              child: Center(
                child: Text(
                  searching
                      ? 'Nothing matches “${_query.trim()}”.'
                      : 'No songs yet. Tap New to start one.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            sliver: SliverList.separated(
              itemCount: results.length,
              separatorBuilder: (_, __) => const SizedBox(height: 9),
              itemBuilder: (context, index) => _SongRow(
                result: results[index],
                onTap: () => _open(results[index].project),
              ),
            ),
          ),
      ],
    );
  }
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? AppColors.cyan.withValues(alpha: 0.15) : AppColors.surface,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: selected ? AppColors.cyan : AppColors.line),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.cyan : AppColors.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// A row rather than a grid tile: a list scans faster when the thing you're
/// looking for is a name, and it leaves room to show *why* a search result
/// matched.
class _SongRow extends StatelessWidget {
  const _SongRow({required this.result, required this.onTap});

  final SongSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final project = result.project;
    final lyric = result.lyricLine;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(19),
      child: AppSurface(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.raised,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.music_note_rounded, color: AppColors.cyan, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  if (lyric != null)
                    Text(
                      '“$lyric”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.cyan,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    Text(
                      '${result.room.icon}  ${result.room.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (project.hasAudioReference)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.graphic_eq_rounded, size: 15, color: AppColors.gold),
              ),
            if (project.status == SongStatus.completed)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.check_circle_rounded, size: 15, color: AppColors.cyan),
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
          ],
        ),
      ),
    );
  }
}
