import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../widgets/app_surface.dart';

/// One idea you left, brought back.
///
/// The app has two tabs and neither is a reason to open it on a Tuesday. Your
/// music is a filing cabinet — you go there when you already know what you
/// want — and the Open Mic needs other people to have done something. So on a
/// quiet week there is nothing here at all, and an app with nothing to say on
/// a quiet week is an app that gets opened when you remember it exists.
///
/// [WhileYouWereGone] answers "what did other people do". This answers the
/// question nobody was asking on your behalf: **what did you leave.** Every
/// musician has a graveyard of half-ideas — the forty-second voice memo with
/// one good line in it — and the reason they stay buried is not that they
/// were bad. It is that nothing ever brings them back up.
///
/// **The tone is the whole design.** This is emotionally loaded material and
/// the wrong voice makes it a chore list. It never counts what is unfinished,
/// never says "still", never nags, and shows one thing rather than a pile.
/// A friend saying *this was good, you know* — not a todo app saying overdue.
///
/// And it draws nothing when there is nothing, the same way the news does. A
/// library made this week has no graveyard, and announcing that it has none
/// would be worse than saying nothing.
@immutable
class LeftBehind {
  const LeftBehind({required this.song, required this.since});

  final SongProject song;
  final Duration since;

  /// When you left it, said the way a person would.
  ///
  /// Weeks while it is still recent enough to feel like a thread you could
  /// pick up, and the month once it is old enough that the number stops
  /// meaning anything — "untouched for 63 weeks" is a statistic, and "you
  /// left this in June" is a memory.
  String get when {
    final weeks = since.inDays ~/ 7;
    if (since.inDays < 60) {
      return weeks <= 1 ? 'You left this last week' : 'You left this $weeks weeks ago';
    }
    final month = _months[song.updatedAt.month - 1];
    final now = DateTime.now();
    final sameYear = song.updatedAt.year == now.year;
    return sameYear
        ? 'You left this in $month'
        : 'You left this in $month ${song.updatedAt.year}';
  }

  /// What the app knows about it that you would have to open it to find out.
  ///
  /// The point of the whole card. Anybody can list old files; the thing worth
  /// coming back for is that this one already knows what is on it.
  String get known => song.analysisState == SongAnalysisState.ready
      ? 'It already has a song sheet — the chords, the key, your words.'
      : 'There is a recording on it, and no song sheet yet.';

  static const _months = <String>[
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
}

class PickItBackUp extends StatelessWidget {
  const PickItBackUp({
    required this.songs,
    required this.onOpen,
    this.skip = 0,
    this.onSkip,
    super.key,
  });

  final List<SongProject> songs;
  final ValueChanged<SongProject> onOpen;

  /// How many times somebody has said "something else" today.
  final int skip;
  final VoidCallback? onSkip;

  /// Nothing counts as left behind until it has been quiet for this long.
  ///
  /// Two weeks, because a song you touched on Sunday is not forgotten, it is
  /// in progress — and putting it here would turn a memory into a nag.
  static const Duration forgotten = Duration(days: 14);

  /// Which one to bring back, or null when there is nothing to bring.
  ///
  /// Only songs with something to hear. A title with no recording is a note
  /// to self, and handing somebody back an empty song is the app admitting it
  /// knows nothing about it.
  ///
  /// Rotates by the day rather than always offering the oldest. A single dead
  /// song at the top of the list every morning stops being an invitation by
  /// Thursday, and the whole graveyard deserves a turn.
  static LeftBehind? choose(
    List<SongProject> songs, {
    DateTime? now,
    int skip = 0,
  }) {
    final today = now ?? DateTime.now();
    final candidates = songs
        .where((song) =>
            song.status == SongStatus.active &&
            song.hasAudioReference &&
            today.difference(song.updatedAt) >= forgotten)
        .toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    if (candidates.isEmpty) return null;

    // Stable within a day, different tomorrow. Deterministic on purpose: a
    // card that reshuffles on every rebuild is a card nobody trusts.
    final day = today.difference(DateTime.utc(2020)).inDays;
    final song = candidates[(day + skip) % candidates.length];
    return LeftBehind(song: song, since: today.difference(song.updatedAt));
  }

  @override
  Widget build(BuildContext context) {
    final left = choose(songs, skip: skip);
    if (left == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppSurface(
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              left.when,
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
            const SizedBox(height: 6),
            InkWell(
              key: const Key('pick_it_back_up'),
              onTap: () => onOpen(left.song),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          left.song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          left.known,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12.5,
                              height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      size: 22, color: AppColors.cyan),
                ],
              ),
            ),
            if (onSkip != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('pick_something_else'),
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  // Not "dismiss". Saying no to one idea should not be an act
                  // of throwing it away, and the pile is the point.
                  child: const Text('Something else',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
