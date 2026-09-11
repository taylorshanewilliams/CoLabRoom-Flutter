import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../services/now_playing.dart';
import '../../widgets/player_face.dart';

/// Everything that wants something from you, as a row of title cards.
///
/// Taylor, on the version before this: "im more seeing the notifications as
/// title cards, possibly 2 or 3 could fit on the screen, and they are
/// scrollable left to right, so you can go through them and see multiple at a
/// time, and just remove the ones you want, and keep the ones you want. but
/// you can swipe and scroll left to right, right to left and go through all
/// your notifications. the rest of the app goes downwards, you see your songs,
/// your rooms your sets as it is."
///
/// Three versions got here. The first two were **stacks**, and a stack above
/// somebody's songs has one unavoidable property: every extra thing pushes
/// the music further down. So it rationed itself — one lead, three rows, a "4
/// more" — and the rationing is what made it feel like one thing at a time.
///
/// The third turned it sideways but kept one big card per screen and snapped
/// between them, which is the same complaint wearing a coat: still one thing
/// at a time, just moving horizontally. **The point is seeing several.** Two
/// or three small cards side by side is a glance at everything waiting; one
/// card that fills the width is a notification you have to page through.
///
/// So the cards are small and the row scrolls freely in both directions,
/// which makes this the one part of the app that does not go downwards. That
/// is not an inconsistency, it is the reason it works: a row that travels the
/// other way cannot be confused with the songs underneath it, cannot push
/// them down the screen, and costs the same height whether it holds one thing
/// or nine.
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

  /// The title of the card. Short enough to be read at a glance, because at
  /// this size it gets two lines and no more.
  final String line;

  /// The smaller line under it, when there is genuinely more to say.
  ///
  /// Null far more often than not. The card two versions ago printed "Nothing
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
  /// News about a person is worth a face and the front of the row. A chore
  /// never is — "make the song sheet" will be equally true tomorrow, and an
  /// app that opens on it feels like arriving at work.
  bool get isNews => who != null && kind != WaitingKind.sheet;

  /// Which of these deserves to be the one at the left-hand end.
  ///
  /// Something you can hear comes first even when it is older than something
  /// you can read. A take somebody cut on your song at two in the morning is
  /// worth more nine hours later than a note left forty minutes ago, and the
  /// card for it has a play button on it — opening on that is the app at its
  /// best in one glance.
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
        WaitingKind.sheet => 'No song sheet',
      };
}

/// The row itself.
class WaitingOnYou extends StatefulWidget {
  const WaitingOnYou({required this.items, super.key});

  final List<WaitingItem> items;

  /// How many cards are meant to be on screen at once.
  ///
  /// The number, not a fraction of the width, because the number is the
  /// point: Taylor asked for "possibly 2 or 3", and the fraction of a card
  /// left over at the right edge is what says the row keeps going. Two and a
  /// bit on a phone, more as the screen grows.
  static const double cardsInView = 2.35;

  /// The narrowest and widest a card ever gets.
  ///
  /// A floor because below about 130 a song title stops being readable and
  /// starts being three ellipses; a ceiling because on a desk the answer to a
  /// wider screen is more cards, not a card 450 pixels across holding four
  /// words — the "phone pulled at the corners" this repo has fixed twice.
  static const double cardMin = 132;
  static const double cardMax = 208;

  /// The inset at each end of the row, matching everything below it.
  static const double gutter = 18;

  /// And the gap between two cards, which is smaller on purpose: they are one
  /// row of one thing, not five separate panels.
  static const double gap = 10;

  /// How tall the row is, before text scaling.
  ///
  /// One card, always. The stacked versions grew by a row per thing, so four
  /// things waiting pushed Your music off the bottom of a phone — which is
  /// what forced them to hide most of it behind a "4 more".
  static const double rowHeight = 172;

  /// And how tall it is on a screen that has no height to spare.
  ///
  /// A landscape phone is about 500 pixels tall. A strip that takes 40% of
  /// that is not a glance at what is waiting, it is a wall in front of the
  /// songs — two tests caught it by failing to reach a song that had been
  /// pushed below the fold, which is exactly what a person would have hit.
  /// So on a short screen the card drops its second line and tightens up.
  static const double denseRowHeight = 118;

  /// Below this, the row goes dense. A tall phone is never dense; a landscape
  /// phone and a short window always are.
  static const double shortScreen = 620;

  /// How wide each card is, given the room the row has.
  static double cardWidth(double available) => math.max(
        cardMin,
        math.min(
          cardMax,
          (available - gutter * 2 - gap * (cardsInView - 1)) / cardsInView,
        ),
      );

  @override
  State<WaitingOnYou> createState() => _WaitingOnYouState();
}

class _WaitingOnYouState extends State<WaitingOnYou> {
  /// Gone until next time.
  ///
  /// For the things that have no permanent dismissal — a connect request is
  /// the only one so far. Taylor, on the first version: "if you wanna skip it
  /// you can, but its all there." Skipping is not answering: nothing is
  /// declined, nothing is marked, and it is back next time the app opens.
  final Set<String> _hiddenForNow = <String>{};

  /// Sorted so the card at the left-hand end is the best one there is.
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

    // The row is a fixed height so that it can scroll sideways at all, so the
    // height follows the text rather than ignoring it. Clamped, because past
    // about 1.45 a card stops being a glance and becomes a screen, and at
    // that point an ellipsis is kinder than a taller strip.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final dense =
        MediaQuery.sizeOf(context).height < WaitingOnYou.shortScreen;
    final height =
        (dense ? WaitingOnYou.denseRowHeight : WaitingOnYou.rowHeight) *
            scale.clamp(1.0, 1.45);

    return Column(
      key: const Key('waiting_on_you'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = WaitingOnYou.cardWidth(constraints.maxWidth);
              return ScrollConfiguration(
                // Draggable with a mouse, not only with a finger.
                //
                // Flutter lets touch drag a scrollable and leaves the mouse
                // to the wheel, which on a horizontal row means a desk user
                // sees cards running off the edge with no way to reach them:
                // there is no horizontal wheel on most mice and no scrollbar
                // on a row this short. The web build is a real surface here.
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: const <PointerDeviceKind>{
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                  scrollbars: false,
                ),
                child: ListView.separated(
                  key: const Key('waiting_row'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                      horizontal: WaitingOnYou.gutter),
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: WaitingOnYou.gap),
                  itemBuilder: (context, i) => SizedBox(
                    width: width,
                    child: _WaitingCard(
                      item: items[i],
                      onDismiss: () => _dismiss(items[i]),
                      dense: dense,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Under the row rather than over it, so the strip opens on the cards
        // instead of on chrome about the cards.
        if (items.length > 1)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 10, top: 2),
              child: TextButton(
                key: const Key('waiting_clear_all'),
                onPressed: _clearAll,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                // Styled on the Text rather than through
                // `styleFrom(textStyle:)`: ButtonStyleButton picks the
                // widget's style *or* the theme's — `??`, not a merge — so a
                // style given there replaces the resolved one and takes the
                // font family with it.
                child: const Text(
                  'Clear all',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          )
        else
          const SizedBox(height: 8),
      ],
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

/// One thing, on one title card.
///
/// Small on purpose. At this size several fit on a phone at once, which is
/// the whole difference between glancing at what is waiting and paging
/// through it — so everything on the card is the short form: a face, what
/// kind of thing it is, a title of two lines at most, where it happened, and
/// one verb.
class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    required this.item,
    required this.onDismiss,
    this.dense = false,
  });

  final WaitingItem item;
  final VoidCallback onDismiss;

  /// Short screen: the label, the title, and the verb. Nothing else.
  ///
  /// The face and the line saying where and when both go. Shrinking every
  /// element instead would keep more of them and make all of them harder to
  /// read, which is the wrong trade on the screen that has the least room.
  final bool dense;

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

    return Material(
      color: AppColors.raised,
      borderRadius: BorderRadius.circular(15),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // The whole card opens it. The button underneath is the interesting
        // verb — on a take that is Hear it, which is not the same as opening
        // the song — so both exist and neither is the only way in.
        key: Key('waiting_card_${item.id}'),
        onTap: item.onAction,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            // News wears its colour. A chore does not: a coloured edge is the
            // cheapest way to say "a person is in this one" from across a
            // room, and spending it on "make the song sheet" spends it on
            // nothing.
            border: Border.all(
              color: item.isNews
                  ? item.tint.withValues(alpha: 0.34)
                  : AppColors.line,
            ),
          ),
          child: Stack(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // The face on its own line, with the × opposite it.
                    //
                    // It shared a line with the label to begin with, and on a
                    // 390px phone that left the label about thirteen
                    // characters: the app introduced somebody as "Wants to
                    // con…". A card this narrow can afford one of them across
                    // the width, not both side by side.
                    if (dense)
                      // Nothing at all on a landscape phone. The face is the
                      // warmest thing on this card and it is also the only
                      // part that repeats something already written: the
                      // title for news names the person ("Dylan added bass")
                      // and the title for a request *is* the person. So it is
                      // the right thing to lose when there are a hundred
                      // pixels to spend.
                      const SizedBox.shrink()
                    else if (item.who != null)
                      PlayerFace(
                        name: item.who!,
                        color: item.tint,
                        photo: controller.avatarBytesFor(item.whoAvatarPath),
                        size: 20,
                      )
                    else
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: item.tint.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(item.icon, size: 12, color: item.tint),
                      ),
                    SizedBox(height: dense ? 0 : 6),
                    Text(
                      item.eyebrow ?? item.defaultEyebrow,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: item.tint,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    if (sub != null && !dense)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 10.5,
                            height: 1.2,
                          ),
                        ),
                      ),
                    const Spacer(),
                    const SizedBox(height: 8),
                    _CardAction(item: item, dense: dense),
                  ],
                ),
              ),
              // In the same corner on every card, doing the same thing.
              Positioned(
                top: 1,
                right: 1,
                child: IconButton(
                  key: Key('waiting_close_${item.id}'),
                  onPressed: onDismiss,
                  tooltip: item.onDismiss == null ? 'Not now' : 'Clear',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close_rounded,
                      size: 14, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one verb on the card, as wide as the card.
///
/// Full width rather than hugging its label: at this size a small button
/// floating in a corner reads as an afterthought, and the row is easier to
/// use when the thing to press is in the same place and the same shape on
/// every card.
class _CardAction extends StatelessWidget {
  const _CardAction({required this.item, this.dense = false});

  final WaitingItem item;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (item.isPlayable) return _PlayButton(item: item, dense: dense);

    final label = Text(
      item.actionLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
    );
    final size = Size.fromHeight(dense ? 28 : 30);

    // A chore gets an outline, not a solid. Two filled buttons of equal
    // weight side by side is the row saying a song sheet and a bass take
    // matter the same amount.
    return item.isNews
        ? FilledButton(
            key: Key('waiting_do_${item.id}'),
            onPressed: item.onAction,
            style: FilledButton.styleFrom(
              backgroundColor: item.tint,
              foregroundColor: AppColors.ink,
              minimumSize: size,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
            child: label,
          )
        : OutlinedButton(
            key: Key('waiting_do_${item.id}'),
            onPressed: item.onAction,
            style: OutlinedButton.styleFrom(
              foregroundColor: item.tint,
              side: BorderSide(color: item.tint.withValues(alpha: 0.5)),
              minimumSize: size,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
            child: label,
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
  const _PlayButton({required this.item, this.dense = false});

  final WaitingItem item;
  final bool dense;

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
            size: 17,
          ),
          label: Text(
            playing ? 'Playing' : 'Hear it',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.cyan,
            foregroundColor: AppColors.ink,
            minimumSize: Size.fromHeight(dense ? 28 : 30),
            padding: const EdgeInsets.only(left: 6, right: 10),
            visualDensity: VisualDensity.compact,
          ),
        );
      },
    );
  }
}
