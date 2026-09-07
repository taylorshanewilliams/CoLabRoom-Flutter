import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/player_face.dart';

/// Who can hear this song, said out loud.
///
/// Nothing in this app answered that question. A song's audience is decided
/// by which room it is in, who was invited to this one song, and whether it
/// is on the Open Mic — three mechanisms, two of them buried in an overflow
/// menu, and no indicator anywhere. Somebody could not look at a song and
/// know who could hear it.
///
/// That is the gap under everything this app promises. A safe place to work
/// on something unfinished only works if the safety is *visible*; otherwise
/// what somebody actually feels is uncertainty, and uncertainty is why an
/// unfinished song never gets put out.
///
/// **One control, four positions.** Alone, with your band, with somebody you
/// asked, in front of everybody. Drawn as a line the song wears rather than
/// hidden behind a menu, because the whole point is that you never have to go
/// looking to find out.
class AudienceDial extends StatelessWidget {
  const AudienceDial({
    required this.audience,
    required this.onTap,
    super.key,
  });

  final SongAudience? audience;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final known = audience;
    // Never a guess. An empty bar while it loads is honest; a bar that says
    // "Only you" before it knows is the one wrong answer that matters.
    if (known == null) return const SizedBox(height: 0);

    final tone = _toneFor(known.reach);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Material(
        color: tone.withValues(alpha: 0.10),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: tone.withValues(alpha: 0.42)),
        ),
        child: InkWell(
          key: const Key('song_audience_dial'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: <Widget>[
                Icon(_iconFor(known.reach), size: 18, color: tone),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        known.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tone,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        known.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                // Faces rather than a number, where there are any. "Who" is
                // the question; "how many" is not.
                if (known.listeners.isNotEmpty)
                  SizedBox(
                    height: 24,
                    width: (known.listeners.take(3).length * 16) + 8,
                    child: Stack(
                      children: <Widget>[
                        for (var i = 0;
                            i < known.listeners.take(3).length;
                            i += 1)
                          Positioned(
                            left: i * 16,
                            child: PlayerFace(
                              name: known.listeners[i].name,
                              size: 24,
                            ),
                          ),
                      ],
                    ),
                  ),
                const Icon(Icons.chevron_right_rounded,
                    size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _toneFor(SongReach reach) => switch (reach) {
        // Public is gold, the colour this app spends on the things that
        // matter most — and being audible to everybody is the state somebody
        // most needs to notice at a glance.
        SongReach.anyone => AppColors.gold,
        SongReach.justYou => AppColors.muted,
        _ => AppColors.cyan,
      };

  static IconData _iconFor(SongReach reach) => switch (reach) {
        SongReach.justYou => Icons.lock_outline_rounded,
        SongReach.room => Icons.group_outlined,
        SongReach.invited => Icons.person_add_alt_1_outlined,
        SongReach.anyone => Icons.public_rounded,
      };
}

/// The dial opened up: the whole gradient, with where this song sits on it.
///
/// Shows all four positions rather than only the current one, because the
/// control's second job is to teach what the spaces are — and a list you can
/// see the ends of does that in one glance, where onboarding copy does not do
/// it at all.
Future<SongAudienceChoice?> showAudienceSheet(
  BuildContext context, {
  required SongAudience audience,
  required String songTitle,
}) {
  return showModalBottomSheet<SongAudienceChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Who can hear it',
              style: Theme.of(sheetContext).textTheme.headlineSmall,
            ),
            const SizedBox(height: 3),
            Text(
              songTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 18),

            _Step(
              reach: SongReach.justYou,
              here: audience.reach == SongReach.justYou,
              title: 'Only you',
              body: 'Nobody else is in the room this song lives in.',
            ),
            _Step(
              reach: SongReach.room,
              here: audience.reach == SongReach.room,
              title: audience.roomName.isEmpty
                  ? 'Your room'
                  : '${audience.roomIcon} ${audience.roomName}'.trim(),
              body: 'Everybody in the room hears it, and can work on it.',
            ),
            _Step(
              reach: SongReach.invited,
              here: audience.reach == SongReach.invited,
              title: 'People you asked',
              body: 'Somebody invited to this one song, and nothing else '
                  'of yours.',
            ),
            _Step(
              reach: SongReach.anyone,
              here: audience.reach == SongReach.anyone,
              title: 'Anyone',
              body: 'On the Open Mic. Only the takes your room has already '
                  'heard become audible — never a private one.',
            ),

            if (audience.listeners.isNotEmpty) ...<Widget>[
              const SizedBox(height: 18),
              const Text(
                'RIGHT NOW',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              for (final listener in audience.listeners)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    children: <Widget>[
                      PlayerFace(name: listener.name, size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          listener.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.text, fontSize: 13.5),
                        ),
                      ),
                      if (listener.songOnly)
                        const Text(
                          'this song only',
                          style: TextStyle(
                              color: AppColors.cyan, fontSize: 11),
                        ),
                    ],
                  ),
                ),
            ],

            const SizedBox(height: 20),
            // The one move that changes the answer, named for what it does
            // in each direction. It used to say "Put it on the Open Mic"
            // whether or not it already was.
            FilledButton.icon(
              key: const Key('audience_open_mic_toggle'),
              onPressed: () => Navigator.pop(
                sheetContext,
                audience.onOpenMic
                    ? SongAudienceChoice.takeOffOpenMic
                    : SongAudienceChoice.putOnOpenMic,
              ),
              icon: Icon(
                audience.onOpenMic
                    ? Icons.public_off_rounded
                    : Icons.public_rounded,
                size: 18,
              ),
              label: Text(
                audience.onOpenMic
                    ? 'Take it off the Open Mic'
                    : 'Put it on the Open Mic',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor:
                    audience.onOpenMic ? AppColors.raised : AppColors.gold,
                foregroundColor:
                    audience.onOpenMic ? AppColors.text : AppColors.ink,
                textStyle: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            // Finishing lives here because "who can hear this" is exactly the
            // question it answers: a finished song shown on the showcase is
            // a different audience from one asking for help on the Open Mic,
            // and putting it anywhere else would make it look like a filing
            // status rather than a reach.
            OutlinedButton.icon(
              key: const Key('audience_show_finished'),
              onPressed: () => Navigator.pop(
                sheetContext,
                audience.onShowcase
                    ? SongAudienceChoice.takeOffShowcase
                    : SongAudienceChoice.showFinished,
              ),
              icon: Icon(
                audience.onShowcase
                    ? Icons.remove_circle_outline_rounded
                    : Icons.workspace_premium_outlined,
                size: 18,
              ),
              // A one-way door is a door nobody walks through — the same
              // reason the Open Mic toggle had to say which direction it
              // goes. This shipped without a way back for exactly one day.
              label: Text(
                audience.onShowcase
                    ? 'Take it off the showcase'
                    : 'It is finished — show it',
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                foregroundColor: AppColors.gold,
                side: BorderSide(color: AppColors.gold.withValues(alpha: 0.45)),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('audience_invite'),
              onPressed: () =>
                  Navigator.pop(sheetContext, SongAudienceChoice.invite),
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: const Text('Invite somebody to this song'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                foregroundColor: AppColors.cyan,
                side: const BorderSide(color: AppColors.line),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'You can move a song back down at any time. Nothing you have '
              'not shared is ever audible.',
              style: TextStyle(
                  color: AppColors.muted, fontSize: 11.5, height: 1.4),
            ),
          ],
        ),
      ),
    ),
  );
}

enum SongAudienceChoice {
  putOnOpenMic,
  takeOffOpenMic,
  invite,

  /// Done, and shown. Two acts in one press because they are one intention —
  /// but two columns underneath, because finishing something privately must
  /// never publish it.
  showFinished,

  /// Off the showcase, still finished. Unpublishing is not un-finishing.
  takeOffShowcase,
}

class _Step extends StatelessWidget {
  const _Step({
    required this.reach,
    required this.here,
    required this.title,
    required this.body,
  });

  final SongReach reach;
  final bool here;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tone = AudienceDial._toneFor(reach);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: here ? tone.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: here ? tone.withValues(alpha: 0.5) : AppColors.line,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              AudienceDial._iconFor(reach),
              size: 17,
              color: here ? tone : AppColors.muted,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: here ? AppColors.text : AppColors.muted,
                      fontSize: 13.5,
                      fontWeight: here ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5, height: 1.4),
                  ),
                ],
              ),
            ),
            if (here) ...<Widget>[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  'NOW',
                  style: TextStyle(
                    color: tone,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
