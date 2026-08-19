import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/name_policy.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';
import '../../widgets/music_tiles.dart';
import '../home/new_song_flow.dart';
import '../workspace/song_workspace_screen.dart';

enum _ProjectSort { updatedRecent, alphabetical, createdNewest, createdOldest }

extension on _ProjectSort {
  String get label => switch (this) {
        _ProjectSort.updatedRecent => 'Recently updated',
        _ProjectSort.alphabetical => 'Alphabetical',
        _ProjectSort.createdNewest => 'Newest first',
        _ProjectSort.createdOldest => 'Oldest first',
      };

  IconData get icon => switch (this) {
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
  _ProjectSort _sort = _ProjectSort.updatedRecent;
  String _query = '';

  List<SongProject> _sortedProjects(MusicRoom room) {
    final query = NamePolicy.normalized(_query);
    final projects = List<SongProject>.from(
      query.isEmpty
          ? room.projects
          : room.projects.where((project) => NamePolicy.normalized(project.title).contains(query)),
    );
    switch (_sort) {
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
        builder: (_) => SimpleDialog(
          title: const Text('Add to Setlist'),
          children: <Widget>[
            for (final value in controller.setlists)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, value),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.queue_music_rounded, color: AppColors.cyan),
                  title: Text(value.name),
                  subtitle: Text('${value.projectIds.length} songs'),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'create'),
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
      _showMessage('Create another Room before moving projects.');
      return;
    }
    final target = await showDialog<MusicRoom>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Move to Room'),
        children: <Widget>[
          for (final room in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, room),
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
      if (mounted) _showMessage('Could not move the selection: $error');
    }
  }

  Future<void> _deleteSelected(MusicRoom room) async {
    final selected = room.projects
        .where((project) => _selectedProjectIds.contains(project.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(selected.length == 1 ? 'Delete this song?' : 'Delete ${selected.length} songs?'),
        content: Text(
          selected.length == 1
              ? '“${selected.first.title}” and all of its lyrics and recordings will be deleted permanently.'
              : 'These songs and all of their lyrics and recordings will be deleted permanently.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
            onPressed: () => Navigator.pop(context, true),
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

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final room = controller.roomById(widget.roomId);
    if (room == null) {
      return const Scaffold(body: Center(child: Text('This Room is no longer available.')));
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
      final draft = await showDialog<_InviteDraft>(
        context: context,
        builder: (_) => const _InviteCollaboratorDialog(),
      );
      if (draft == null) return;
      try {
        final code = await controller.createInvite(room, draft.email, role: draft.role);
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Invite ready'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Send this code to ${draft.email}. It expires in seven days.'),
                  const SizedBox(height: 16),
                  SelectableText(
                    code,
                    style: const TextStyle(
                      color: AppColors.cyan,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(content: Text('Invite code copied.')),
                    );
                  }
                },
                child: const Text('Copy Code'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Rooms'),
        actions: <Widget>[
          IconButton(
            onPressed: rename,
            tooltip: 'Rename Room',
            icon: const Icon(Icons.edit_rounded),
          ),
          IconButton(
            onPressed: invite,
            tooltip: 'Invite collaborator',
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
        ],
      ),
      body: Column(
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
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x082B6FFF)],
                      ),
                    ),
                    child: Text(
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
                    hintText: 'Search songs in this Room',
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
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 10,
                      mainAxisExtent: 164,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final project = sortedProjects[index];
                        return SongTile(
                          project: project,
                          selected: _selectedProjectIds.contains(project.id),
                          onLongPress: () => _toggleSelection(project.id),
                          onTap: () {
                            if (_selectedProjectIds.isNotEmpty) {
                              _toggleSelection(project.id);
                              return;
                            }
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SongWorkspaceScreen(projectId: project.id),
                              ),
                            );
                          },
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

class _InviteDraft {
  const _InviteDraft(this.email, this.role);

  final String email;
  final RoomRole role;
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
      title: const Text('Rename Room'),
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

class _InviteCollaboratorDialog extends StatefulWidget {
  const _InviteCollaboratorDialog();

  @override
  State<_InviteCollaboratorDialog> createState() => _InviteCollaboratorDialogState();
}

class _InviteCollaboratorDialogState extends State<_InviteCollaboratorDialog> {
  final _email = TextEditingController();
  RoomRole _role = RoomRole.editor;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite a Collaborator'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Their email'),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<RoomRole>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: 'Permission'),
              items: const <DropdownMenuItem<RoomRole>>[
                DropdownMenuItem(value: RoomRole.editor, child: Text('Editor')),
                DropdownMenuItem(value: RoomRole.commenter, child: Text('Commenter')),
                DropdownMenuItem(value: RoomRole.viewer, child: Text('Viewer')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _role = value);
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _InviteDraft(_email.text, _role)),
          child: const Text('Create Invite'),
        ),
      ],
    );
  }
}
