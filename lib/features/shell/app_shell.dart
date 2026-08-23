import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/colabroom_theme.dart';
import '../account/account_screen.dart';
import '../home/home_screen.dart';
import '../notifications/notifications_screen.dart';
import '../songs/songs_screen.dart';
import '../studio/studio_home_screen.dart';
import '../toolbox/toolbox_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({required this.displayName, this.supabase, super.key});

  final String displayName;
  final SupabaseClient? supabase;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _index = 0;
    if (kIsWeb && Uri.base.queryParameters['deleteAccount'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAccount());
    }
    _screens = <Widget>[
      HomeScreen(
        displayName: widget.displayName,
        onSeeSongs: () => setState(() => _index = 1),
        onOpenAccount: _openAccount,
        onOpenNotifications: _openNotifications,
      ),
      const SongsScreen(),
      const StudioHomeScreen(),
      const ToolboxScreen(),
    ];
  }

  // Account is no longer one of the four tabs (Toolbox took its slot) — it's
  // reached the same way it always has been from Home's top-right icon,
  // just as a pushed route instead of a tab switch.
  void _openAccount() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AccountScreen(supabase: widget.supabase)),
    );
  }

  void _openNotifications() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
    );
  }

  // Four destinations, each one a thing a musician does. Rooms moved inside
  // Songs as a filter — they decide who can see what, which is an attribute
  // of a song rather than somewhere you want to navigate to on the way to
  // your work. Invites folded into the notification inbox: it was a
  // permanent tab for something that happens a handful of times, and once
  // notifications existed it was the same event in two places.
  static const _destinations = <_Destination>[
    _Destination('Home', Icons.home_rounded),
    _Destination('Songs', Icons.library_music_rounded),
    _Destination('Studio', Icons.auto_awesome_rounded),
    _Destination('Toolbox', Icons.construction_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        if (wide) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 116,
                    child: _NavigationRail(
                      index: _index,
                      destinations: _destinations,
                      onSelect: (value) => setState(() => _index = value),
                    ),
                  ),
                  Expanded(child: IndexedStack(index: _index, children: _screens)),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: _index, children: _screens)),
          bottomNavigationBar: SafeArea(
            top: false,
            child: _BottomNavigation(
              index: _index,
              destinations: _destinations,
              onSelect: (value) => setState(() => _index = value),
            ),
          ),
        );
      },
    );
  }
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    required this.index,
    required this.destinations,
    required this.onSelect,
  });

  final int index;
  final List<_Destination> destinations;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: AppColors.ink,
        boxShadow: <BoxShadow>[
          BoxShadow(color: Color(0x22000000), blurRadius: 28, offset: Offset(0, -8)),
        ],
      ),
      child: Row(
        children: List<Widget>.generate(destinations.length, (itemIndex) {
          final selected = itemIndex == index;
          final item = destinations[itemIndex];
          return Expanded(
            child: _NavButton(
              destination: item,
              selected: selected,
              onTap: () => onSelect(itemIndex),
            ),
          );
        }),
      ),
    );
  }
}

class _NavigationRail extends StatelessWidget {
  const _NavigationRail({
    required this.index,
    required this.destinations,
    required this.onSelect,
  });

  final int index;
  final List<_Destination> destinations;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.deepNavy,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(destinations.length, (itemIndex) {
          final item = destinations[itemIndex];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: _NavButton(
              destination: item,
              selected: itemIndex == index,
              onTap: () => onSelect(itemIndex),
            ),
          );
        }),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.destination, required this.selected, required this.onTap});

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.cyan : AppColors.muted;
    return Semantics(
      selected: selected,
      button: true,
      label: destination.label,
      child: InkResponse(
        onTap: onTap,
        radius: 32,
        containedInkWell: false,
        splashColor: AppColors.cyan.withValues(alpha: 0.08),
        child: SizedBox(
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: selected
                      ? const <BoxShadow>[
                          BoxShadow(color: Color(0x443AD3FF), blurRadius: 24, spreadRadius: 1),
                          BoxShadow(color: Color(0x302B6FFF), blurRadius: 38),
                        ]
                      : const <BoxShadow>[],
                ),
                child: Icon(destination.icon, size: 24, color: color),
              ),
              const SizedBox(height: 3),
              Text(
                destination.label,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon);

  final String label;
  final IconData icon;
}
