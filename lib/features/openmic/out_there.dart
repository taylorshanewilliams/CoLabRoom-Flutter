import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/text_measures.dart';

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

  /// The height the strip rests at, and its floor. See the note on the
  /// SizedBox below.
  static const double _restingHeight = 92;

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
                // Wraps. It is the one line that says the whole state of what
                // you put up, for somebody who is not going to read the cards
                // — and at the largest text size it read "1 SONG OUT THERE ·
                // 1 OFFE…", which is the half that does not matter.
                child: Text(
                  _summary(mine.length, listeners, offers),
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
            // Two lines of title, one line under it, and the card's own
            // padding — worked out at whatever text size this phone is set
            // to rather than written down as 92. See linesOfTextHigh: a
            // horizontal list is the one layout Flutter will not size for
            // itself, and since the reader's own text size stopped being
            // clamped a flat 92 cut the second line off.
            //
            // 92 stays the floor, so the strip is the height it has always
            // been at the usual text sizes: the card holds its title and its
            // line apart (spaceBetween), and that air is part of the drawing
            // rather than slack nobody meant.
            height: math.max(
              _restingHeight,
              _Card.padding.vertical +
                  linesOfTextHigh(context, _Card.titleStyle, lines: 2) +
                  linesOfTextHigh(context, _Card.underStyle),
            ),
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

  /// What the card is made of, named so OutThere can work out how tall the
  /// strip holding these has to be at the reader's own text size.
  static const EdgeInsets padding = EdgeInsets.fromLTRB(12, 10, 12, 10);

  static const TextStyle titleStyle = TextStyle(
    color: AppColors.text,
    fontSize: 13,
    fontWeight: FontWeight.w800,
    height: 1.25,
  );

  static const TextStyle underStyle =
      TextStyle(color: AppColors.muted, fontSize: 11.5);

  @override
  Widget build(BuildContext context) {
    // An offer is somebody putting their hand up, so it outranks every
    // number on the card and takes the colour.
    final waiting = song.offers > 0;
    return SizedBox(
      // Wider when the text is bigger, for the same reason the strip is
      // taller: 168 was room for a two-line song title at 13 points, and at
      // twice that it is room for three words and an ellipsis.
      width: 168 * textGrowth(context, titleStyle.fontSize!),
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
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Flexible(
                  child: Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                if (waiting)
                  Text(
                    song.offers == 1
                        ? 'Somebody offered'
                        : '${song.offers} people offered',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: underStyle.copyWith(
                      color: AppColors.cyan,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                else
                  Text(
                    _heard(song),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: underStyle,
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
    // Somebody choosing to say so outranks a play count: it is a person
    // rather than a number, and it is the cheap answer this app asks for.
    if (song.heard > 0) {
      return song.heard == 1
          ? '1 person said they heard it'
          : '${song.heard} said they heard it';
    }
    if (song.listeners == 0) return 'Nobody yet';
    if (song.listenersThisWeek > 0) {
      return '${song.listeners} heard it · ${song.listenersThisWeek} this week';
    }
    return song.listeners == 1 ? '1 person heard it' : '${song.listeners} heard it';
  }
}
