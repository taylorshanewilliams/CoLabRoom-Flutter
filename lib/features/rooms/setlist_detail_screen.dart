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
      final selected = await showDialog<Set<String>>(
        context: context,
        builder: (_) => _AddSongsDialog(
          projects: controller.projects.toList(growable: false),
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
        title: Text(setlist.name),
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
                              child: Text(project.title, style: Theme.of(context).textTheme.titleMedium),
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

class _AddSongsDialog extends StatefulWidget {
  const _AddSongsDialog({required this.projects, required this.existingIds});

  final List<SongProject> projects;
  final Set<String> existingIds;

  @override
  State<_AddSongsDialog> createState() => _AddSongsDialogState();
}

class _AddSongsDialogState extends State<_AddSongsDialog> {
  final Set<String> _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final available = widget.projects
        .where((project) => !widget.existingIds.contains(project.id))
        .toList(growable: false);
    return AlertDialog(
      title: const Text('Add Songs'),
      content: SizedBox(
        width: 440,
        child: available.isEmpty
            ? const Text('Every available song is already in this setlist.')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: available.length,
                itemBuilder: (context, index) {
                  final project = available[index];
                  return CheckboxListTile(
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
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
