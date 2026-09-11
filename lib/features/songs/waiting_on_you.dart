import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../services/now_playing.dart';
import '../../widgets/player_face.dart';

/// Everything that wants something from you, in one place — sideways.
///
/// Taylor: "the notifications bar is still just one single line... its just
/// one thing at a time. and not formatted in a pleasant way. everything in
/// the app version works top down, what if notifications worked more left to
/// right, seamless and fluid, you could scroll through them that way, one at
/// a time, without leaving the page, see everything at once while still being
/// right at home on open. clear them all, or clear one at a time, or open one
/// if its exciting."
///
/// The two versions before this were both **stacks**, and a stack of
/// notifications above somebody's songs has one unavoidable property: every
/// extra thing pushes the music further down the screen. So the stack had to
/// be rationed — one lead, three rows, the rest folded behind a "4 more" —
/// and rationing is what made it feel like a single line at a time. The
/// layout was fighting the content.
///
/// Turned on its side, that fight disappears. A row of cards costs the same
/// height whether it holds one thing or nine, so nothing has to be hidden and
/// nothing has to be rationed. The next card peeks in past the right edge,
/// which is the whole instruction: there is more, it is that way, and you can
/// ignore it because your music is already on screen underneath.
///
/// What keeps it from being annoying:
///
///   * it draws nothing at all when nothing is waiting, which is most days
///   * it is one card tall no matter how much is in it
///   * every card has a verb and a way out, in the same two places
///   * one card's worth of space is a glance, not an inbox
enum WaitingKind {
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
    this.eyebrow,
    this.detail,
    this.onDismiss,
    this.who,
    this.whoAvatarPath,
    this.about,
    this.at,
    this.audioPath,
    this.audioMs,
  });

  /// Unique within the strip, so a dismissal can be remembered.
  final String id;
  final WaitingKind kind;

  /// What kind of thing this is, in two or three words, above the sentence.
  ///
  /// Supplied by the caller rather than derived from [kind], because the
  /// caller knows things the kind does not: "New take" and "New message" are
  /// both news, and only one of them is worth putting headphones on for.
  final String? eyebrow;

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

  /// Clear this one for good.
  ///
  /// Null for things that should not be silently forgotten — a person who
  /// asked to connect is waiting on an answer, and an × that made that
  /// disappear permanently would be how you never reply. Those hide for the
  /// session instead; see `_WaitingOnYouState._hiddenForNow`.
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

  /// Where the audio is, when this is a thing that can be heard.
  ///
  /// The difference between being told somebody added a bass part and
  /// hearing the bass part, from the top of your own screen, without opening
  /// anything.
  final String? audioPath;
  final int? audioMs;

  bool get isPlayable => (audioPath ?? '').isNotEmpty;

  /// Whether a person did this.
  ///
  /// News about a person is worth a face and the front of the queue. A chore
  /// never is — "make the song sheet" will be equally true tomorrow, and an
  /// app that opens on it feels like arriving at work.
  bool get isNews => who != null && kind != WaitingKind.sheet;

  /// Which of these deserves to be the one you land on.
  ///
  /// Something you can hear comes first even when it is older than something
  /// you can read. A take somebody cut on your song at two in the morning is
  /// worth more nine hours later than a note left forty minutes ago, and the
  /// card for it has a play button on it — landing on that is the app at its
  /// best in one screen.
  int get rank => switch (kind) {
        WaitingKind.news => isPlayable ? 0 : 1,
        WaitingKind.request => 2,
        WaitingKind.unfinished => 3,
        WaitingKind.sheet => 4,
      };

  IconData get icon => switch (kind) {
        WaitingKind.request => Icons.person_add_alt_1_rounded,
        WaitingKind.news => Icons.graphic_eq_rounded,
        WaitingKind.unfinished => Icons.history_rounded,
        WaitingKind.sheet => Icons.article_outlined,
      };

  Color get tint => switch (kind) {
        WaitingKind.request => AppColors.green,
        WaitingKind.news => AppColors.cyan,
        WaitingKind.unfinished => AppColors.muted,
        WaitingKind.sheet => AppColors.gold,
      };

  String get defaultEyebrow => switch (kind) {
        WaitingKind.request => 'Wants to connect',
        WaitingKind.news => 'Just happened',
        WaitingKind.unfinished => 'Pick it back up',
        WaitingKind.sheet => 'No song sheet yet',
      };
}

/// The strip itself.
class WaitingOnYou extends StatefulWidget {
  const WaitingOnYou({required this.items, super.key});

  final List<WaitingItem> items;

  /// The most of the strip one card may take.
  ///
  /// Not 1.0, and that is the whole design. At 0.9 the next card shows about
  /// thirty pixels of itself past the right edge, which says "there is more,
  /// and it is sideways" without a caption, an arrow or a number. At 1.0 the
  /// strip looks like one notification and nobody ever swipes it.
  static const double cardShare = 0.9;

  /// And the widest a card ever gets, in pixels.
  ///
  /// A share alone is a phone rule. On a desk it drew one card 970 pixels
  /// across holding a single sentence — the same "phone pulled at the
  /// corners" this repo has fixed twice already. Past this width the strip
  /// stops growing the card and starts showing more of them, which is what a
  /// bigger screen is for.
  static const double cardMax = 340;

  /// The gap between two cards, and the inset at each end of the row.
  static const double gutter = 18;

  /// How tall the row is, before text scaling.
  ///
  /// One card, always. The old stack grew with its contents, so four things
  /// waiting pushed Your music off the bottom of a phone; this is the same
  /// height whether it holds one card or nine.
  static const double rowHeight = 172;

  @override
  State<WaitingOnYou> createState() => _WaitingOnYouState();
}

class _WaitingOnYouState extends State<WaitingOnYou> {
  PageController? _pages;
  double? _fraction;
  int _page = 0;

  /// A controller sized to the screen it is being drawn on.
  ///
  /// Rebuilt only when the share actually changes, which in practice is once
  /// — a phone does not resize, and a window that does gets a controller that
  /// keeps the card you were on. The old one is disposed after the frame
  /// rather than here: it is still attached to the page view that is being
  /// replaced, and disposing an attached controller throws.
  PageController _controllerFor(double width) {
    // The smaller of the two rules, always. Taking whichever branch a
    // comparison fell into let a 360px phone ask for 0.994 of itself, which
    // is a card with no card peeking past it — the one thing that says the
    // row goes sideways.
    final share = math.min(
      WaitingOnYou.cardShare,
      (WaitingOnYou.cardMax + WaitingOnYou.gutter) / width,
    );
    if (_pages != null && _fraction == share) return _pages!;
    final previous = _pages;
    _fraction = share;
    _pages = PageController(viewportFraction: share, initialPage: _page);
    if (previous != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => previous.dispose());
    }
    return _pages!;
  }

  /// Gone until next time.
  ///
  /// For the things that have no permanent dismissal — a connect request is
  /// the only one so far. Taylor, on the first version: "if you wanna skip it
  /// you can, but its all there." Skipping is not answering: nothing is
  /// declined, nothing is marked, and it is back next time the app opens.
  final Set<String> _hiddenForNow = <String>{};

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  /// Sorted so the card you land on is the best one there is.
  ///
  /// News first, because somebody playing on your song while you were asleep
  /// is the most exciting sentence this app can produce. Chores last, and
  /// inside a kind the most recent first.
  List<WaitingItem> get _visible {
    final items = <WaitingItem>[
      for (final item in widget.items)
        if (!_hiddenForNow.contains(item.id)) item,
    ];
    items.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      return (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0));
    });
    return items;
  }

  void _dismiss(WaitingItem item) {
    // A card with no permanent dismissal goes for the session only. Keeping
    // that here rather than pushing it through the parent keeps "not now" out
    // of storage entirely, which is what makes it a different promise from
    // the × on everything else.
    if (item.onDismiss == null) {
      setState(() => _hiddenForNow.add(item.id));
      return;
    }
    item.onDismiss!.call();
  }

  /// Clear the lot, in one tap.
  ///
  /// Everything goes, including the things that only hide for the session —
  /// otherwise "Clear all" leaves a card behind and reads as broken.
  void _clearAll() {
    final hideToo = <String>[];
    for (final item in _visible) {
      if (item.onDismiss == null) {
        hideToo.add(item.id);
      } else {
        item.onDismiss!.call();
      }
    }
    if (hideToo.isEmpty) return;
    setState(() => _hiddenForNow.addAll(hideToo));
  }

  @override
  Widget build(BuildContext context) {
    final items = _visible;
    if (items.isEmpty) return const SizedBox.shrink();

    // The row has to be a fixed height for a page view to live in it, so the
    // height follows the text rather than ignoring it. Clamped, because past
    // about 1.45 the card stops being a glance and becomes a screen, and at
    // that point an ellipsis is kinder than a taller strip.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final height = WaitingOnYou.rowHeight * scale.clamp(1.0, 1.45);
    final page = _page.clamp(0, items.length - 1);

    // One thing gets its own card at its own size, with no page view around
    // it. A lone card held to a fixed height, indented to leave room for a
    // card that is not there, is the "one single line" problem wearing a
    // different hat.
    if (items.length == 1) {
      return Padding(
        key: const Key('waiting_on_you'),
        padding: const EdgeInsets.fromLTRB(
            WaitingOnYou.gutter, 0, WaitingOnYou.gutter, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: WaitingOnYou.cardMax),
            child: _WaitingCard(
              item: items.first,
              onDismiss: () => _dismiss(items.first),
              fill: false,
            ),
          ),
        ),
      );
    }

    return Column(
      key: const Key('waiting_on_you'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) => Padding(
              // Half a gutter each side here and half inside each page: card
              // edges land a full gutter from the screen, the gap between two
              // cards is a gutter, and the last card stops a gutter short of
              // the right edge instead of running off it.
              padding: const EdgeInsets.symmetric(
                  horizontal: WaitingOnYou.gutter / 2),
              child: PageView.builder(
                key: const Key('waiting_pages'),
                controller: _controllerFor(constraints.maxWidth),
                // The first card starts at the left edge rather than centred
                // with half a card of blank beside it.
                padEnds: false,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: items.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: WaitingOnYou.gutter / 2),
                  child: _WaitingCard(
                    item: items[i],
                    onDismiss: () => _dismiss(items[i]),
                  ),
                ),
              ),
            ),
          ),
        ),
        _StripFooter(
          count: items.length,
          page: page,
          onGo: (i) => _pages?.animateToPage(
            i,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
          onClearAll: _clearAll,
        ),
      ],
    );
  }
}

/// Where you are in the row, and the way out of all of it.
///
/// Underneath rather than above, so the strip opens on the card instead of on
/// chrome about the card. The dots are tappable: they are the only part of
/// this that says how much there is, and a count you cannot act on is
/// decoration.
class _StripFooter extends StatelessWidget {
  const _StripFooter({
    required this.count,
    required this.page,
    required this.onGo,
    required this.onClearAll,
  });

  final int count;
  final int page;
  final ValueChanged<int> onGo;
  final VoidCallback? onClearAll;

  @override
  Widget build(BuildContext context) {
    if (count < 2) return const SizedBox(height: 10);
    return SizedBox(
      height: 34,
      child: Stack(
        children: <Widget>[
          Align(
            alignment: Alignment.center,
            child: count <= 7
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (var i = 0; i < count; i += 1)
                        Semantics(
                          button: true,
                          label: '${i + 1} of $count',
                          child: InkResponse(
                            onTap: () => onGo(i),
                            radius: 14,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                                height: 5,
                                width: i == page ? 18 : 5,
                                decoration: BoxDecoration(
                                  color: i == page
                                      ? AppColors.cyan
                                      : AppColors.line,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  )
                // Past seven, dots stop being countable and become a texture.
                // A number is more use than a smear.
                : Text(
                    '${page + 1} of $count',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          if (onClearAll != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextButton(
                  key: const Key('waiting_clear_all'),
                  onPressed: onClearAll,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.muted,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  // Styled on the Text rather than through
                  // `styleFrom(textStyle:)`: ButtonStyleButton picks the
                  // widget's style *or* the theme's — `??`, not a merge — so
                  // a style given there replaces the resolved one and takes
                  // the font family with it.
                  child: const Text(
                    'Clear all',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
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
    _WaitingCard.when(at, now: now);

/// One thing, on its own card.
///
/// Every card is the same shape, and what changes inside it is what the thing
/// actually is: a person gets their face and a coloured edge, a chore gets an
/// icon and a quieter button. The version before this drew two different
/// layouts for those, which made the strip look like two features pushed
/// together — and the chore layout, being a grey row, was the one Taylor saw.
class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    required this.item,
    required this.onDismiss,
    this.fill = true,
  });

  final WaitingItem item;
  final VoidCallback onDismiss;

  /// Whether to grow into the height it is given.
  ///
  /// True inside the row, where every card has to be the same height or the
  /// buttons dance about as you swipe. False for a card standing on its own,
  /// which is laid out in a sliver and so has no height to grow into — a
  /// `Spacer` there is a flex child under an unbounded constraint, which is
  /// not a cosmetic problem but a layout assertion.
  final bool fill;

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
    final under = <String>[
      if (item.about != null) item.about!,
      if (at != null) when(at),
    ].join('  ·  ');
    final sub = under.isNotEmpty ? under : item.detail;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(16),
        // News wears its colour. A chore does not: a coloured edge is the
        // cheapest way to say "a person is in this one" from across a room,
        // and spending it on "make the song sheet" spends it on nothing.
        border: Border.all(
          color:
              item.isNews ? item.tint.withValues(alpha: 0.34) : AppColors.line,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(13, 12, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (item.who != null)
                PlayerFace(
                  name: item.who!,
                  color: item.tint,
                  photo: controller.avatarBytesFor(item.whoAvatarPath),
                  size: 34,
                )
              else
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: item.tint.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(item.icon, size: 18, color: item.tint),
                ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.eyebrow ?? item.defaultEyebrow,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: item.tint,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    if (sub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11.5,
                            height: 1.25,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // In the same corner on every card, doing the same thing.
              IconButton(
                key: Key('waiting_close_${item.id}'),
                onPressed: onDismiss,
                tooltip: item.onDismiss == null ? 'Not now' : 'Clear',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close_rounded,
                    size: 16, color: AppColors.muted),
              ),
            ],
          ),
          if (fill) const Spacer(),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              // Heard here, not somewhere else.
              //
              // A person recorded a part on your song while you were asleep,
              // and until #206 the best the app could do was tell you so and
              // offer to open a screen. One tap, no navigation -- the same
              // player the rest of the app uses, so the bar at the bottom
              // picks it up and it keeps going while you scroll on.
              if (item.isPlayable)
                _PlayButton(item: item)
              else if (item.isNews)
                FilledButton(
                  key: Key('waiting_do_${item.id}'),
                  onPressed: item.onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: item.tint,
                    foregroundColor: AppColors.ink,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: Text(
                    item.actionLabel,
                    maxLines: 1,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                )
              else
                // A chore gets an outline, not a solid. Two filled buttons of
                // equal weight side by side is the strip saying a song sheet
                // and a bass take matter the same amount.
                OutlinedButton(
                  key: Key('waiting_do_${item.id}'),
                  onPressed: item.onAction,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: item.tint,
                    side: BorderSide(color: item.tint.withValues(alpha: 0.5)),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: Text(
                    item.actionLabel,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
              if (item.isPlayable) ...<Widget>[
                const SizedBox(width: 2),
                // Still a way into the song, for somebody who wants the rest
                // of it rather than the thirty seconds.
                //
                // Flexible, because a 360px phone at 1.3x text does not have
                // room for two buttons at their natural widths — that
                // overflowed by 27 pixels on the version before this, which
                // throws in a test and is clipped in silence in release.
                Flexible(
                  child: TextButton(
                    key: Key('waiting_open_${item.id}'),
                    onPressed: item.onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.muted,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text(
                      'Open',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Play, and then stop, without leaving the screen.
///
/// Listens to the one player the whole app shares, so a take started here
/// appears in the bar at the bottom and keeps going while somebody scrolls on
/// — and so pressing play on a second thing stops the first, which is what a
/// person expects and what two independent players never do.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.item});

  final WaitingItem item;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NowPlaying.instance,
      builder: (context, _) {
        final now = NowPlaying.instance;
        final mine = now.path == item.audioPath;
        final playing = mine && now.playing;
        return FilledButton.icon(
          key: Key('waiting_play_${item.id}'),
          onPressed: () => unawaited(
            now.toggle(
              item.audioPath!,
              knownLength: item.audioMs == null
                  ? null
                  : Duration(milliseconds: item.audioMs!),
              title: item.about ?? '',
              byline: item.who ?? '',
            ),
          ),
          icon: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 20,
          ),
          label: Text(
            playing ? 'Playing' : 'Hear it',
            maxLines: 1,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.cyan,
            foregroundColor: AppColors.ink,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(left: 10, right: 16),
          ),
        );
      },
    );
  }
}
