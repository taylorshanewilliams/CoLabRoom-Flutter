import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';

/// Inviting somebody you met into a whole catalog.
///
/// The other half of the ask, and a bigger thing than it: an ask is one song,
/// this is everything in a catalog and everything added to it afterwards. So
/// the sheet says the size out loud — the song count sits on every row — and
/// it does not preselect anything. Somebody about to hand over their band's
/// whole library should have to say which one.
///
/// It grants nothing on its own. Same as an ask: the invitation waits, and
/// the person invited is the only one who can turn it into access.
class InviteToCatalogSheet extends StatefulWidget {
  const InviteToCatalogSheet({
    required this.musician,
    required this.repository,
    super.key,
  });

  final Musician musician;
  final MusicRepository repository;

  @override
  State<InviteToCatalogSheet> createState() => _InviteToCatalogSheetState();
}

class _InviteToCatalogSheetState extends State<InviteToCatalogSheet> {
  final TextEditingController _note = TextEditingController();
  List<InvitableRoom>? _rooms;
  String? _roomId;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rooms = await widget.repository.roomsICanInviteTo(widget.musician.id);
      if (!mounted) return;
      setState(() => _rooms = rooms);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rooms = const <InvitableRoom>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'rooms_i_can_invite_to',
          route: 'Invite to a catalog',
        );
      });
    }
  }

  Future<void> _send() async {
    final roomId = _roomId;
    if (roomId == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.repository.inviteMusicianToRoom(
        roomId: roomId,
        profileId: widget.musician.id,
        note: _note.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'invite_musician_to_room',
          route: 'Invite to a catalog',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _rooms;
    final name = widget.musician.displayName;
    final invitable =
        rooms?.where((r) => r.blockedBecause == null).toList() ?? const [];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Invite $name',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              // The difference between this and an ask, stated before the
              // choice rather than discovered after it.
              const Text(
                'A catalog is everything in it, now and later. If you only '
                'want them on one song, ask them to play on it instead.',
                style:
                    TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 16),
              const _Label('Which catalog'),
              const SizedBox(height: 8),
              if (rooms == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (rooms.isEmpty)
                const Text(
                  'You do not own a catalog yet. Only an owner can invite '
                  'somebody into one.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                )
              else
                for (final room in rooms)
                  _RoomRow(
                    room: room,
                    selected: room.id == _roomId,
                    onTap: room.blockedBecause != null
                        ? null
                        : () => setState(() => _roomId = room.id),
                  ),
              if (rooms != null && rooms.isNotEmpty && invitable.isEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '$name is already in, or already invited to, every catalog '
                  'you own.',
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
              if (invitable.isNotEmpty) ...<Widget>[
                const SizedBox(height: 18),
                const _Label('Anything to say', note: 'optional'),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  maxLines: 3,
                  maxLength: 280,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'This is what we have been working on.',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: const TextStyle(
                      color: AppColors.orange, fontSize: 12.5, height: 1.4),
                ),
              ],
              const SizedBox(height: 14),
              FilledButton(
                onPressed: (_roomId == null || _sending)
                    ? null
                    : () => unawaited(_send()),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send the invitation'),
              ),
              const SizedBox(height: 8),
              const Text(
                'They can say no, and they see nothing until they say yes.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomRow extends StatelessWidget {
  const _RoomRow({
    required this.room,
    required this.selected,
    required this.onTap,
  });

  final InvitableRoom room;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final blocked = room.blockedBecause;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected ? AppColors.cyan.withValues(alpha: 0.1) : AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(color: selected ? AppColors.cyan : AppColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: blocked != null
                      ? AppColors.line
                      : (selected ? AppColors.cyan : AppColors.muted),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        room.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: blocked != null
                              ? AppColors.muted
                              : AppColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // The size of what is being handed over, on the row
                      // where the decision is made.
                      Text(
                        '${room.songCount} '
                        '${room.songCount == 1 ? 'song' : 'songs'}',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                if (blocked != null)
                  Text(
                    blocked,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
            ),
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
            ),
          ),
        ],
      ],
    );
  }
}
