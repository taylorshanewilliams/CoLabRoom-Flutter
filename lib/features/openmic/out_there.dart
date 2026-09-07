import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// What is happening to the things you put up.
///
/// A song went on the Open Mic and nothing ever came back. No count, no
/// signal, no reason to look again — so putting something up felt like
/// dropping it down a well, and the second time was harder than the first.
///
/// **People, not plays.** Somebody who played it eleven times on Tuesday is
/// one person who heard it, which is the number that means something and the
/// only one this app is willing to keep: the table behind it is keyed on
/// (song, listener, day) precisely so a fuller answer cannot be given.
///
/// **And only on your own songs.** A count on somebody else's work is a
/// score, and the moment there is a score there is a leaderboard — which is
/// what 0072 and 0074 spent two migrations making sure this app does not
/// have. You can see how your own song is doing. You can never see how it is
/// doing compared to anybody.
class OutThere extends StatelessWidget {
  const OutThere({
    required this.mine,
    required this.onOpen,
    super.key,
  });

  final List<OpenMicStatus> mine;
  final ValueChanged<OpenMicStatus> onOpen;

  @override
  Widget build(BuildContext context) {
    // Nothing up: nothing here. An empty strip explaining that you have not
    // published anything is a panel telling somebody off.
    if (mine.isEmpty) return const SizedBox.shrink();

    final listeners = mine.fold<int>(0, (sum, s) => sum + s.listeners);
    final offers = mine.fold<int>(0, (sum, s) => sum + s.offers);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.graphic_eq_rounded,
                  size: 14, color: AppColors.gold),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _summary(mine.length, listeners, offers),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: mine.length,
              separatorBuilder: (_, __) => const SizedBox(width: 9),
              itemBuilder: (context, index) => _Card(
                song: mine[index],
                onTap: () => onOpen(mine[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Says the whole state in one line, so somebody who is not going to read
  /// the cards still learns the thing that matters.
  static String _summary(int songs, int listeners, int offers) {
    final what = songs == 1 ? '1 SONG OUT THERE' : '$songs SONGS OUT THERE';
    if (offers > 0) {
      return '$what · ${offers == 1 ? "1 OFFER" : "$offers OFFERS"} WAITING';
    }
    if (listeners > 0) {
      return '$what · ${listeners == 1 ? "1 PERSON HAS" : "$listeners PEOPLE HAVE"} '
          'HEARD IT';
    }
    return '$what · NOBODY HAS HEARD IT YET';
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.song, required this.onTap});

  final OpenMicStatus song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // An offer is somebody putting their hand up, so it outranks every
    // number on the card and takes the colour.
    final waiting = song.offers > 0;
    return SizedBox(
      width: 168,
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(
            color: waiting
                ? AppColors.cyan.withValues(alpha: 0.55)
                : AppColors.line,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  song.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                if (waiting)
                  Text(
                    song.offers == 1
                        ? 'Somebody offered'
                        : '${song.offers} people offered',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.cyan,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                else
                  Text(
                    _heard(song),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Never "0 listeners", which is a number that makes somebody feel worse
  /// than no number at all — and is usually wrong about what happened, since
  /// a song can have been up for an hour.
  static String _heard(OpenMicStatus song) {
    if (song.listeners == 0) return 'Nobody yet';
    if (song.listenersThisWeek > 0) {
      return '${song.listeners} heard it · ${song.listenersThisWeek} this week';
    }
    return song.listeners == 1 ? '1 person heard it' : '${song.listeners} heard it';
  }
}
