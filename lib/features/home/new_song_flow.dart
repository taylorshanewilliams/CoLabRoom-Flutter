import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../domain/music_models.dart';
import '../../domain/name_policy.dart';
import '../../widgets/app_surface.dart';

Future<MusicRoom?> showCreateRoomDialog(
  BuildContext context,
  MusicBetaController controller,
) async {
  final draft = await showDialog<_RoomDraft>(
    context: context,
    builder: (_) => const _CreateRoomDialog(),
  );
  if (draft == null) return null;
  try {
    return await controller.createRoom(name: draft.name, icon: draft.icon);
  } catch (error) {
    if (context.mounted) _showError(context, error);
    return null;
  }
}

Future<SongProject?> showNewSongFlow(
  BuildContext context,
  MusicBetaController controller, {
  MusicRoom? initialRoom,
}) async {
  var room = initialRoom;
  if (room == null) {
    final choice = await showModalBottomSheet<_RoomChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.deepNavy,
      builder: (_) => _RoomPickerSheet(controller: controller),
    );
    if (choice == null || !context.mounted) return null;
    room = choice.createNew ? await showCreateRoomDialog(context, controller) : choice.room;
  }
  if (room == null || !context.mounted) return null;
  return _askForSongTitle(context, controller, room);
}

Future<SongProject?> _askForSongTitle(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final title = await showDialog<String>(
    context: context,
    builder: (_) => _SongTitleDialog(roomName: room.name),
  );
  if (title == null) return null;
  try {
    return await controller.createSong(room, title);
  } catch (error) {
    if (context.mounted) _showError(context, error);
    return null;
  }
}

void _showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
}

class _RoomDraft {
  const _RoomDraft(this.name, this.icon);

  final String name;
  final String icon;
}

class _CreateRoomDialog extends StatefulWidget {
  const _CreateRoomDialog();

  @override
  State<_CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends State<_CreateRoomDialog> {
  final _name = TextEditingController();
  String _icon = '♪';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create a Music Room'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Name it your way—capital letters and spaces are preserved.'),
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Room name'),
            ),
            const SizedBox(height: 18),
            const Text('Choose an icon', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              children: <String>['♪', '♬', '♫', '🎸', '🎹', '🎤'].map((candidate) {
                final selected = candidate == _icon;
                return ChoiceChip(
                  selected: selected,
                  showCheckmark: false,
                  label: Text(candidate, style: const TextStyle(fontSize: 21)),
                  onSelected: (_) => setState(() => _icon = candidate),
                  selectedColor: AppColors.raised,
                  side: BorderSide(color: selected ? AppColors.cyan : AppColors.line),
                );
              }).toList(growable: false),
            ),
          ],
        ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _RoomDraft(_name.text, _icon)),
          child: const Text('Create Room'),
        ),
      ],
    );
  }
}

class _SongTitleDialog extends StatefulWidget {
  const _SongTitleDialog({required this.roomName});

  final String roomName;

  @override
  State<_SongTitleDialog> createState() => _SongTitleDialogState();
}

class _SongTitleDialogState extends State<_SongTitleDialog> {
  final _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name your song'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _title,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Project name',
            helperText: 'Saving to ${widget.roomName}',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _title.text),
          child: const Text('Create Song'),
        ),
      ],
    );
  }
}

class _RoomChoice {
  const _RoomChoice.room(this.room) : createNew = false;
  const _RoomChoice.create() : room = null, createNew = true;

  final MusicRoom? room;
  final bool createNew;
}

class _RoomPickerSheet extends StatefulWidget {
  const _RoomPickerSheet({required this.controller});

  final MusicBetaController controller;

  @override
  State<_RoomPickerSheet> createState() => _RoomPickerSheetState();
}

class _RoomPickerSheetState extends State<_RoomPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final rooms = widget.controller.rooms.where((room) {
      return NamePolicy.normalized(room.name).contains(NamePolicy.normalized(_query));
    }).toList(growable: false);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Where should this song live?',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 6),
              const Text('Choose a Room or create a new one without leaving this flow.'),
              const SizedBox(height: 16),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search Rooms',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: rooms.isEmpty
                    ? const Center(child: Text('No Rooms match that search.'))
                    : ListView.separated(
                        itemCount: rooms.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final room = rooms[index];
                          return InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => Navigator.pop(context, _RoomChoice.room(room)),
                            child: AppSurface(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: <Widget>[
                                  Text(room.icon, style: const TextStyle(fontSize: 26)),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      room.name,
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                  ),
                                  Text('${room.projects.length} songs'),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, const _RoomChoice.create()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create a New Room'),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
