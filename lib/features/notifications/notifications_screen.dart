import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/moment_note.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';
import '../../services/invite_link.dart';
import '../../widgets/missed_on_your_phone.dart';
import '../../widgets/problem_report.dart';
import '../../widgets/app_surface.dart';
import '../../domain/musical_roles.dart';
import '../../widgets/play_button.dart';
import '../openmic/report_sheet.dart';
import '../../app/routes.dart';
import '../lessons/with_birth_month.dart';
import '../layers/song_layers_screen.dart';
import '../meeting/add_person_screen.dart';
import '../openmic/musician_profile_screen.dart';
import '../openmic/people_screen.dart';
import '../rooms/room_detail_screen.dart';
import '../messages/room_thread_sheet.dart';
import '../openmic/person_thread_sheet.dart';
import '../workspace/ask_thread_sheet.dart';
import '../workspace/song_workspace_screen.dart';

/// The single inbox: pending invitations you can act on, then everything
/// that has happened since you were last here.
///
/// Invites used to own a whole bottom-nav tab. Once notifications existed
/// that meant one event showed up in two places, and the tab was permanent
/// real estate for something most people encounter a handful of times. They
/// live here now, at the top, as cards you can accept or decline in place.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _busy = false;

  /// [open] is where the thing that was just said yes to now lives. "X is in
  /// Your music now" with nothing to press left somebody to go and find it.
  Future<void> _run(Future<void> Function() action, String success, {VoidCallback? open}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(
        content: Text(success),
        action: open == null ? null : SnackBarAction(label: 'Open', onPressed: open),
      ));
    } on NothingSaidAboutAge {
      // A lesson code, and the birth month question was closed rather than
      // answered (0139). Nothing happened, so nothing is said.
    } catch (error) {
      // Was `Text(error.toString())`, which is how a musician standing in a
      // room came to be shown a Postgres unique-constraint violation. The
      // detail goes to the error table now, and the moment somebody has just
      // been let down is the only moment they will describe what they were
      // doing — so there is a way to say more, right there.
      if (!mounted) {
        // Nobody left to tell, and still worth recording. An error that only
        // exists while somebody is looking at it is the state this app spent
        // three weeks in.
        reportAndDescribe(error,
            service: 'app', stage: 'invite', route: 'Inbox');
        return;
      }
      showProblem(context, error,
          service: 'app', stage: 'invite', route: 'Inbox');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// No thanks, with a few seconds to take it back.
  ///
  /// "No thanks" used to decline on the spot, and a thumb that meant Join
  /// had no way back (audit, 17 September 2026). The server has no way back
  /// either — a decline closes the invitation and tells the sender at once —
  /// so the card goes now and the answer goes when Undo does.
  ///
  /// The sending hangs off the snackbar, not this screen. The snackbar
  /// belongs to the app's messenger and carries on over whatever screen is
  /// next, so leaving the inbox still sends it; any way it closes other than
  /// Undo counts as meaning it.
  void _declineWithUndo({
    required String inviteId,
    required String said,
    required Future<void> Function() send,
  }) {
    final controller = BetaScope.of(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    controller.holdDecline(inviteId);
    messenger.hideCurrentSnackBar();
    final shown = messenger.showSnackBar(SnackBar(
      content: Text(said),
      // An action makes a snackbar stay up until it is dismissed, and this
      // one has to go on its own for the answer to be sent.
      persist: false,
      // Four seconds is plenty to see Undo and tap it, and not enough with
      // TalkBack or VoiceOver: the message is read out first, then it takes
      // a swipe to Undo and a double tap. `persist: false` also switches off
      // what used to keep a snackbar with an action up until they got to it,
      // so without this the decline went before they could reach Undo
      // (review of the audit fixes, 17 September 2026). Thirty seconds is the
      // middle of what Android's own "Time to take action" setting offers,
      // and the answer still goes during the same visit.
      duration: MediaQuery.accessibleNavigationOf(context)
          ? const Duration(seconds: 30)
          : const Duration(seconds: 4),
      action: SnackBarAction(
        key: Key('inbox_undo_$inviteId'),
        label: 'Undo',
        onPressed: () => controller.releaseDecline(inviteId),
      ),
    ));
    unawaited(shown.closed.then((_) async {
      try {
        await controller.sendHeldDecline(inviteId, send);
      } catch (error) {
        if (!mounted) {
          reportAndDescribe(error,
              service: 'app', stage: 'invite', route: 'Inbox');
          return;
        }
        showProblem(context, error,
            service: 'app', stage: 'invite', route: 'Inbox');
      }
    }));
  }

  Future<void> _useCode() async {
    final controller = BetaScope.of(context);
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinCodeDialog(),
    );
    if (code == null || code.trim().isEmpty || !mounted) return;
    // A teacher's lesson code or link makes a room rather than joining one.
    final lesson = lessonCodeFromText(code);
    if (lesson != null) {
      await _run(
        () async {
          // Lesson links are for people 18 and over for now, so the server
          // may want a birth month before it opens one (0139).
          await withBirthMonth(
            () => controller.joinLessonLink(lesson),
            context: context,
            repository: controller.repository,
          );
        },
        'Your lesson room is ready. It is under Your music.',
      );
      return;
    }
    // Somebody's own code, or the link their QR code holds: this is the box
    // people reach for, and it said "That invite code is not valid."
    final person = meetingCodeFromText(code);
    if (person != null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.meet(person)),
        builder: (_) => AddPersonScreen(code: person, repository: controller.repository),
      ));
      return;
    }
    await _run(
      () => controller.acceptInvite(code: inviteCodeFromText(code) ?? code.trim()),
      'Joined. It is under Your music.',
    );
  }

  void _openSong(String projectId) {
    // From a snackbar, which can outlive this screen.
    if (!mounted) return;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.song(projectId)),
      builder: (_) => SongWorkspaceScreen(projectId: projectId),
    )));
  }

  /// Somebody left a note at a moment of a recording of yours.
  ///
  /// Straight to the takes, which is where the recording, the marks on its
  /// lane and the note itself are -- not the words. Opening the song would
  /// leave the person on the lyrics with one more tap to work out.
  ///
  /// The card itself is the note's address. `notifications` has no column for
  /// the thing a notification is about, so who left it and the words the card
  /// is already showing are how the screen picks the right one out of a song
  /// two people have both pinned something on.
  void _openTakesAtTheNote(SongProject project, AppNotification about) {
    if (!mounted) return;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.songTakes(project.id)),
      builder: (_) => SongLayersScreen(
        roomId: project.roomId,
        projectId: project.id,
        songTitle: project.title,
        openNote: NoteToOpen(authorId: about.actorId, bodyStart: about.body),
      ),
    )));
  }

  void _openRoom(String roomId) {
    if (!mounted) return;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.room(roomId)),
      builder: (_) => RoomDetailScreen(roomId: roomId),
    )));
  }

  /// Saying a song is wrong, from the card it arrived on.
  Future<void> _reportAsk(AskForMe ask) async {
    final controller = BetaScope.of(context, listen: false);
    final sent = await showReportSheet(
      context,
      repository: controller.repository,
      kind: 'song',
      about: ask.songTitle,
      profileId: ask.askedById,
      projectId: ask.projectId,
    );
    if (sent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Report sent. Somebody reads every one of these.'),
      ));
    }
  }

  /// Making it stop, which is a different thing from reporting it.
  ///
  /// Blocking also closes anything open between the two of you, so the ask
  /// leaves this inbox in the same breath — see block_user in 0063.
  Future<void> _blockAsker(AskForMe ask) async {
    final who = ask.askedById;
    if (who == null) return;
    final controller = BetaScope.of(context, listen: false);
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text('Block ${ask.askedByName}?'),
        content: const Text(
          'They will not be able to ask you again or see anything of yours, '
          'and this ask leaves your inbox. You can undo it in your account.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await _run(() => controller.repository.blockUser(who),
        '${ask.askedByName} is blocked.');
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final invites = controller.invites;
    final asks = controller.asksForMe;
    final roomInvites = controller.roomInvitesForMe;
    final notifications = controller.notifications;
    final empty = invites.isEmpty &&
        asks.isEmpty &&
        roomInvites.isEmpty &&
        notifications.isEmpty;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Inbox'),
        actions: <Widget>[
          if (notifications.any((n) => !n.isRead))
            TextButton(
              onPressed: () => controller.markAllNotificationsRead(),
              child: const Text('Mark all read'),
            ),
          // Reading something was never the same as being done with it, and
          // until now there was no way to say the second thing at all: an
          // inbox could only grow.
          if (notifications.any((n) => n.isRead))
            TextButton(
              key: const Key('inbox_clear_read'),
              onPressed: () => unawaited(controller.deleteReadNotifications()),
              child: const Text('Clear read'),
            ),
          IconButton(
            key: const Key('inbox_use_code'),
            tooltip: 'Join with an invite code',
            onPressed: _useCode,
            icon: const Icon(Icons.key_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: empty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(30),
                  child: Text(
                    'Nothing new.\nInvitations and activity land here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                children: <Widget>[
                  // Above everything, and usually not there at all.
                  //
                  // It draws nothing unless this inbox holds something that
                  // could not have reached the phone. That is what stops it
                  // being a campaign for notifications and makes it a report
                  // of a cost already paid.
                  MissedOnYourPhone(notifications: notifications),
                  // First, above invitations. Somebody has asked *you*, by
                  // name, to play something — that is the most personal thing
                  // this inbox can hold and the one thing in it that another
                  // musician is waiting on.
                  if (asks.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Asked of you'),
                    for (final ask in asks) ...<Widget>[
                      _AskCard(
                        ask: ask,
                        busy: _busy,
                        onAccept: () => _run(
                          () => controller.answerAsk(ask, accept: true),
                          '${ask.songTitle} is in Your music now.',
                          open: () => _openSong(ask.projectId),
                        ),
                        onDecline: () => _run(
                          () => controller.answerAsk(ask, accept: false),
                          'Passed. They have been told.',
                        ),
                        onReport: () => unawaited(_reportAsk(ask)),
                        onBlock: () => unawaited(_blockAsker(ask)),
                        // Before yes or no: a question back. "What key?"
                        // and "would next week do?" are most of what an
                        // answer actually is, and until now the card could
                        // only say one of two words.
                        onReply: () => unawaited(showAskThread(
                          context,
                          repository: controller.repository,
                          askId: ask.id,
                          headline: ask.headline,
                          note: ask.note,
                        )),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  // Somebody inviting you into a room by name, rather
                  // than by emailing you a code. Same section as the coded
                  // invitations below, because to a person they are the same
                  // thing: somebody wants you in their band.
                  if (roomInvites.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Invitations'),
                    for (final invite in roomInvites) ...<Widget>[
                      _RoomInviteCard(
                        invite: invite,
                        busy: _busy,
                        onAccept: () => _run(
                          () => controller.answerRoomInvite(invite,
                              accept: true),
                          '${invite.roomName} is in Your music now.',
                          open: () => _openRoom(invite.roomId),
                        ),
                        onDecline: () => _declineWithUndo(
                          inviteId: invite.id,
                          said: 'Declined. They will be told.',
                          send: () => controller.answerRoomInvite(invite,
                              accept: false),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (invites.isNotEmpty) ...<Widget>[
                    // No second heading. The note above says these belong in
                    // the same section "because to a person they are the same
                    // thing: somebody wants you in their band" — and then the
                    // code printed INVITATIONS twice whenever both lists had
                    // something in them, which is most of the time somebody
                    // is being invited at all.
                    if (roomInvites.isEmpty) const _SectionLabel('Invitations'),
                    for (final invite in invites) ...<Widget>[
                      _InviteCard(
                        invite: invite,
                        busy: _busy,
                        onJoin: () => _run(
                          () => controller.acceptInvite(invite: invite),
                          invite.isProjectScoped
                              ? 'Song joined. Find it in Your music.'
                              : 'Room joined. Its songs are in Your music.',
                          open: () => invite.projectId != null
                              ? _openSong(invite.projectId!)
                              : _openRoom(invite.roomId),
                        ),
                        onDecline: () => _declineWithUndo(
                          inviteId: invite.id,
                          said: 'Invitation declined.',
                          send: () => controller.declineInvite(invite),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (notifications.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Activity'),
                    for (final notification in notifications) ...<Widget>[
                      Dismissible(
                        key: ValueKey<String>('notification-${notification.id}'),
                        direction: DismissDirection.endToStart,
                        background: const _ClearBackground(),
                        onDismissed: (_) =>
                            unawaited(controller.deleteNotification(notification)),
                        child: _NotificationCard(
                          notification: notification,
                          onTap: () {
                            unawaited(
                                controller.markNotificationRead(notification));
                            // A message opens the thread it came from: the
                            // sender rides on the notification as its actor
                            // and the title is their name.
                            // Said in a room, it opens the room's thread:
                            // the room rides on the notification, and the
                            // title is "Name · Room".
                            // A student joining through a lesson link
                            // arrives as an accepted invitation with the
                            // new room on it: the card opens that room's
                            // thread, where the lesson starts.
                            // Somebody said yes to a song you asked them
                            // onto: the song. It used to open nothing -- the
                            // one song_ask card in production ("Taylor is
                            // in") went nowhere.
                            // An ask still waiting on you stays with its own
                            // card, where it is answered.
                            if (notification.type == NotificationType.songAsk &&
                                notification.projectId != null &&
                                controller.projectById(notification.projectId!) != null &&
                                !asks.any((ask) => ask.projectId == notification.projectId)) {
                              _openSong(notification.projectId!);
                            }
                            // An invitation you have already taken: the room.
                            // The card above does the answering while it is
                            // open.
                            if (notification.type == NotificationType.inviteReceived &&
                                notification.roomId != null &&
                                controller.roomById(notification.roomId!) != null) {
                              _openRoom(notification.roomId!);
                            }
                            // Accepted onto one song: that song.
                            if (notification.type == NotificationType.inviteAccepted &&
                                notification.projectId != null &&
                                controller.projectById(notification.projectId!) != null) {
                              _openSong(notification.projectId!);
                            } else if (notification.type ==
                                    NotificationType.inviteAccepted &&
                                notification.roomId != null) {
                              final room = controller.roomById(notification.roomId!);
                              unawaited(showRoomThread(
                                context,
                                controller: controller,
                                roomId: notification.roomId!,
                                roomName: room?.name ?? 'Lessons',
                              ));
                            }
                            if (notification.type ==
                                    NotificationType.directMessage &&
                                notification.roomId != null) {
                              final room = controller.roomById(notification.roomId!);
                              final title = notification.title;
                              final dot = title.lastIndexOf(' · ');
                              unawaited(showRoomThread(
                                context,
                                controller: controller,
                                roomId: notification.roomId!,
                                roomName: room?.name ??
                                    (dot < 0 ? title : title.substring(dot + 3)),
                              ));
                            } else if (notification.type ==
                                    NotificationType.directMessage &&
                                notification.actorId != null) {
                              unawaited(showPersonThread(
                                context,
                                repository: controller.repository,
                                changes: controller,
                                personId: notification.actorId!,
                                personName: notification.title,
                              ));
                            }
                            // News about a song opens the song. "Mountains
                            // is ready" used to be a card that went nowhere:
                            // it marked itself read and left the person to
                            // find the song by hand. Only the two kinds that
                            // imply you can open it -- an analysis you ran,
                            // an update on a song of yours. An ask is left to
                            // its own card, because the person asked cannot
                            // open the song until they say yes.
                            if ((notification.type ==
                                        NotificationType.analysisReady ||
                                    notification.type ==
                                        NotificationType.projectUpdate) &&
                                notification.projectId != null) {
                              final id = notification.projectId!;
                              unawaited(Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  settings:
                                      RouteSettings(name: AppRoutes.song(id)),
                                  builder: (_) =>
                                      SongWorkspaceScreen(projectId: id),
                                ),
                              ));
                            }
                            // A call started in a room: the room, where the
                            // bar at the top says who is in it and has Join.
                            if (notification.type ==
                                    NotificationType.callStarted &&
                                notification.roomId != null) {
                              unawaited(Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  settings: RouteSettings(
                                      name: AppRoutes.room(
                                          notification.roomId!)),
                                  builder: (_) => RoomDetailScreen(
                                      roomId: notification.roomId!),
                                ),
                              ));
                            }
                            // A note at a moment: the takes, opened on it.
                            if (notification.type ==
                                    NotificationType.momentNote &&
                                notification.projectId != null) {
                              final song = controller
                                  .projectById(notification.projectId!);
                              if (song != null) {
                                _openTakesAtTheNote(song, notification);
                              }
                            }
                            // Somebody asked to add you: Your people is
                            // where a request is answered, and it lists the
                            // ones waiting on you first.
                            if (notification.type ==
                                NotificationType.connectionRequest) {
                              unawaited(Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  settings: const RouteSettings(
                                      name: AppRoutes.people),
                                  builder: (_) => const PeopleScreen(),
                                ),
                              ));
                            }
                            // Somebody added you back: their page, to see
                            // who you are now connected to.
                            if (notification.type ==
                                    NotificationType.connectionAccepted &&
                                notification.actorId != null) {
                              unawaited(Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  settings: RouteSettings(
                                      name: AppRoutes.musician(
                                          notification.actorId!)),
                                  builder: (_) => MusicianProfileScreen(
                                    profileId: notification.actorId!,
                                    repository: controller.repository,
                                  ),
                                ),
                              ));
                            }
                            // Somebody you left a note about has turned up:
                            // the useful next thing is their page.
                            if (notification.type ==
                                    NotificationType.wantMatched &&
                                notification.actorId != null) {
                              unawaited(Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => MusicianProfileScreen(
                                    profileId: notification.actorId!,
                                    repository: controller.repository,
                                  ),
                                ),
                              ));
                            }
                          },
                          // A swipe on its own is not discoverable, and the
                          // inbox is where somebody arrives already annoyed.
                          onClear: () => unawaited(
                              controller.deleteNotification(notification)),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              ),
      ),
    );
  }
}

/// Somebody asking you, by name, to play on their song.
///
/// The card carries the song's title and what they said, and nothing else —
/// which is not a design choice about density but the literal extent of what
/// the person asked is allowed to see. Deciding does not require access;
/// accepting is what grants it, and it grants that one song rather than the
/// room it sits in.
class _AskCard extends StatelessWidget {
  const _AskCard({
    required this.ask,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
    required this.onReport,
    required this.onBlock,
    required this.onReply,
  });

  final AskForMe ask;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onReply;

  /// Somewhere to say this is wrong, and somewhere to make it stop.
  ///
  /// A stranger's song now plays inside this card, which makes the inbox a
  /// place unreviewed audio from somebody you have never met reaches you —
  /// and every surface like that needs both of these within reach. It is
  /// also what App Store 1.2 asks for wherever user content appears, and
  /// the one surface in the app that had neither.
  final VoidCallback onReport;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Hear it first, then read about it. Somebody deciding whether to
          // spend an evening on a stranger's song makes that decision by ear
          // in about ten seconds, and every second before the play button is
          // a second spent reading instead.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if ((ask.storagePath ?? '').isNotEmpty) ...<Widget>[
                PlayButton(
                  storagePath: ask.storagePath!,
                  durationMs: ask.durationMs,
                  title: ask.songTitle,
                  byline: ask.askedByName,
                  songId: ask.projectId,
                  size: 38,
                ),
                const SizedBox(width: 11),
              ],
              Expanded(
                child: Text(
                  ask.headline,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.3,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: const Key('ask_card_more'),
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz_rounded,
                    size: 20, color: AppColors.muted),
                onSelected: (choice) =>
                    choice == 'report' ? onReport() : onBlock(),
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                      value: 'report', child: Text('Report this')),
                  PopupMenuItem<String>(
                      value: 'block',
                      child: Text('Block ${ask.askedByName}')),
                ],
              ),
            ],
          ),
          // What the song is. Every fact here was already in the database
          // and none of it used to reach the person being asked.
          if (ask.brief != null) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              ask.brief!,
              style: const TextStyle(
                  color: AppColors.cyan, fontSize: 12, height: 1.35),
            ),
          ],
          if (ask.partsOnIt.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              // Words, not a number. A count of takes would be a tally of
              // somebody's work, and it tells the person answering nothing
              // about whether there is a hole shaped like them.
              'Already on it: ${ask.partsOnIt.map(MusicalRole.labelFor).join(', ').toLowerCase()}',
              style: const TextStyle(
                  color: AppColors.muted, fontSize: 12, height: 1.35),
            ),
          ],
          // What answering means, before they answer. The sentence was
          // settled when the ask was sent and the database will not let it
          // change, which is the whole of its value: a co-writing argument is
          // two honest memories of a session nobody wrote down.
          if (ask.terms.notice != null) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              ask.terms.notice!,
              key: const Key('ask_card_terms'),
              style: const TextStyle(
                  color: AppColors.gold, fontSize: 12, height: 1.35),
            ),
          ],
          if (ask.note.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              '“${ask.note.trim()}”',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 13.5,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 6),
          // Both promises, half the words.
          //
          // "Saying yes puts this one song in your library. Nothing else of
          // theirs opens up." says exactly the right two things and takes two
          // sentences to do it. The instinct behind it — saying what a tap
          // costs before the tap — is the best habit this app has, and none of
          // it is given up here. What goes is the second verb.
          const Text(
            'This song joins your library — nothing else of theirs.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cyan,
                    foregroundColor: AppColors.ink,
                  ),
                  child: const Text("I'm in"),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const Key('ask_card_reply'),
                onPressed: busy ? null : onReply,
                style: TextButton.styleFrom(foregroundColor: AppColors.cyan),
                child: const Text('Reply'),
              ),
              // A real answer, not a dismissal. Somebody who asked deserves
              // to hear no rather than nothing, and an ask that can only be
              // answered with silence is one nobody sends twice.
              TextButton(
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                child: const Text('Not this one'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Somebody inviting you into a room of theirs.
///
/// Bigger than an ask and drawn to say so: an ask is one song, this is
/// everything in a room and everything added to it later. The card names
/// the room rather than counting its songs, because the count somebody
/// sees before accepting would be out of date the moment they did.
class _RoomInviteCard extends StatelessWidget {
  const _RoomInviteCard({
    required this.invite,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final RoomInviteForMe invite;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            invite.headline,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
          if (invite.note.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              '“${invite.note.trim()}”',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 13.5,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            'Every song in the room, now and later. Leave any time.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  key: Key('room_invite_join_${invite.id}'),
                  onPressed: busy ? null : onAccept,
                  style: _answerTouch,
                  child: const Text('Join'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: Key('room_invite_decline_${invite.id}'),
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(foregroundColor: AppColors.muted)
                    .merge(_answerTouch),
                child: const Text('No thanks'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Join and No thanks take a 48-pixel-tall touch whatever the platform.
///
/// Material pads a button out to 48 only on a phone. On a desk the density
/// is compact and the touch shrinks to 40, around a button drawn 32 tall,
/// and these two are the answer to somebody wanting you in their band
/// (audit, 17 September 2026). The extra touch is invisible. On a phone the
/// card looks exactly as it did; on a desk the buttons are drawn at a phone's
/// 40 rather than 32.
const ButtonStyle _answerTouch = ButtonStyle(
  tapTargetSize: MaterialTapTargetSize.padded,
  visualDensity: VisualDensity.standard,
);

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(
        text.toUpperCase(),
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

class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.invite,
    required this.busy,
    required this.onJoin,
    required this.onDecline,
  });

  final BetaInvite invite;
  final bool busy;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final initial = invite.inviterName.trim().isEmpty
        ? '?'
        : invite.inviterName.trim().substring(0, 1).toUpperCase();
    return AppSurface(
      color: AppColors.raised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              // The same ground and letter as your own initials in the top
              // bar. Left to CircleAvatar, the letter came out pale blue on
              // flat blue, 3.37:1 (audit, 17 September 2026).
              CircleAvatar(
                key: const Key('invite_face'),
                backgroundColor: AppColors.faceGround.first,
                foregroundColor: AppColors.faceLetter,
                child: Text(initial),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      invite.isProjectScoped ? invite.projectTitle ?? 'A song' : invite.roomName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (invite.isProjectScoped)
                      Text(
                        'One song in ${invite.roomName} · not the rest of the room',
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    Text('${invite.inviterName} invited you as ${invite.role.name}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Join first and filled, No thanks quiet and second — the same
          // shape as the room invitation directly above it. These two cards
          // asked the identical question in opposite orders, with the
          // dismissive answer sitting where the eye and the thumb both go
          // first on one of them.
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  key: Key('invite_join_${invite.id}'),
                  onPressed: busy ? null : onJoin,
                  style: _answerTouch,
                  child: const Text('Join'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: Key('invite_decline_${invite.id}'),
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(foregroundColor: AppColors.muted)
                    .merge(_answerTouch),
                child: const Text('No thanks'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What shows behind a notification on its way out.
class _ClearBackground extends StatelessWidget {
  const _ClearBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 18),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.delete_outline_rounded,
          size: 19, color: Color(0xFFFF718B)),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.onTap,
    required this.onClear,
  });

  final AppNotification notification;
  final VoidCallback onTap;
  final VoidCallback onClear;

  IconData get _icon {
    switch (notification.type) {
      case NotificationType.inviteReceived:
        return Icons.mail_outline_rounded;
      case NotificationType.inviteAccepted:
        return Icons.check_circle_outline_rounded;
      case NotificationType.inviteDeclined:
        return Icons.cancel_outlined;
      case NotificationType.projectUpdate:
        return Icons.edit_note_rounded;
      case NotificationType.analysisReady:
        // The same icon the room list uses to mark a song that has audio, so
        // "your analysis finished" and "this song has a recording" read as one
        // idea in two places rather than two unrelated ones.
        return Icons.graphic_eq_rounded;
      case NotificationType.songAsk:
        // The same megaphone as "Ask the room", so an ask arriving and an
        // ask being sent read as the two ends of one thing.
        return Icons.campaign_outlined;
      case NotificationType.directMessage:
        return Icons.chat_bubble_outline_rounded;
      case NotificationType.wantMatched:
        return Icons.person_search_rounded;
      case NotificationType.connectionRequest:
        return Icons.person_add_alt_1_rounded;
      case NotificationType.connectionAccepted:
        return Icons.how_to_reg_rounded;
      case NotificationType.callStarted:
        return Icons.videocam_rounded;
      case NotificationType.momentNote:
        // A pin, because that is the verb: the note is pinned to a second of
        // the recording rather than said about the song in general.
        return Icons.push_pin_outlined;
      case NotificationType.unfamiliar:
        return Icons.notifications_none_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(19)),
      child: AppSurface(
        color: notification.isRead ? AppColors.surface : AppColors.raised,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(_icon, color: notification.isRead ? AppColors.muted : AppColors.cyan),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    notification.title,
                    style: TextStyle(
                      fontWeight: notification.isRead ? FontWeight.w600 : FontWeight.w800,
                    ),
                  ),
                  if (notification.body.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(notification.body, style: const TextStyle(color: AppColors.muted)),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    _relativeTime(notification.createdAt),
                    style: const TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!notification.isRead)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(top: 4, left: 8),
                decoration: const BoxDecoration(color: AppColors.cyan, shape: BoxShape.circle),
              ),
            Tooltip(
              message: 'Clear this notification',
              child: InkResponse(
                onTap: onClear,
                radius: 22,
                // The glyph stays 16. The *target* was 24x18, which is under
                // the 24x24 floor in WCAG 2.2 SC 2.5.8 — and this is a
                // dismiss button sitting beside a row somebody wants to open,
                // so a miss either loses the thing they meant to read or
                // clears the thing they meant to keep.
                //
                // Padding rather than a bigger icon: 44 is Apple's number and
                // 48 is Material's, and a close cross drawn at either is a
                // statement rather than a dismissal.
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(17, 14, 11, 14),
                  child: Icon(Icons.close_rounded,
                      size: 16, color: AppColors.muted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }
}

class _JoinCodeDialog extends StatefulWidget {
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join with a code'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: TextField(
          key: const Key('join_code_field'),
          controller: _code,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Code or link',
            helperMaxLines: 3,
            helperText: 'An invitation, a teacher\'s lesson code, or somebody\'s own code from their QR.',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value);
          },
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        // Waits for a code. With nothing typed it used to close the box and
        // say the code was not valid.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _code,
          builder: (context, value, _) => FilledButton(
            key: const Key('join_code_submit'),
            onPressed: value.text.trim().isEmpty ? null : () => Navigator.pop(context, value.text),
            child: const Text('Join'),
          ),
        ),
      ],
    );
  }
}
