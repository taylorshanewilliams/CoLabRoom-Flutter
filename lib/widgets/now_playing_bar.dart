import 'dart:async';

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../services/now_playing.dart';

/// The music keeps playing.
///
/// Every play button in this app stopped mattering the moment somebody
/// scrolled: sound was tied to whichever screen started it, so browsing the
/// Open Mic meant starting a song, deciding, and starting another — three
/// deliberate acts where a listening app has one continuous one.
///
/// This is what makes it feel seamless, and it is not "more songs per
/// screen". A feed of text works several at a time because your eye reads one
/// and previews the next; audio cannot do that, because two songs at once is
/// noise. What audio needs instead is for the one that is playing not to stop
/// when you look somewhere else.
///
/// **Absent when nothing is playing.** A permanent transport bar with nothing
/// in it is a permanent 56 pixels taken from every screen to say "silence".
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({required this.onOpen, super.key});

  /// Tapping the bar goes to the song it came from, when whatever started it
  /// said which song that was.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final now = NowPlaying.instance;
    return AnimatedBuilder(
      animation: now,
      builder: (context, _) {
        final path = now.path;
        if (path == null || path.isEmpty) return const SizedBox.shrink();

        final fraction = now.fraction ?? 0;
        final title = now.title.isEmpty ? 'Playing' : now.title;
        final songId = now.songId;

        return Material(
          color: AppColors.raised,
          child: InkWell(
            key: const Key('now_playing_bar'),
            onTap: songId == null ? null : () => onOpen(songId),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // A hairline rather than a slider. Somebody scrolling a feed
                // wants to know it is still going, not to scrub — and a
                // draggable target this thin, this close to the tab bar, is
                // one people hit by accident.
                SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 2,
                    backgroundColor: AppColors.line,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppColors.cyan),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (now.byline.isNotEmpty)
                              Text(
                                now.byline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('now_playing_toggle'),
                        tooltip: now.playing ? 'Pause' : 'Play',
                        onPressed: () => unawaited(now.toggle(path)),
                        icon: Icon(
                          now.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: AppColors.cyan,
                        ),
                      ),
                      IconButton(
                        key: const Key('now_playing_stop'),
                        tooltip: 'Stop',
                        // A way out that is not "find the row it came from
                        // and press it again". Without this the only way to
                        // silence the app is to leave it.
                        onPressed: () => unawaited(now.stop()),
                        icon: const Icon(Icons.close_rounded,
                            size: 19, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
