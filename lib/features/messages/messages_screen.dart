import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/player_face.dart';
import '../openmic/people_screen.dart';
import '../openmic/person_thread_sheet.dart';
import '../songs/new_song_flow.dart';
import 'room_thread_sheet.dart';

/// Everything anybody has said to you, in one place.
///
/// Taylor, 14 Sep: "can we also add a chat inbox, or some way of seeing all
/// messages with users on the home page, in an intuitive way, so you don't
/// need to go to each user individually just to see your chat between
/// them." And: "you can create rooms for your band, or message people
/// individually, but it's all in one place, seamless and intuitive."
///
/// So: one list. Every room you are in is a thread -- the band chat exists
/// the moment the band does, with nothing to set up -- and every person you
/// have written to or heard from is a thread. Newest first, what was last
/// said under the name, and a count of what you have not seen. Tap one and
/// the conversation opens over this screen; close it and the count clears.
///
/// Starting a new thread with a person goes through the People screen,
/// where every one of your people already has a message button: the list
/// of who you can write to is the list of your people, and this screen does
/// not keep a second copy of it.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    this.embedded = false,
    this.showTopBar = false,
    this.displayName = '',
    this.onOpenAccount,
    this.onOpenNotifications,
    super.key,
  });

  /// As a tab in the shell, which draws no app bar of its own: the top
  /// bar every tab wears goes at the top instead, when the shell asks.
  final bool embedded;
  final bool showTopBar;
  final String displayName;
  final VoidCallback? onOpenAccount;
  final VoidCallback? onOpenNotifications;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  @override
  void initState() {
    super.initState();
    // Fresh on arrival. The controller's copy is from the last load, which
    // could be from before the thing you came here to read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(BetaScope.of(context, listen: false).refreshThreads());
    });
  }

  Future<void> _open(ThreadSummary thread) async {
    final controller = BetaScope.of(context, listen: false);
    switch (thread.kind) {
      case ThreadKind.room:
        await showRoomThread(
          context,
          repository: controller.repository,
          changes: controller,
          roomId: thread.targetId,
          roomName: thread.name,
        );
      case ThreadKind.person:
        await showPersonThread(
          context,
          repository: controller.repository,
          changes: controller,
          personId: thread.targetId,
          personName: thread.name,
        );
    }
    if (!mounted) return;
    // Seen, now. Marked on the way out rather than the way in, so a thread
    // somebody opened and was interrupted from still shows what they
    // missed the next time.
    await controller.markThreadRead(thread);
    if (!mounted) return;
    await controller.refreshThreads();
  }

  void _newMessage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AppRoutes.people),
        builder: (_) => const PeopleScreen(),
      ),
    );
  }

  /// Starting a room from here.
  ///
  /// Taylor: "you can create rooms for your band, or message people
  /// individually, but it's all in one place." The same dialog the song
  /// flow uses; the band chat exists the moment the band does, so the new
  /// room's thread opens straight away. Inviting people into it is the
  /// room screen's job, as before.
  Future<void> _newRoom() async {
    final controller = BetaScope.of(context, listen: false);
    final room = await showCreateRoomDialog(context, controller);
    if (room == null || !mounted) return;
    await controller.refreshThreads();
    if (!mounted) return;
    await showRoomThread(
      context,
      repository: controller.repository,
      changes: controller,
      roomId: room.id,
      roomName: room.name,
    );
    if (!mounted) return;
    await controller.refreshThreads();
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final threads = controller.threads;
    final said = threads.where((t) => t.lastAt != null).toList(growable: false);
    final quiet = threads.where((t) => t.lastAt == null).toList(growable: false);

    // Two ways to start something, under one pencil: a person, or a
    // room for the band.
    final compose = PopupMenuButton<String>(
      key: const Key('messages_new'),
      tooltip: 'Start something',
      icon: const Icon(Icons.edit_outlined, color: AppColors.cyan),
      color: AppColors.raised,
      onSelected: (value) {
        switch (value) {
          case 'person':
            _newMessage();
          case 'room':
            unawaited(_newRoom());
        }
      },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          key: Key('messages_new_person'),
          value: 'person',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.chat_bubble_outline_rounded),
            title: Text('Message somebody'),
            subtitle: Text('One of your people'),
          ),
        ),
        const PopupMenuItem<String>(
          key: Key('messages_new_room'),
          value: 'room',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.forum_outlined),
            title: Text('Start a room'),
            subtitle: Text('For the band: a thread, and a place for songs'),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              title: const Text('Messages'),
              actions: <Widget>[compose],
            ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: controller.refreshThreads,
          child: ListView(
            key: const Key('messages_list'),
            padding: EdgeInsets.fromLTRB(
                widget.embedded ? 0 : 18, 0, widget.embedded ? 0 : 18, 24),
            children: <Widget>[
              if (widget.embedded &&
                  widget.showTopBar &&
                  widget.onOpenAccount != null &&
                  widget.onOpenNotifications != null)
                AppTopBar(
                  displayName: widget.displayName,
                  onOpenAccount: widget.onOpenAccount!,
                  onOpenNotifications: widget.onOpenNotifications!,
                ),
              if (widget.embedded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 10, 2),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Messages',
                          key: Key('messages_headline'),
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      compose,
                    ],
                  ),
                ),
              if (threads.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(28, 60, 28, 24),
                  child: _NobodyYet(),
                )
              else
                Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: widget.embedded ? 18 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                    for (final thread in said)
                      _ThreadRow(
                        thread: thread,
                        onTap: () => unawaited(_open(thread)),
                      ),
                    if (quiet.isNotEmpty) ...<Widget>[
                      if (said.isNotEmpty) const SizedBox(height: 10),
                      const _Label('YOUR ROOMS · NOTHING SAID YET'),
                      for (final thread in quiet)
                        _ThreadRow(
                          thread: thread,
                          onTap: () => unawaited(_open(thread)),
                        ),
                    ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({required this.thread, required this.onTap});

  final ThreadSummary thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final unread = thread.unread > 0;
    final lastAt = thread.lastAt;
    final line = thread.lastBody == null
        ? (thread.kind == ThreadKind.room
            ? '${thread.memberCount} in the room'
            : 'Nothing said yet')
        : thread.lastAuthorId == controller.repository.currentUserId
            ? 'You: ${thread.lastBody}'
            : thread.kind == ThreadKind.room
                ? '${thread.lastAuthorName}: ${thread.lastBody}'
                : thread.lastBody!;

    return InkWell(
      key: Key('thread_${thread.kind.name}_${thread.targetId}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: <Widget>[
            if (thread.kind == ThreadKind.room)
              _RoomMark(icon: thread.icon ?? '♪')
            else
              PlayerFace(
                name: thread.name,
                color: AppColors.cyan,
                photo: controller.avatarBytesFor(thread.avatarPath),
                size: 42,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          thread.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 14.5,
                            fontWeight:
                                unread ? FontWeight.w800 : FontWeight.w700,
                          ),
                        ),
                      ),
                      if (lastAt != null)
                        Text(
                          _when(lastAt),
                          style: TextStyle(
                            color: unread ? AppColors.cyan : AppColors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: unread ? AppColors.text : AppColors.muted,
                      fontSize: 12.5,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (unread) ...<Widget>[
              const SizedBox(width: 10),
              Container(
                key: Key('thread_unread_${thread.targetId}'),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                constraints: const BoxConstraints(minWidth: 22),
                decoration: BoxDecoration(
                  color: AppColors.cyan,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  thread.unread > 99 ? '99+' : '${thread.unread}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _when(DateTime time) {
    final gap = DateTime.now().difference(time);
    if (gap.inMinutes < 1) return 'now';
    if (gap.inHours < 1) return '${gap.inMinutes}m';
    if (gap.inDays < 1) return '${gap.inHours}h';
    if (gap.inDays < 7) return '${gap.inDays}d';
    return '${time.day}/${time.month}';
  }
}

/// A room, as a mark: its icon in a rounded square, the way the room list
/// draws it, so a band chat and the band's room read as one thing.
class _RoomMark extends StatelessWidget {
  const _RoomMark({required this.icon});

  final String icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.45)),
      ),
      child: Text(icon, style: const TextStyle(fontSize: 19)),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2, top: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.9,
        ),
      ),
    );
  }
}

class _NobodyYet extends StatelessWidget {
  const _NobodyYet();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const <Widget>[
        Icon(Icons.forum_outlined, color: AppColors.muted, size: 40),
        SizedBox(height: 14),
        Text(
          'Nothing here yet.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.text,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Every room you are in is a thread the whole band can talk in, and '
          'every person you write to is one too. They all land here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, height: 1.45),
        ),
      ],
    );
  }
}
