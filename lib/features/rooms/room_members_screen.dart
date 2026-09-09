import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/player_face.dart';

/// Who is actually in this room.
///
/// It has said "3 members" since the day it shipped and has never been able
/// to say which three — and there has been no way to change it either. The
/// app could add people and never remove one, which is not a small omission:
/// bands are not permanent. Somebody leaves, somebody was added by mistake,
/// somebody played on one record. An app where membership only ever grows is
/// one whose owners stop adding anybody.
class RoomMembersScreen extends StatefulWidget {
  const RoomMembersScreen({required this.roomId, super.key});

  final String roomId;

  @override
  State<RoomMembersScreen> createState() => _RoomMembersScreenState();
}

class _RoomMembersScreenState extends State<RoomMembersScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    CurrentRoute.enter('Room members');
  }

  Future<void> _run(Future<void> Function() action, String said) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(said)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(reportAndDescribe(
            error,
            service: 'app',
            stage: 'room_membership',
            route: 'Room members',
          )),
        ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(
    MusicBetaController controller,
    MusicRoom room,
    RoomMember member,
  ) async {
    // Confirmed, and named. "Remove member?" is the dialog somebody taps
    // through without reading; the person's name and what it actually costs
    // them is the version that gets read.
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text('Remove ${member.displayName}?'),
        content: Text(
          'They lose access to ${room.name} and every song in it. Anything '
          'they already recorded stays — their takes are part of those songs '
          'now.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run(
      () => controller.removeRoomMember(roomId: room.id, userId: member.userId),
      '${member.displayName} is no longer in ${room.name}.',
    );
  }

  Future<void> _leave(MusicBetaController controller, MusicRoom room) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text('Leave ${room.name}?'),
        content: const Text(
          'You lose access to its songs. Whoever owns it can invite you back.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run(() => controller.leaveRoom(room.id), 'You left ${room.name}.');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final room = controller.rooms.where((r) => r.id == widget.roomId).firstOrNull;

    if (room == null) {
      return Scaffold(
        backgroundColor: AppColors.deepNavy,
        appBar: AppBar(
          backgroundColor: AppColors.deepNavy,
          title: const Text('Who is in it'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'This room is no longer here.',
              style: TextStyle(color: AppColors.muted),
            ),
          ),
        ),
      );
    }

    final me = controller.repository.currentUserId;
    final iOwnIt = room.accountId == me;
    final members = <RoomMember>[
      // The owner first, always. It is the one fact on this screen that
      // decides what everybody else can do here.
      ...room.members.where((m) => m.userId == room.accountId),
      ...room.members.where((m) => m.userId != room.accountId),
    ];

    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Who is in it', style: TextStyle(fontSize: 17)),
            Text(
              room.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 11),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            for (final member in members)
              _MemberRow(
                member: member,
                isOwner: member.userId == room.accountId,
                isMe: member.userId == me,
                // Owners remove anybody but themselves; everybody else can
                // only remove themselves, which is how leaving works.
                onRemove: member.userId == room.accountId
                    ? null
                    : (iOwnIt
                        ? () => unawaited(_remove(controller, room, member))
                        : (member.userId == me
                            ? () => unawaited(_leave(controller, room))
                            : null)),
              ),
            const SizedBox(height: 18),
            if (iOwnIt)
              const Text(
                'Removing somebody takes them out of every song in this '
                'room too. Takes they already recorded stay where they '
                'are — they are part of those songs now.',
                style: TextStyle(
                    color: AppColors.muted, fontSize: 12.5, height: 1.45),
              )
            else
              // Said out loud so nobody has to guess why there are no
              // controls beside the other names.
              Text(
                'Only ${room.name}’s owner can add or remove people. You '
                'can leave whenever you like.',
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
          ],
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isOwner,
    required this.isMe,
    required this.onRemove,
  });

  final RoomMember member;
  final bool isOwner;
  final bool isMe;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: <Widget>[
              // Their room colour, which is the same one their takes are
              // drawn in everywhere else — so the list of people matches the
              // lanes on the song.
              PlayerFace(
                name: member.displayName,
                color: Color(member.colorValue),
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      isMe ? '${member.displayName} (you)' : member.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isOwner ? 'Owner' : _roleWord(member.role),
                      style: TextStyle(
                        color: isOwner ? AppColors.gold : AppColors.muted,
                        fontSize: 11.5,
                        fontWeight:
                            isOwner ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                TextButton(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.muted,
                  ),
                  child: Text(
                    isMe ? 'Leave' : 'Remove',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The role in words somebody outside the codebase would use.
  static String _roleWord(RoomRole role) {
    switch (role) {
      case RoomRole.owner:
        return 'Owner';
      case RoomRole.editor:
        return 'Can record and edit';
      case RoomRole.commenter:
        return 'Can comment';
      case RoomRole.viewer:
        return 'Can listen';
    }
  }
}
