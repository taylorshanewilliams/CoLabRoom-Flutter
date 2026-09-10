import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// Everything that wants something from you, in one place.
///
/// Taylor: "lets find a way to have all suggestions, notifications, continue
/// working, friend requests etc all in one place, clean the screen up a
/// little."
///
/// Before this there were three cards in two positions on Your music — the
/// news above the heading, what you left below it, and the song-sheet queue
/// below that — each with its own shape, its own colour, and its own idea of
/// how to be dismissed. Three answers to the same question is not three
/// features, it is one feature somebody has built three times.
///
/// He also said the thing that fixes it: "the text, sizing, font is all the
/// same as the rest i didnt even notice it said somethign else or stop asking
/// this one at first."
///
/// So this is one strip with one grammar, and it is deliberately not shaped
/// like a song. A suggestion that looks like content is content somebody
/// tries to open; a suggestion that looks like a suggestion is one they can
/// answer or close without thinking about it.
///
/// **Every row has both.** A verb and a way out, always, in the same two
/// places on every row. That is the whole rule.
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
    this.detail,
    this.onDismiss,
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

  IconData get icon => switch (kind) {
        WaitingKind.request => Icons.person_add_alt_1_rounded,
        WaitingKind.news => Icons.graphic_eq_rounded,
        WaitingKind.unfinished => Icons.history_rounded,
        WaitingKind.sheet => Icons.article_outlined,
      };

  Color get tint => switch (kind) {
        WaitingKind.request => AppColors.cyan,
        WaitingKind.news => AppColors.cyan,
        WaitingKind.unfinished => AppColors.muted,
        WaitingKind.sheet => AppColors.gold,
      };
}

/// The strip itself.
///
/// Renders nothing at all when there is nothing waiting, which is the state it
/// should be in most days. A permanent box that says "nothing here" is the
/// thing this is replacing.
class WaitingOnYou extends StatefulWidget {
  const WaitingOnYou({required this.items, super.key});

  final List<WaitingItem> items;

  /// How many are shown before the rest are folded away.
  ///
  /// Three, because the strip sits above somebody's songs and its job is to
  /// be answered and gone. A list of nine things to deal with before you can
  /// see your own music is a worse version of the problem.
  static const int shown = 3;

  @override
  State<WaitingOnYou> createState() => _WaitingOnYouState();
}

class _WaitingOnYouState extends State<WaitingOnYou> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final all = widget.items;
    final visible =
        _expanded ? all : all.take(WaitingOnYou.shown).toList(growable: false);
    final hidden = all.length - visible.length;

    return Container(
      key: const Key('waiting_on_you'),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        // Its own surface, one shade off the page. Enough that the eye reads
        // it as a different kind of thing from the songs underneath, and not
        // so much that it shouts.
        color: AppColors.raised.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < visible.length; i += 1) ...<Widget>[
            if (i > 0) const Divider(height: 1, color: AppColors.line),
            _WaitingRow(item: visible[i]),
          ],
          if (hidden > 0 || _expanded) ...<Widget>[
            const Divider(height: 1, color: AppColors.line),
            InkWell(
              key: const Key('waiting_more'),
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(13)),
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
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // The verb, in the same place on every row, and it does not look
          // like the words around it. Taylor did not notice the old actions
          // because they were the same size and weight as the sentence they
          // sat under.
          TextButton(
            key: Key('waiting_do_${item.id}'),
            onPressed: item.onAction,
            style: TextButton.styleFrom(
              foregroundColor: item.tint,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            // Styled on the Text rather than through styleFrom(textStyle:).
            // ButtonStyleButton picks the widget's style *or* the theme's --
            // `??`, not a merge -- so a style given there replaces the
            // resolved one and takes the font family with it. There is a test
            // that catches this, and it caught this.
            child: Text(
              item.actionLabel,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w800),
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
