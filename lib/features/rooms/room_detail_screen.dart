import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/name_policy.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';
import '../../widgets/invite_collaborator_dialog.dart';
import '../../widgets/music_tiles.dart';
import '../home/new_song_flow.dart';
import '../workspace/song_workspace_screen.dart';

enum _ProjectSort { manual, updatedRecent, alphabetical, createdNewest, createdOldest }

extension on _ProjectSort {
  String get label => switch (this) {
        _ProjectSort.manual => 'Custom order',
        _ProjectSort.updatedRecent => 'Recently updated',
        _ProjectSort.alphabetical => 'Alphabetical',
        _ProjectSort.createdNewest => 'Newest first',
        _ProjectSort.createdOldest => 'Oldest first',
      };

  IconData get icon => switch (this) {
        _ProjectSort.manual => Icons.drag_indicator_rounded,
        _ProjectSort.updatedRecent => Icons.history_rounded,
        _ProjectSort.alphabetical => Icons.sort_by_alpha_rounded,
        _ProjectSort.createdNewest => Icons.arrow_downward_rounded,
        _ProjectSort.createdOldest => Icons.arrow_upward_rounded,
      };
}

class RoomDetailScreen extends StatefulWidget {
  const RoomDetailScreen({required this.roomId, super.key});

  final String roomId;

  @override
  State<RoomDetailScreen> createState() => _RoomDetailScreenState();
}

class _RoomDetailScreenState extends State<RoomDetailScreen> {
  final Set<String> _selectedProjectIds = <String>{};
  // Manual (drag-to-reorder) by default so song tiles behave like Room
  // tiles out of the box — dragging shouldn't require hunting through a
  // sort menu first.
  _ProjectSort _sort = _ProjectSort.manual;
  String _query = '';

  List<SongProject> _sortedProjects(MusicRoom room) {
    final query = NamePolicy.normalized(_query);
    final projects = List<SongProject>.from(
      query.isEmpty
          ? room.projects
          : room.projects.where((project) => NamePolicy.normalized(project.title).contains(query)),
    );
    switch (_sort) {
      case _ProjectSort.manual:
        projects.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      case _ProjectSort.updatedRecent:
        projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case _ProjectSort.alphabetical:
        projects.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _ProjectSort.createdNewest:
        projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _ProjectSort.createdOldest:
        projects.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    return projects;
  }

  void _toggleSelection(String projectId) {
    setState(() {
      if (!_selectedProjectIds.add(projectId)) _selectedProjectIds.remove(projectId);
    });
  }

  Future<void> _addSelectedToSetlist() async {
    final controller = BetaScope.of(context);
    Setlist? setlist;
    var createNew = controller.setlists.isEmpty;
    if (controller.setlists.isNotEmpty) {
      final choice = await showDialog<Object>(
        context: context,
        // showDialog defaults to the root navigator, but this app also has
        // a nested workspace Navigator (see workspace_shell.dart) — using
        // the outer `context` to pop (instead of this builder's own
        // dialogContext) pops the wrong navigator's top route, closing this
        // screen instead of the dialog while the dialog itself is left
        // orphaned on top, blocking input. Looks like "goes back a screen
        // and freezes."
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Add to Setlist'),
          children: <Widget>[
            for (final value in controller.setlists)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, value),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.queue_music_rounded, color: AppColors.cyan),
                  title: Text(value.name),
                  subtitle: Text('${value.projectIds.length} songs'),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, 'create'),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.add_rounded, color: AppColors.cyan),
                title: Text('Create a new Setlist'),
              ),
            ),
          ],
        ),
      );
      if (choice is Setlist) setlist = choice;
      createNew = choice == 'create';
    }
    if (setlist == null && createNew && mounted) {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => const _NewSetlistDialog(),
      );
      if (name == null || !mounted) return;
      try {
        setlist = await controller.createSetlist(name);
      } catch (error) {
        if (mounted) _showMessage(error.toString());
        return;
      }
    }
    if (setlist == null) return;
    try {
      await controller.addProjectsToSetlist(setlist, _selectedProjectIds);
      if (!mounted) return;
      _showMessage('Added ${_selectedProjectIds.length} ${_selectedProjectIds.length == 1 ? 'song' : 'songs'} to ${setlist.name}.');
      setState(_selectedProjectIds.clear);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _moveSelected(MusicRoom currentRoom) async {
    final controller = BetaScope.of(context);
    final targets = controller.rooms.where((room) => room.id != currentRoom.id).toList();
    if (targets.isEmpty) {
      _showMessage('Create another catalog before moving songs.');
      return;
    }
    final target = await showDialog<MusicRoom>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Move to a catalog'),
        children: <Widget>[
          for (final room in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, room),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Text(room.icon, style: const TextStyle(fontSize: 24)),
                title: Text(room.name),
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final selected = currentRoom.projects
        .where((project) => _selectedProjectIds.contains(project.id))
        .toList(growable: false);
    try {
      await controller.moveProjects(selected, target);
      if (!mounted) return;
      _showMessage('Moved ${selected.length} ${selected.length == 1 ? 'project' : 'projects'} to ${target.name}.');
      setState(_selectedProjectIds.clear);
    } catch (error) {
      if (mounted) _showMessage(_moveFailureMessage(error, target));
    }
  }

  /// Why a move failed, in words about songs rather than about constraints.
  ///
  /// Moving a song into a Room owned by a different account now moves the
  /// song's account with it, which is what the database always required. The
  /// side effect is that a title can collide on arrival: song titles are
  /// unique per account, so a Room that already has a song by this name will
  /// refuse it. That is a real conflict a person has to resolve by renaming
  /// one of them, and "duplicate key value violates unique constraint
  /// projects_account_title_unique" tells them none of that.
  String _moveFailureMessage(Object error, MusicRoom target) {
    final text = error.toString();
    if (text.contains('projects_account_title_unique')) {
      return '${target.name} already has a song with that name. '
          'Rename one of them and try again.';
    }
    return 'Could not move the selection: $error';
  }

  Future<void> _deleteSelected(MusicRoom room) async {
    final selected = room.projects
        .where((project) => _selectedProjectIds.contains(project.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(selected.length == 1 ? 'Delete this song?' : 'Delete ${selected.length} songs?'),
        content: Text(
          selected.length == 1
              ? '“${selected.first.title}” and all of its lyrics and recordings will be deleted permanently.'
              : 'These songs and all of their lyrics and recordings will be deleted permanently.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final controller = BetaScope.of(context);
    try {
      for (final project in selected) {
        await controller.deleteSong(project);
      }
      if (!mounted) return;
      _showMessage('Deleted ${selected.length} ${selected.length == 1 ? 'song' : 'songs'}.');
      setState(_selectedProjectIds.clear);
    } catch (error) {
      if (mounted) _showMessage('Could not delete the selection: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _reorderProjects(
    MusicRoom room,
    List<SongProject> visibleProjects,
    String draggedProjectId,
    int dropIndex,
  ) {
    if (draggedProjectId == visibleProjects[dropIndex].id) return;
    final reordered = List<SongProject>.from(visibleProjects);
    final draggedIndex = reordered.indexWhere((project) => project.id == draggedProjectId);
    if (draggedIndex == -1) return;
    final dragged = reordered.removeAt(draggedIndex);
    reordered.insert(dropIndex, dragged);
    unawaited(BetaScope.of(context).reorderRoomProjects(room, reordered));
  }

  Future<void> _showSongMenu(MusicRoom room, SongProject project) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Rename Song'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(project.coverImagePath == null ? 'Set Song Cover' : 'Replace Song Cover'),
                onTap: () => Navigator.pop(context, 'set_cover'),
              ),
              if (project.coverImagePath != null)
                ListTile(
                  leading: const Icon(Icons.hide_image_outlined, color: AppColors.muted),
                  title: const Text('Remove Song Cover'),
                  onTap: () => Navigator.pop(context, 'remove_cover'),
                ),
              ListTile(
                leading: Icon(
                  project.status == SongStatus.completed
                      ? Icons.radio_button_unchecked_rounded
                      : Icons.check_circle_outline_rounded,
                ),
                title: Text(
                  project.status == SongStatus.completed ? 'Mark In Progress' : 'Mark Complete',
                ),
                onTap: () => Navigator.pop(context, 'toggle_status'),
              ),
              ListTile(
                leading: const Icon(Icons.check_box_outlined),
                title: const Text('Select Multiple'),
                onTap: () => Navigator.pop(context, 'select'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFF9AA9)),
                title: const Text('Delete Song'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        await _renameSong(project);
      case 'set_cover':
        await _pickAndSetSongCover(project);
      case 'remove_cover':
        try {
          await BetaScope.of(context).clearProjectCover(project);
        } catch (error) {
          if (mounted) _showMessage(error.toString());
        }
      case 'toggle_status':
        try {
          await BetaScope.of(context).setSongStatus(
            project,
            project.status == SongStatus.completed ? SongStatus.active : SongStatus.completed,
          );
        } catch (error) {
          if (mounted) _showMessage(error.toString());
        }
      case 'select':
        setState(() => _selectedProjectIds.add(project.id));
      case 'delete':
        await _deleteSingleSong(room, project);
    }
  }

  Future<void> _pickAndSetSongCover(SongProject project) async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null || !mounted) return;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw Exception('ColabRoom could not read that image.');
      // Reading a large photo is its own async gap, and the check above
      // happened before it. Leaving the room while a cover decodes would
      // otherwise reach BetaScope through a dead element.
      if (!mounted) return;
      await BetaScope.of(context).setProjectCover(project, bytes);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _renameSong(SongProject project) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _RenameProjectDialog(initialTitle: project.title),
    );
    if (value == null || !mounted) return;
    try {
      await BetaScope.of(context).renameSong(project, value);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _deleteSingleSong(MusicRoom room, SongProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this song?'),
        content: Text(
          '“${project.title}” and all of its lyrics and recordings will be deleted permanently.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await BetaScope.of(context).deleteSong(project);
      if (mounted) _showMessage('Deleted “${project.title}”.');
    } catch (error) {
      if (mounted) _showMessage('Could not delete this song: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final room = controller.roomById(widget.roomId);
    if (room == null) {
      return const Scaffold(body: Center(child: Text('This catalog is no longer available.')));
    }

    Future<void> rename() async {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => _RenameRoomDialog(initialName: room.name),
      );
      if (value == null) return;
      try {
        await controller.renameRoom(room, value);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }

    Future<void> newSong() async {
      final project = await showNewSongFlow(context, controller, initialRoom: room);
      if (project != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SongWorkspaceScreen(projectId: project.id),
          ),
        );
      }
    }

    Future<void> invite() async {
      final draft = await showDialog<InviteDraft>(
        context: context,
        builder: (_) => const InviteCollaboratorDialog(),
      );
      if (draft == null) return;
      try {
        final result = await controller.createInvite(room, draft.email, role: draft.role);
        if (!context.mounted) return;
        if (result.matchedAccount) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invite sent — ${draft.email} will see it in their Invites tab.')),
          );
        } else {
          await showInviteReadyDialog(context, email: draft.email, code: result.code);
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Catalogs'),
        actions: <Widget>[
          IconButton(
            onPressed: rename,
            tooltip: 'Rename catalog',
            icon: const Icon(Icons.edit_rounded),
          ),
          IconButton(
            onPressed: invite,
            tooltip: 'Invite collaborator',
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
        children: <Widget>[
          if (_selectedProjectIds.isNotEmpty)
            _ProjectSelectionBar(
              count: _selectedProjectIds.length,
              onSetlist: _addSelectedToSetlist,
              onMove: () => _moveSelected(room),
              onDelete: () => _deleteSelected(room),
              onCancel: () => setState(_selectedProjectIds.clear),
            ),
          Expanded(
            child: CustomScrollView(
              slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
            sliver: SliverToBoxAdapter(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    clipBehavior: Clip.antiAlias,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x082B6FFF)],
                      ),
                    ),
                    child: controller.roomLogoBytes(room) != null
                        ? Image.memory(
                            controller.roomLogoBytes(room)!,
                            fit: BoxFit.cover,
                            width: 56,
                            height: 56,
                          )
                        : Text(
                            room.icon,
                            style: const TextStyle(fontSize: 27, color: AppColors.cyan),
                          ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        InkWell(
                          onTap: rename,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(room.name, style: Theme.of(context).textTheme.titleLarge),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('${room.members.length} members · ${room.projects.length} projects'),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 44,
                    child: BloomTap(
                      onTap: newSong,
                      borderRadius: BorderRadius.circular(15),
                      child: AppSurface(
                        borderRadius: BorderRadius.circular(15),
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        color: AppColors.raised,
                        child: const Center(
                          child: Text(
                            '+  New Song',
                            style: TextStyle(
                              color: AppColors.cyan,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text('Projects', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  if (room.projects.length > 1)
                    PopupMenuButton<_ProjectSort>(
                      key: const Key('project_sort_menu'),
                      tooltip: 'Sort projects',
                      initialValue: _sort,
                      onSelected: (value) => setState(() => _sort = value),
                      itemBuilder: (context) => <PopupMenuEntry<_ProjectSort>>[
                        for (final option in _ProjectSort.values)
                          PopupMenuItem<_ProjectSort>(
                            value: option,
                            child: Row(
                              children: <Widget>[
                                Icon(option.icon, size: 18, color: AppColors.muted),
                                const SizedBox(width: 10),
                                Text(option.label),
                              ],
                            ),
                          ),
                      ],
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(_sort.icon, size: 17, color: AppColors.muted),
                          const SizedBox(width: 5),
                          Text(
                            _sort.label,
                            style: const TextStyle(color: AppColors.muted, fontSize: 12.5, fontWeight: FontWeight.w700),
                          ),
                          const Icon(Icons.arrow_drop_down_rounded, color: AppColors.muted),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (room.projects.length > 1)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              sliver: SliverToBoxAdapter(
                child: TextField(
                  key: const Key('room_project_search'),
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Search songs in this catalog',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
            ),
          if (room.projects.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: FilledButton.icon(
                  onPressed: newSong,
                  icon: const Icon(Icons.music_note_rounded),
                  label: const Text('Create the first song'),
                ),
              ),
            )
          else if (_sortedProjects(room).isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(30),
                  child: Text('No songs match “$_query”.'),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.crossAxisExtent;
                  final count = width >= 1100 ? 4 : width >= 700 ? 3 : 2;
                  final sortedProjects = _sortedProjects(room);
                  final density = _densityFor(sortedProjects.length);
                  final tileWidth = (width - 10 * (count - 1)) / count;
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 10,
                      mainAxisExtent: density.mainAxisExtent,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final project = sortedProjects[index];
                        void onTap() {
                          if (_selectedProjectIds.isNotEmpty) {
                            _toggleSelection(project.id);
                            return;
                          }
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SongWorkspaceScreen(projectId: project.id),
                            ),
                          );
                        }

                        if (_selectedProjectIds.isEmpty &&
                            _sort == _ProjectSort.manual &&
                            _query.isEmpty) {
                          return _DraggableSongTile(
                            key: ValueKey<String>(project.id),
                            project: project,
                            density: density,
                            tileSize: Size(tileWidth, density.mainAxisExtent),
                            onTap: onTap,
                            onMore: () => _showSongMenu(room, project),
                            onReorder: (draggedId) =>
                                _reorderProjects(room, sortedProjects, draggedId, index),
                            coverBytes: controller.projectCoverBytes(project),
                          );
                        }
                        return SongTile(
                          project: project,
                          density: density,
                          selected: _selectedProjectIds.contains(project.id),
                          onMore: _selectedProjectIds.isEmpty ? () => _showSongMenu(room, project) : null,
                          onTap: onTap,
                          coverBytes: controller.projectCoverBytes(project),
                          unheardTakes: controller.unheardTakesFor(project.id),
                        );
                      },
                      childCount: sortedProjects.length,
                    ),
                  );
                },
              ),
            ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// A Room with a handful of songs can afford the spacious card; one with
  /// dozens shouldn't force endless scrolling for what's ultimately the
  /// same glance-and-tap card, so tiles step down automatically as the
  /// Room fills up instead of staying a fixed size forever.
  SongTileDensity _densityFor(int projectCount) {
    if (projectCount <= 4) return SongTileDensity.spacious;
    if (projectCount <= 14) return SongTileDensity.cozy;
    return SongTileDensity.compact;
  }
}

/// Wraps [SongTile] with long-press drag-to-reorder support, mirroring
/// _DraggableRoomTile on the Rooms screen. Only used while sorted by
/// "Custom order" (the default) with no active search/selection.
class _DraggableSongTile extends StatefulWidget {
  const _DraggableSongTile({
    required this.project,
    required this.density,
    required this.tileSize,
    required this.onTap,
    required this.onMore,
    required this.onReorder,
    this.coverBytes,
    super.key,
  });

  final SongProject project;
  final SongTileDensity density;
  final Size tileSize;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final ValueChanged<String> onReorder;
  final Uint8List? coverBytes;

  @override
  State<_DraggableSongTile> createState() => _DraggableSongTileState();
}

class _DraggableSongTileState extends State<_DraggableSongTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != widget.project.id,
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onReorder(details.data);
      },
      onMove: (_) => setState(() => _hovering = true),
      onLeave: (_) => setState(() => _hovering = false),
      builder: (context, candidates, rejected) {
        return LongPressDraggable<String>(
          data: widget.project.id,
          delay: const Duration(milliseconds: 220),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: widget.tileSize.width,
              height: widget.tileSize.height,
              child: Transform.scale(
                scale: 1.05,
                child: Opacity(
                  opacity: 0.9,
                  child: SongTile(project: widget.project, density: widget.density, onTap: () {}),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.28,
            child: SongTile(project: widget.project, density: widget.density, onTap: () {}),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: _hovering
                  ? Border.all(color: AppColors.cyan, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
            ),
            child: SongTile(
              project: widget.project,
              density: widget.density,
              onTap: widget.onTap,
              onMore: widget.onMore,
              coverBytes: widget.coverBytes,
            ),
          ),
        );
      },
    );
  }
}

class _ProjectSelectionBar extends StatelessWidget {
  const _ProjectSelectionBar({
    required this.count,
    required this.onSetlist,
    required this.onMove,
    required this.onDelete,
    required this.onCancel,
  });

  final int count;
  final VoidCallback onSetlist;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0B1C35),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
          child: Row(
            children: <Widget>[
              IconButton(onPressed: onCancel, tooltip: 'Cancel selection', icon: const Icon(Icons.close_rounded)),
              Flexible(
                child: Text(
                  '$count selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onSetlist,
                tooltip: 'Add to setlist',
                icon: const Icon(Icons.playlist_add_rounded),
              ),
              IconButton(
                onPressed: onMove,
                tooltip: 'Move',
                icon: const Icon(Icons.drive_file_move_rounded),
              ),
              IconButton(
                key: const Key('delete_selected_songs'),
                onPressed: onDelete,
                tooltip: 'Delete',
                color: const Color(0xFFFF9AA9),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewSetlistDialog extends StatefulWidget {
  const _NewSetlistDialog();

  @override
  State<_NewSetlistDialog> createState() => _NewSetlistDialogState();
}

class _NewSetlistDialogState extends State<_NewSetlistDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Setlist'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) => Navigator.pop(context, value),
        decoration: const InputDecoration(hintText: 'Setlist name'),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _name.text), child: const Text('Create')),
      ],
    );
  }
}

class _RenameRoomDialog extends StatefulWidget {
  const _RenameRoomDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameRoomDialog> createState() => _RenameRoomDialogState();
}

class _RenameRoomDialogState extends State<_RenameRoomDialog> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename catalog'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _RenameProjectDialog extends StatefulWidget {
  const _RenameProjectDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _title;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename Song'),
      content: TextField(
        controller: _title,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _title.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

