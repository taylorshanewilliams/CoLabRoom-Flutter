import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/routes.dart';
import '../../services/invite_link.dart';
import '../../services/user_facing_error.dart';
import '../lessons/with_birth_month.dart';
import '../rooms/room_detail_screen.dart';
import '../../widgets/note_that_fits.dart';

/// Whether an address is a way into a room: an invitation, or a teacher's
/// lesson link.
bool opensARoom(Uri address) => lessonCodeFrom(address) != null || inviteCodeFrom(address) != null;

/// Joins the room an address names, and says so.
///
/// Two callers. The shell starting up, for the link that brought somebody
/// here (read off the address on the web, handed over by the phone); and the
/// shell already open, for a link tapped or a QR code scanned while the app
/// was in the background. [navigator] is the one that holds the app, so the
/// room opens on top of the shell rather than replacing it. [onJoined] runs
/// once a room is theirs, before anything opens.
Future<void> joinFromAddress(
  Uri address, {
  required BuildContext context,
  required NavigatorState navigator,
  VoidCallback? onJoined,
}) async {
  final lesson = lessonCodeFrom(address);
  if (lesson != null) {
    await _joinLesson(lesson, context: context, navigator: navigator, onJoined: onJoined);
    return;
  }
  final code = inviteCodeFrom(address);
  if (code == null) return;
  final controller = BetaScope.of(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  final before = controller.rooms.map((room) => room.id).toSet();
  try {
    await controller.acceptInvite(code: code);
    if (!context.mounted) return;
    final joined = controller.rooms
        .where((room) => !before.contains(room.id))
        .map((room) => room.name)
        .toList();
    onJoined?.call();
    messenger.showNote(
      joined.isEmpty
          ? 'You are in. The room is under Your music.'
          : 'You are in ${joined.first}. It is under Your music.',
    );
  } catch (error) {
    if (!context.mounted) return;
    // Used, expired, or already yours: said plainly, and the app goes
    // on as it would have without the link.
    messenger.showNote(
      reportAndDescribe(error,
          service: 'app', stage: 'invite.link', route: 'Home'),
    );
  }
}

/// A teacher's lesson link: their own room with the teacher, opened
/// straight away -- "the student could join right into their room".
Future<void> _joinLesson(
  String code, {
  required BuildContext context,
  required NavigatorState navigator,
  VoidCallback? onJoined,
}) async {
  final controller = BetaScope.of(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  try {
    // Lesson links are for people 18 and over for now (0139), so the server
    // may want a birth month before it opens one.
    final joined = await withBirthMonth(
      () => controller.joinLessonLink(code),
      context: context,
      repository: controller.repository,
    );
    if (!context.mounted) return;
    onJoined?.call();
    // Both rooms, when a class link put them in two (0148): they opened a
    // link, not a room with other people in it.
    messenger.showNote(joined.sentence());
    final room = joined.room;
    if (room != null) {
      await navigator.push(MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.room(room.id)),
        builder: (_) => RoomDetailScreen(roomId: room.id),
      ));
    }
  } on NothingSaidAboutAge {
    // The birth month question was closed. Nothing was joined, and nothing
    // is said about it.
  } catch (error) {
    if (!context.mounted) return;
    messenger.showNote(
      reportAndDescribe(error,
          service: 'app', stage: 'lesson.link', route: 'Home'),
    );
  }
}
