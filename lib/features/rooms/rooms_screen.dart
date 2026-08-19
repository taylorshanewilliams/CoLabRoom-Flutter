import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../domain/music_models.dart';
import '../../domain/name_policy.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';
import '../../widgets/music_tiles.dart';
import '../home/new_song_flow.dart';
import 'room_detail_screen.dart';
import 'setlist_detail_screen.dart';

enum _RoomsView { rooms, setlists }

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key});

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  String _query = '';
  _RoomsView _view = _RoomsView.rooms;

  Future<void> _createSetlist(BuildContext context) async {
    final controller = BetaScope.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _SetlistNameDialog(),
    );
    if (name == null || !context.mounted) return;
    try {
      final setlist = await controller.createSetlist(name);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => SetlistDetailScreen(setlistId: setlist.id)),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final rooms = controller.rooms.where((room) {
      final query = NamePolicy.normalized(_query);
      return NamePolicy.normalized(room.name).contains(query) ||
          room.projects.any((project) => NamePolicy.normalized(project.title).contains(query));
    }).toList(growable: false);
    final setlists = controller.setlists
        .where((setlist) => NamePolicy.normalized(setlist.name).contains(NamePolicy.normalized(_query)))
        .toList(growable: false);
    final showingRooms = _view == _RoomsView.rooms;
    final itemCount = showingRooms ? rooms.length : setlists.length;

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    showingRooms ? 'Rooms' : 'Setlists',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                ),
                SizedBox(
                  width: 116,
                  height: 48,
                  child: BloomTap(
                    onTap: () => showingRooms
                        ? showCreateRoomDialog(context, controller)
                        : _createSetlist(context),
                    borderRadius: BorderRadius.circular(15),
                    child: AppSurface(
                      borderRadius: BorderRadius.circular(15),
                      padding: EdgeInsets.zero,
                      color: AppColors.raised,
                      child: Center(
                        child: Text(
                          showingRooms ? '+  New Room' : '+  Setlist',
                          style: const TextStyle(color: AppColors.cyan, fontWeight: FontWeight.w800),
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
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          sliver: SliverToBoxAdapter(
            child: SegmentedButton<_RoomsView>(
              segments: const <ButtonSegment<_RoomsView>>[
                ButtonSegment<_RoomsView>(
                  value: _RoomsView.rooms,
                  icon: Icon(Icons.folder_rounded),
                  label: Text('Rooms'),
                ),
                ButtonSegment<_RoomsView>(
                  value: _RoomsView.setlists,
                  icon: Icon(Icons.queue_music_rounded),
                  label: Text('Setlists'),
                ),
              ],
              selected: <_RoomsView>{_view},
              onSelectionChanged: (selection) => setState(() {
                _view = selection.first;
                _query = '';
              }),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          sliver: SliverToBoxAdapter(
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: showingRooms ? 'Search Rooms or projects' : 'Search setlists',
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
        ),
        if (itemCount == 0)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Text(
                  _query.isEmpty
                      ? (showingRooms
                          ? 'Create your first Music Room.'
                          : 'Create a setlist for rehearsals or shows.')
                      : 'No ${showingRooms ? 'Rooms' : 'setlists'} match “$_query”.',
                ),
              ),
            ),
          )
        else if (showingRooms && _query.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final count = width >= 1100 ? 4 : width >= 700 ? 3 : 2;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 10,
                    mainAxisExtent: 144,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _DraggableRoomTile(
                      key: ValueKey<String>(rooms[index].id),
                      room: rooms[index],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RoomDetailScreen(roomId: rooms[index].id),
                        ),
                      ),
                      onReorder: (draggedId) => _reorderRooms(controller, rooms, draggedId, index),
                      onMore: () => _showRoomMenu(controller, rooms[index]),
                    ),
                    childCount: itemCount,
                  ),
                );
              },
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final count = width >= 1100 ? 4 : width >= 700 ? 3 : 2;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 10,
                    mainAxisExtent: 144,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (showingRooms) {
                        final room = rooms[index];
                        return RoomTile(
                          room: room,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => RoomDetailScreen(roomId: room.id),
                            ),
                          ),
                          onMore: () => _showRoomMenu(controller, room),
                        );
                      }
                      final setlist = setlists[index];
                      return SetlistTile(
                        setlist: setlist,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SetlistDetailScreen(setlistId: setlist.id),
                          ),
                        ),
                      );
                    },
                    childCount: itemCount,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  void _reorderRooms(
    MusicBetaController controller,
    List<MusicRoom> visibleRooms,
    String draggedRoomId,
    int dropIndex,
  ) {
    if (draggedRoomId == visibleRooms[dropIndex].id) return;
    final reordered = List<MusicRoom>.from(visibleRooms);
    final draggedIndex = reordered.indexWhere((room) => room.id == draggedRoomId);
    if (draggedIndex == -1) return;
    final dragged = reordered.removeAt(draggedIndex);
    reordered.insert(dropIndex, dragged);
    unawaited(controller.reorderRooms(reordered));
  }

  Future<void> _showRoomMenu(MusicBetaController controller, MusicRoom room) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.deepNavy,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: AppColors.cyan),
                title: const Text('Rename Room'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFF9AA9)),
                title: const Text('Delete Room'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action == 'rename') {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => _RenameRoomDialog(initialName: room.name),
      );
      if (value == null || !mounted) return;
      try {
        await controller.renameRoom(room, value);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${room.name}"?'),
        content: const Text(
          'This permanently deletes the Room and everything in it — every song, lyric, and recording. This cannot be undone.',
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
    try {
      await controller.deleteRoom(room);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
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

/// Wraps [RoomTile] with long-press drag-to-reorder support. Dragging a
/// tile over another and releasing moves it to that tile's position.
class _DraggableRoomTile extends StatefulWidget {
  const _DraggableRoomTile({
    required this.room,
    required this.onTap,
    required this.onReorder,
    required this.onMore,
    super.key,
  });

  final MusicRoom room;
  final VoidCallback onTap;
  final ValueChanged<String> onReorder;
  final VoidCallback onMore;

  @override
  State<_DraggableRoomTile> createState() => _DraggableRoomTileState();
}

class _DraggableRoomTileState extends State<_DraggableRoomTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != widget.room.id,
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onReorder(details.data);
      },
      onMove: (_) => setState(() => _hovering = true),
      onLeave: (_) => setState(() => _hovering = false),
      builder: (context, candidates, rejected) {
        return LongPressDraggable<String>(
          data: widget.room.id,
          delay: const Duration(milliseconds: 220),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: 168,
              height: 144,
              child: Transform.scale(
                scale: 1.05,
                child: Opacity(
                  opacity: 0.9,
                  child: RoomTile(room: widget.room, onTap: () {}),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.28,
            child: RoomTile(room: widget.room, onTap: () {}),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: _hovering
                  ? Border.all(color: AppColors.cyan, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
            ),
            child: RoomTile(room: widget.room, onTap: widget.onTap, onMore: widget.onMore),
          ),
        );
      },
    );
  }
}

class _SetlistNameDialog extends StatefulWidget {
  const _SetlistNameDialog();

  @override
  State<_SetlistNameDialog> createState() => _SetlistNameDialogState();
}

class _SetlistNameDialogState extends State<_SetlistNameDialog> {
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
        decoration: const InputDecoration(hintText: 'Friday night set'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _name.text), child: const Text('Create')),
      ],
    );
  }
}
