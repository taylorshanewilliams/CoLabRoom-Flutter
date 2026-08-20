import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/project_export_service.dart';
import '../../widgets/app_surface.dart';
import '../workspace/song_workspace_screen.dart';

enum _SetlistMenuAction { print, share }

class SetlistDetailScreen extends StatefulWidget {
  const SetlistDetailScreen({required this.setlistId, super.key});

  final String setlistId;

  @override
  State<SetlistDetailScreen> createState() => _SetlistDetailScreenState();
}

class _SetlistDetailScreenState extends State<SetlistDetailScreen> {
  // Optimistic local order so drag-and-drop feels instant instead of
  // waiting on a round trip to the backend before the list visibly moves.
  List<String>? _localOrder;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final setlist = controller.setlistById(widget.setlistId);
    if (setlist == null) {
      return const Scaffold(body: Center(child: Text('This setlist is no longer available.')));
    }

    // Resync local order whenever the underlying song set changes (songs
    // added/removed elsewhere), but keep it otherwise so a drag isn't
    // clobbered by an in-flight reload from a previous reorder.
    if (_localOrder == null || _localOrder!.toSet().difference(setlist.projectIds.toSet()).isNotEmpty ||
        setlist.projectIds.toSet().difference(_localOrder!.toSet()).isNotEmpty) {
      _localOrder = List<String>.from(setlist.projectIds);
    }
    final order = _localOrder!;

    final projects = <SongProject>[];
    for (final projectId in order) {
      final project = controller.projectById(projectId);
      if (project != null) projects.add(project);
    }

    void reorder(int oldIndex, int newIndex) {
      if (newIndex > oldIndex) newIndex -= 1;
      final updated = List<String>.from(order);
      final movedId = updated.removeAt(oldIndex);
      updated.insert(newIndex, movedId);
      setState(() => _localOrder = updated);
      unawaited(controller.reorderSetlistProjects(setlist, updated));
    }

    Future<void> export(_SetlistMenuAction action) async {
      try {
        switch (action) {
          case _SetlistMenuAction.print:
            await ProjectExportService.printSetlist(setlist, projects);
            break;
          case _SetlistMenuAction.share:
            await ProjectExportService.shareSetlist(setlist, projects);
            break;
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }

    Future<void> addSongs() async {
      final selected = await showModalBottomSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.deepNavy,
        builder: (_) => _AddSongsSheet(
          rooms: controller.rooms,
          existingIds: setlist.projectIds.toSet(),
        ),
      );
      if (selected == null || selected.isEmpty) return;
      try {
        await controller.addProjectsToSetlist(setlist, selected);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(setlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            onPressed: addSongs,
            tooltip: 'Add songs',
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          PopupMenuButton<_SetlistMenuAction>(
            tooltip: 'Setlist options',
            onSelected: export,
            itemBuilder: (_) => const <PopupMenuEntry<_SetlistMenuAction>>[
              PopupMenuItem<_SetlistMenuAction>(
                value: _SetlistMenuAction.print,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.print_rounded),
                  title: Text('Send to printer'),
                ),
              ),
              PopupMenuItem<_SetlistMenuAction>(
                value: _SetlistMenuAction.share,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.share_rounded),
                  title: Text('Share by text or email'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: projects.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.queue_music_rounded, size: 44, color: AppColors.cyan),
                    const SizedBox(height: 12),
                    const Text('This setlist is ready for songs.'),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: addSongs,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Songs'),
                    ),
                  ],
                ),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
              buildDefaultDragHandles: false,
              itemCount: projects.length,
              onReorder: reorder,
              itemBuilder: (context, index) {
                final project = projects[index];
                return ReorderableDragStartListener(
                  key: ValueKey<String>(project.id),
                  index: index,
                  child: Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: AppSurface(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
                    child: Row(
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.drag_indicator_rounded, color: AppColors.muted),
                        ),
                        SizedBox(
                          width: 26,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: AppColors.cyan,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const Icon(Icons.music_note_rounded, color: AppColors.cyan),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SongWorkspaceScreen(projectId: project.id),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                project.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => controller.removeProjectFromSetlist(setlist, project.id),
                          tooltip: 'Remove from setlist',
                          icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  ),
                );
              },
            ),
    );
  }
}

class _AddSongsSheet extends StatefulWidget {
  const _AddSongsSheet({required this.rooms, required this.existingIds});

  final List<MusicRoom> rooms;
  final Set<String> existingIds;

  @override
  State<_AddSongsSheet> createState() => _AddSongsSheetState();
}

class _AddSongsSheetState extends State<_AddSongsSheet> {
  final Set<String> _selected = <String>{};
  final _query = TextEditingController();
  String? _roomId;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.text.trim().toLowerCase();
    final available = widget.rooms
        .where((room) => _roomId == null || room.id == _roomId)
        .expand((room) => room.projects)
        .where((project) =>
            !widget.existingIds.contains(project.id) &&
            (normalizedQuery.isEmpty || project.title.toLowerCase().contains(normalizedQuery)))
        .toList(growable: false);
    return SafeArea(
      top: false,
      // An AlertDialog's shrink-wrapped ListView had no bounded ancestor to
      // shrink-wrap within (a Dialog doesn't force one), so with enough
      // songs it tried to size itself to the sum of every row — taller
      // than the dialog could ever be, which is a real overflow the Flutter
      // framework can't recover from cleanly. Bottom sheets need the same
      // care: an explicit fixed height plus Expanded (not shrinkWrap) is
      // what actually gives the list something bounded to scroll within.
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Add Songs', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                  hintText: 'Search songs',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    _RoomFilterChip(
                      label: 'All Rooms',
                      selected: _roomId == null,
                      onTap: () => setState(() => _roomId = null),
                    ),
                    for (final room in widget.rooms) ...<Widget>[
                      const SizedBox(width: 8),
                      _RoomFilterChip(
                        label: room.name,
                        selected: _roomId == room.id,
                        onTap: () => setState(() => _roomId = room.id),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: available.isEmpty
                    ? Center(
                        child: Text(
                          normalizedQuery.isNotEmpty || _roomId != null
                              ? 'No matching songs.'
                              : 'Every available song is already in this setlist.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: available.length,
                        itemBuilder: (context, index) {
                          final project = available[index];
                          return CheckboxListTile(
                            key: ValueKey<String>(project.id),
                            value: _selected.contains(project.id),
                            title: Text(project.title),
                            onChanged: (selected) => setState(() {
                              if (selected ?? false) {
                                _selected.add(project.id);
                              } else {
                                _selected.remove(project.id);
                              }
                            }),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected),
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomFilterChip extends StatelessWidget {
  const _RoomFilterChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.raised,
      side: BorderSide(color: selected ? AppColors.cyan : AppColors.line),
    );
  }
}
