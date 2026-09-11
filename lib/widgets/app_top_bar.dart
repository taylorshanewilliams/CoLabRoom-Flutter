import 'package:flutter/material.dart';
import '../app/routes.dart';

import '../app/beta_scope.dart';
import '../app/colabroom_theme.dart';
import '../features/help/help_screen.dart';
import 'brand_mark.dart';

/// The mark, the news, and you.
///
/// These three lived on Home and only on Home. When Home was a tab that was
/// merely a bit hidden; once Home stopped being a tab it would have taken the
/// notification bell and the way into your own account with it — which is how
/// a refactor quietly removes the two things every screen needs.
///
/// So they became a bar both places wear. Same position, same order, on every
/// tab: the corner of the screen is a place people learn once.
class AppTopBar extends StatelessWidget {
  const AppTopBar({
    required this.displayName,
    required this.onOpenAccount,
    required this.onOpenNotifications,
    this.tabs = const <String>[],
    this.selectedTab = 0,
    this.onSelectTab,
    this.onGoHome,
    super.key,
  });

  final String displayName;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenNotifications;

  /// Where you can go, when there is room to say so along the top.
  ///
  /// On a phone these are the bottom tabs, where a thumb can reach them. On a
  /// desk that bar became a 116px strip down the left holding two words —
  /// the phone's navigation rotated, taking a column of the screen to say
  /// what fits in a sentence. Up here they cost nothing and give the whole
  /// width back to the work.
  final List<String> tabs;
  final int selectedTab;
  final ValueChanged<int>? onSelectTab;

  /// The way back to the top, from anywhere.
  ///
  /// Taylor, on the web: the mark "does nothing, maybe pressing that could be
  /// the home button that brings you back to just full screen home, because
  /// im not seeing a way to even do that on the web version." He is right
  /// that there was no way. On a phone the bottom bar is always under your
  /// thumb and every screen has a back arrow; on a desk the tabs are up here
  /// and a song, a room or the account can be several routes deep with
  /// nothing that says *out*.
  ///
  /// A logo that goes home is the oldest convention the web has, and this one
  /// was drawn, placed in the corner, and wired to nothing.
  final VoidCallback? onGoHome;

  /// The mark, with or without the tap that takes you home.
  ///
  /// Built once here because it goes into two different flex wrappers
  /// depending on whether the tabs are showing, and duplicating it was how
  /// one of the two ended up wrapped wrongly in the first place.
  Widget _mark() => onGoHome == null
      ? const BrandMark()
      : Semantics(
          button: true,
          label: 'Home',
          child: InkWell(
            key: const Key('brand_home_button'),
            onTap: onGoHome,
            borderRadius: BorderRadius.circular(15),
            child: const BrandMark(),
          ),
        );

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    // Pending invitations need an answer, so they count alongside unread
    // activity — both live in the same inbox.
    final inbox = controller.unreadNotificationCount + controller.invites.length;
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final initials = words.isEmpty
        ? 'CR'
        : words.length == 1
            ? words.first.substring(0, 1).toUpperCase()
            : '${words.first.substring(0, 1)}${words.last.substring(0, 1)}'
                .toUpperCase();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
      child: Row(
        children: <Widget>[
          // Expanded when it is alone up here, and a Spacer must never follow
          // it.
          //
          // This is the bug Taylor reported as "the colabroom logo at the top
          // shrunk a lot", and the comment warning about it was already
          // sitting here when the tabs landed on top of it. `Flexible` and
          // `Spacer` are both flex children with flex 1, so a Row holding
          // both hands each of them half the free space — the mark got 95 of
          // the 190 spare pixels on a 360px phone, the icon and its gap ate
          // 58 of those, and `BrandMark`'s own `FittedBox` dutifully shrank
          // the wordmark to fit the 37 that were left. Nothing overflowed and
          // nothing threw. The app just quietly wrote its own name at a
          // quarter size, next to an equal amount of nothing.
          //
          // So: one flex child on this side, whichever it is. With tabs, the
          // tab strip is the thing that absorbs the slack and the mark takes
          // its natural width beside it; without them, the mark takes it all.
          if (tabs.isEmpty)
            Expanded(child: _mark())
          else ...<Widget>[
            Flexible(child: _mark()),
            const SizedBox(width: 26),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (var i = 0; i < tabs.length; i += 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: TextButton(
                          onPressed: () => onSelectTab?.call(i),
                          style: TextButton.styleFrom(
                            foregroundColor: i == selectedTab
                                ? AppColors.text
                                : AppColors.muted,
                          ),
                          // Styled on the Text rather than through
                          // `styleFrom(textStyle:)`.
                          //
                          // `ButtonStyleButton` picks the widget's text style
                          // *or* the theme's — `??`, not a merge — so a style
                          // given there replaces the resolved one entirely
                          // and takes the font family with it. It resolves to
                          // the platform font on a device and so looks fine;
                          // it also means these tabs would silently ignore a
                          // custom family the day the theme sets one, and
                          // they render with no font at all under the render
                          // harness, which is where the app is looked at.
                          child: Text(
                            tabs[i],
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: i == selectedTab
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          // A question mark in the corner, beside the bell.
          //
          // The help screen was reachable only from Account, which is where
          // somebody goes to change their password — not where they are
          // standing when they wonder what this app can do. It answers good
          // questions and nobody could find it.
          Semantics(
            button: true,
            label: 'Help',
            child: InkResponse(
              key: const Key('top_bar_help'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: AppRoutes.help),
                  builder: (_) => const HelpScreen(),
                ),
              ),
              radius: 22,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.help_outline_rounded,
                    color: AppColors.muted, size: 24),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Notifications',
            child: InkResponse(
              onTap: onOpenNotifications,
              radius: 24,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    const Icon(Icons.notifications_outlined,
                        color: AppColors.text, size: 26),
                    if (inbox > 0)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          constraints:
                              const BoxConstraints(minWidth: 16, minHeight: 16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            inbox > 9 ? '9+' : '$inbox',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Account',
            child: InkResponse(
              onTap: onOpenAccount,
              radius: 28,
              containedInkWell: true,
              customBorder: const CircleBorder(),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: <Color>[AppColors.blue, Color(0xFF124A80)],
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: Color(0x242B6FFF), blurRadius: 24),
                  ],
                ),
                child: controller.avatarBytes != null
                    ? Image.memory(
                        controller.avatarBytes!,
                        fit: BoxFit.cover,
                        width: 44,
                        height: 44,
                      )
                    : Text(initials,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
