import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/calls.dart';
import '../../services/user_facing_error.dart';
import 'birth_month_sheet.dart';
import 'call_screen.dart';

/// Into a room's call, from wherever the button is.
///
/// Birth month first if it has never been asked; a clear no, with the reason
/// and what is coming, for somebody under 18; otherwise the call.
Future<void> openRoomCall(
  BuildContext context, {
  required String roomId,
  required String roomName,
  required MusicRepository repository,
  JoinCall? join,
}) async {
  CallStanding standing;
  try {
    standing = await repository.myCallStanding();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(reportAndDescribe(error, service: 'app', stage: 'calls.standing', route: 'Room')),
    ));
    return;
  }
  if (!context.mounted) return;
  if (standing == CallStanding.unknown) {
    standing = await askBirthMonth(context, repository) ?? CallStanding.unknown;
    if (standing == CallStanding.unknown || !context.mounted) return;
  }
  if (standing == CallStanding.minor) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: const Text('Calls are 18+ for now'),
        content: const Text(
          'Calls for 13 to 17 are coming, with a parent or guardian who says who you can '
          'call and can join any call. Everything else in the room is yours to use now: '
          'the songs, Follow me, and what your teacher leaves you to practise.',
        ),
        actions: <Widget>[
          FilledButton(
            key: const Key('call_minor_ok'),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    settings: const RouteSettings(name: 'Call'),
    builder: (_) => CallScreen(roomId: roomId, roomName: roomName, repository: repository, join: join),
  ));
}

/// The room's call, at the top of the room: "Call the room" when it is quiet,
/// and who is in it, with Join, when it is not.
///
/// It looks every few seconds while the room is on screen and stops when it is
/// not; the push when a call starts is for everybody who is somewhere else.
class RoomCallBar extends StatefulWidget {
  const RoomCallBar({
    required this.roomId,
    required this.roomName,
    required this.repository,
    required this.me,
    this.join,
    this.lookEvery = const Duration(seconds: 10),
    super.key,
  });

  final String roomId;
  final String roomName;
  final MusicRepository repository;

  /// The signed-in person, so "you are in this call on another device" is
  /// not "somebody is in a call".
  final String me;
  final JoinCall? join;
  final Duration lookEvery;

  @override
  State<RoomCallBar> createState() => _RoomCallBarState();
}

class _RoomCallBarState extends State<RoomCallBar> {
  List<InCallPerson> _inCall = const <InCallPerson>[];
  Timer? _look;

  @override
  void initState() {
    super.initState();
    unawaited(_lookNow());
    _look = Timer.periodic(widget.lookEvery, (_) => unawaited(_lookNow()));
  }

  @override
  void dispose() {
    _look?.cancel();
    super.dispose();
  }

  Future<void> _lookNow() async {
    try {
      final people = await widget.repository.roomCall(widget.roomId);
      if (mounted) setState(() => _inCall = people);
    } catch (_) {
      // Quietly: the next look will do.
    }
  }

  Future<void> _open() async {
    await openRoomCall(
      context,
      roomId: widget.roomId,
      roomName: widget.roomName,
      repository: widget.repository,
      join: widget.join,
    );
    if (mounted) unawaited(_lookNow());
  }

  @override
  Widget build(BuildContext context) {
    final others = _inCall.where((person) => person.userId != widget.me).toList();
    final meElsewhere = _inCall.any((person) => person.userId == widget.me);
    if (others.isEmpty && !meElsewhere) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const Key('room_call_start'),
          onPressed: () => unawaited(_open()),
          icon: const Icon(Icons.videocam_outlined, size: 19),
          label: const Text('Call the room'),
        ),
      );
    }
    final names = others.map((person) => person.displayName).toList();
    final who = switch (names.length) {
      0 => 'You are in this call on another device',
      1 => '${names.single} is in a call',
      2 => '${names.first} and ${names.last} are in a call',
      _ => '${names.first} and ${names.length - 1} others are in a call',
    };
    return Container(
      key: const Key('room_call_live'),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.14),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.videocam_rounded, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              who,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('room_call_join'),
            onPressed: () => unawaited(_open()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: AppColors.ink),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}
