import 'package:flutter/material.dart';

import '../app/beta_scope.dart';
import '../app/colabroom_theme.dart';
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
    super.key,
  });

  final String displayName;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenNotifications;

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
          // Expanded, and no Spacer after it: both are flex children, so a
          // Spacer here would split the free space and squeeze the app's own
          // name to half a row with the other half sitting empty beside it.
          const Expanded(child: BrandMark()),
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
