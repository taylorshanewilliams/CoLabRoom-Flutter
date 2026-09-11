import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../widgets/player_face.dart';

/// Everything that wants something from you, in one place.
///
/// Taylor: "lets find a way to have all suggestions, notifications, continue
/// working, friend requests etc all in one place, clean the screen up a
/// little." And then, on the first version of it: "one bar might be to
/// limiting, what can we do to make it feel exciting and fun and helpful
/// above all, intuitive and seamless without being intrusive and annoying."
///
/// He is right, and the flaw was flattening. **Not everything here is the
/// same kind of thing.** "Jess added a bass take at midnight" and "make the
/// song sheet" are not two instances of one category — the first is a person
/// doing something for your song while you were asleep, which is the most
/// exciting sentence this app is capable of producing, and the second is a
/// chore that will be equally true tomorrow. Rendering them as identical grey
/// rows threw that difference away.
///
/// So: **news leads and gets room.** A face, a name, the song, and when —
/// said the way somebody would say it. Chores never lead; they keep their
/// place in the list underneath. An app that opens on "make the song sheet"
/// feels like arriving at work.
///
/// What keeps it from being annoying is four rules:
///
///   * it draws nothing at all when nothing is waiting, which is most days
///   * every row has a verb and a way out, in the same two places
///   * the whole strip can be skipped for now without answering anything
///   * it is not shaped like a song, so nobody tries to open it as one
enum WaitingKind {
  /// Somebody asked you, by name, to play on their song.
  ask,

  /// Somebody invited you into a room.
  invite,

  /// Somebody has asked to connect.
  request,

  /// Somebody did something to a song you are in.
  news,

  /// A song you stopped working on.
  unfinished,

  /// A recording with no song sheet yet.
  sheet,
}

class WaitingItem {
  const WaitingItem({
    required this.id,
    required this.kind,
    required this.line,
    required this.actionLabel,
    required this.onAction,
    this.detail,
    this.onDismiss,
    this.who,
    this.whoAvatarPath,
    this.about,
    this.at,
  });

  /// Unique within the strip, so a dismissal can be remembered.
  final String id;
  final WaitingKind kind;

  /// One line. Not a paragraph, and never wrapped onto three.
  final String line;

  /// The smaller line under it, when there is genuinely more to say.
  ///
  /// Null far more often than not. The card this replaced printed "Nothing
  /// else is waiting" under its own heading, which is a sentence that exists
  /// to fill a space rather than to be read.
  final String? detail;

  final String actionLabel;
  final VoidCallback onAction;

  /// Null only for things that cannot be declined, which so far is nothing.
  final VoidCallback? onDismiss;

  /// Who did it, when somebody did.
  ///
  /// The difference between "a recording was added" and "Jess added a
  /// recording" is the whole feeling of the thing.
  final String? who;
  final String? whoAvatarPath;

  /// The song it happened to, drawn separately so it can be emphasised.
  final String? about;

  /// When, so it can be said the way a person would.
  final DateTime? at;

  /// Whether this is worth the top of the screen.
  ///
  /// News about a person is. A chore never is.
  bool get isNews => who != null && kind != WaitingKind.sheet;

  /// Where this sits against everything else.
  ///
  /// A person waiting on an answer outranks a person's news, which outranks
  /// a job that will be equally true tomorrow. Nothing here is ordered by
  /// recency: the newest thing is rarely the most important one, and an
  /// inbox sorted by time makes you read it all to find out what matters.
  int get rank => switch (kind) {
        WaitingKind.ask => 0,
        WaitingKind.invite => 1,
        WaitingKind.request => 2,
        WaitingKind.news => 3,
        WaitingKind.sheet => 4,
        WaitingKind.unfinished => 5,
      };

  /// Whether somebody is on the other end, waiting.
  ///
  /// These cannot be closed, only answered. Letting somebody silently drop a
  /// request another musician is waiting on would make the strip a place
  /// where things go to be forgotten, which is the opposite of the point.
  bool get someoneIsWaiting =>
      kind == WaitingKind.ask ||
      kind == WaitingKind.invite ||
      kind == WaitingKind.request;

  IconData get icon => switch (kind) {
        WaitingKind.ask => Icons.campaign_outlined,
        WaitingKind.invite => Icons.meeting_room_outlined,
        WaitingKind.request => Icons.person_add_alt_1_rounded,
        WaitingKind.news => Icons.graphic_eq_rounded,
        WaitingKind.unfinished => Icons.history_rounded,
        WaitingKind.sheet => Icons.article_outlined,
      };

  Color get tint => switch (kind) {
        WaitingKind.ask => AppColors.gold,
        WaitingKind.invite => AppColors.cyan,
        WaitingKind.request => AppColors.cyan,
        WaitingKind.news => AppColors.cyan,
        WaitingKind.unfinished => AppColors.muted,
        WaitingKind.sheet => AppColors.gold,
      };
}

/// The strip itself.
class WaitingOnYou extends StatefulWidget {
  const WaitingOnYou({required this.items, super.key});

  final List<WaitingItem> items;

  /// How many rows are shown under the lead before the rest are folded away.
  ///
  /// Two, and it was three until the asks and invites moved in here. With a
  /// lead card on top, three rows and a "more" line pushed the songs off a
  /// small phone entirely — which is the definition of intrusive, and was
  /// caught by four tests that suddenly could not tap a song.
  ///
  /// The strip sits above somebody's music. Its job is to be answered and
  /// gone, and it must never be the reason you cannot see what you came for.
  static const int shown = 2;

  @override
  State<WaitingOnYou> createState() => _WaitingOnYouState();
}

class _WaitingOnYouState extends State<WaitingOnYou> {
  bool _expanded = false;
  bool _skipped = false;

  /// Gone for this session.
  ///
  /// Taylor: "if you wanna skip it you can, but its all there." Skipping is
  /// not dismissing — nothing is answered, nothing is marked, and it is all
  /// back next time the app opens. The difference between "not now" and "no".
  void _skip() => setState(() => _skipped = true);

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty || _skipped) return const SizedBox.shrink();

    // Ordered here rather than by the caller, so every screen that ever
    // shows this strip agrees about what matters most.
    final all = widget.items.toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));

    // The most important thing with a person attached leads. A chore never
    // does, however near the top of the list it sits.
    WaitingItem? lead;
    for (final item in all) {
      if (item.isNews) {
        lead = item;
        break;
      }
    }
    final rest = all.where((i) => i != lead).toList(growable: false);
    // Fewer rows on a short screen. A strip that is right at 844 points is
    // half the screen at 690 with the text scaled up, and "half the screen
    // before you can see your own songs" is the definition of intrusive
    // however good the contents are.
    final room = MediaQuery.sizeOf(context).height >= 760
        ? WaitingOnYou.shown
        : 1;
    final visible =
        _expanded ? rest : rest.take(room).toList(growable: false);
    final hidden = rest.length - visible.length;

    return Container(
      key: const Key('waiting_on_you'),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        // Its own surface, one shade off the page: enough that the eye reads
        // it as a different kind of thing from the songs underneath, and not
        // so much that it shouts.
        color: AppColors.raised.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: <Widget>[
          if (lead != null) _LeadCard(item: lead, onSkip: _skip),
          for (var i = 0; i < visible.length; i += 1) ...<Widget>[
            if (i > 0 || lead != null)
              const Divider(height: 1, color: AppColors.line),
            _WaitingRow(item: visible[i]),
          ],
          if (hidden > 0 || _expanded) ...<Widget>[
            const Divider(height: 1, color: AppColors.line),
            InkWell(
              key: const Key('waiting_more'),
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(13)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: Text(
                    _expanded ? 'Fewer' : '$hidden more',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// How long ago, said the way somebody would say it.
///
/// Exposed so it can be tested directly: the rule it encodes -- that
/// "overnight" is worth more than "9 hours ago" -- is the kind of thing that
/// gets quietly replaced with a number by somebody tidying up.
String leadCardWhen(DateTime at, {DateTime? now}) =>
    _LeadCard.when(at, now: now);

/// The thing worth looking up for.
///
/// Somebody played on your song while you were asleep. The first version of
/// this strip rendered that as a grey row with an icon — the same row, in the
/// same grey, as "make the song sheet".
class _LeadCard extends StatelessWidget {
  const _LeadCard({required this.item, required this.onSkip});

  final WaitingItem item;
  final VoidCallback onSkip;

  /// Said the way somebody would say it, not in units.
  ///
  /// "Overnight" is the one worth having. It is the whole promise of an app
  /// for people who are never free at the same time, and no number says it.
  static String when(DateTime at, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final gap = today.difference(at);
    if (gap.inMinutes < 2) return 'just now';
    if (gap.inMinutes < 60) return '${gap.inMinutes} minutes ago';
    if (gap.inHours < 5) return '${gap.inHours} hours ago';
    if (gap.inHours < 20 && today.hour < 12) return 'overnight';
    if (gap.inHours < 24) return 'today';
    if (gap.inDays < 2) return 'yesterday';
    if (gap.inDays < 7) return '${gap.inDays} days ago';
    return 'a while back';
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final at = item.at;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              PlayerFace(
                name: item.who ?? 'Someone',
                color: AppColors.cyan,
                photo: controller.avatarBytesFor(item.whoAvatarPath),
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    if (item.about != null || at != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          <String>[
                            if (item.about != null) item.about!,
                            if (at != null) when(at),
                          ].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              // Skip, not dismiss: the whole strip goes until next time and
              // nothing is answered.
              IconButton(
                key: const Key('waiting_skip'),
                onPressed: onSkip,
                tooltip: 'Skip for now',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close_rounded,
                    size: 16, color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              FilledButton(
                key: Key('waiting_lead_do_${item.id}'),
                onPressed: item.onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: Text(
                  item.actionLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              if (item.onDismiss != null) ...<Widget>[
                const SizedBox(width: 4),
                TextButton(
                  key: Key('waiting_lead_close_${item.id}'),
                  onPressed: item.onDismiss,
                  style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                  child: const Text('Not now'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _WaitingRow extends StatelessWidget {
  const _WaitingRow({required this.item});

  final WaitingItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
      child: Row(
        children: <Widget>[
          Icon(item.icon, size: 18, color: item.tint),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.detail != null)
                  Text(
                    item.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Flexible, because a 360px phone at 1.3x text does not have room
          // for a sentence, a verb and a close button at their natural
          // widths -- it overflowed by 27 pixels, which throws in a test and
          // is clipped in silence in release.
          //
          // The verb sits in the same place on every row and does not look
          // like the words around it. Taylor did not notice the old actions
          // because they were the same size and weight as the sentence they
          // sat under.
          Flexible(
            child: TextButton(
              key: Key('waiting_do_${item.id}'),
              onPressed: item.onAction,
              style: TextButton.styleFrom(
                foregroundColor: item.tint,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              // Styled on the Text rather than through styleFrom(textStyle:):
              // ButtonStyleButton picks the widget's style *or* the theme's —
              // `??`, not a merge — so a style given there replaces the
              // resolved one and takes the font family with it.
              child: Text(
                item.actionLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          if (item.onDismiss != null)
            IconButton(
              key: Key('waiting_close_${item.id}'),
              onPressed: item.onDismiss,
              tooltip: 'Not now',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded,
                  size: 16, color: AppColors.muted),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}
