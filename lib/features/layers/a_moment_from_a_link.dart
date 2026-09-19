import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import 'song_layers_screen.dart';

/// What `/r/<room>/s/<song>?take=&at=` opens, and what it refuses to open.
///
/// Every Musician, Same Song, 17 September 2026 (schools, item 1). A member
/// lands on the takes with the playhead at the moment the link names; a
/// signed-in stranger gets one plain sentence and nothing else. There is no
/// third answer, and in particular no preview: the 0096 stance is that
/// nothing inside a room has a public page, so a link into a room is worth
/// exactly what membership of that room is worth.
///
/// Membership is read from the library this person's controller already
/// holds, which *is* the answer — the rooms in it are the rooms they are in,
/// and the server would refuse the rest anyway (the takes, the notes and the
/// audio are all behind their own policies). Nothing is fetched here to find
/// out, because fetching would be asking the server a question about a room
/// somebody is not in.
///
/// Somebody signed out never reaches this screen: the address waits in
/// IncomingAddresses while the sign-in screen is up and opens once there is
/// a shell to open it, so they sign in and land.
class MomentFromALink extends StatelessWidget {
  const MomentFromALink({required this.at, super.key});

  final MomentAddress at;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final project = controller.projectById(at.projectId);
    final room = controller.roomForProject(at.projectId);
    // The room in the address has to be the room the song is actually in.
    // Otherwise a link could name a room somebody is in and a song that is
    // not in it, and the address would answer a question nobody asked.
    if (project != null && room != null && room.id == at.roomId) {
      return SongLayersScreen(
        roomId: room.id,
        projectId: project.id,
        songTitle: project.title,
        openAt: at,
      );
    }
    // The library is still arriving. A refusal drawn for the half-second
    // before somebody's own songs load would be a lie told to the person the
    // link was sent to.
    if (controller.loading) {
      return const Scaffold(
        backgroundColor: AppColors.deepNavy,
        body: Center(child: CircularProgressIndicator(color: AppColors.gold)),
      );
    }
    return const _NotYourRoom();
  }
}

/// The whole of what a stranger is told.
///
/// No room name, no song title, no count of anything, and no way in: those
/// would all be facts about a room this person is not in, which is the thing
/// the address is not allowed to leak. The way in is the person who sent the
/// link, so that is what it says.
class _NotYourRoom extends StatelessWidget {
  const _NotYourRoom();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(backgroundColor: AppColors.deepNavy),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'This is inside a room you are not in.',
                key: Key('not_your_room'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Ask whoever sent you the link to add you to it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
