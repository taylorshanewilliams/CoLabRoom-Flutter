import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../account/account_screen.dart';
import '../notifications/notifications_screen.dart';
import '../openmic/open_mic_screen.dart';
import '../openmic/open_mic_song_screen.dart';
import '../songs/songs_screen.dart';
import '../workspace/song_analysis_screen.dart';
import '../../services/current_route.dart';
import '../../widgets/now_playing_bar.dart';
import '../../services/user_facing_error.dart';

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
    // Where somebody lands depends on whether they have anything here yet.
    //
    // An app that opens on your own empty shelf has told a new person, on
    // their very first screen, that there is nothing here. The Open Mic is
    // playing from the moment it loads, so somebody with no songs arrives in
    // a room with music in it and can see what the app is for before making
    // anything — and the moment they have one song of their own, that becomes
    // the more useful place to land, so it does.
    _index = _landing();
    // So a crash on a tab names that tab. Thirty-four of this app's route
    // pushes are unnamed, so a navigator observer alone would record nothing;
    // the destination is the cheap fact that is always true.
    CurrentRoute.enter(_destinations[_index].label);
    if (kIsWeb && Uri.base.queryParameters['deleteAccount'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAccount());
    }
    _screens = <Widget>[
      SongsScreen(
        displayName: widget.displayName,
        onOpenAccount: _openAccount,
        onOpenNotifications: _openNotifications,
      ),
      // Built through a Builder because it needs the repository, and the
      // scope is not reachable from initState.
      Builder(
        builder: (context) => OpenMicScreen(
          repository: BetaScope.of(context, listen: false).repository,
          displayName: widget.displayName,
          onOpenAccount: _openAccount,
          onOpenNotifications: _openNotifications,
        ),
      ),
    ];
  }

  // Account is no longer one of the four tabs — it's reached the same way it
  // always has been from Home's top-right icon, just as a pushed route
  // instead of a tab switch. The Toolbox left the bar for a different
  // reason: see the note above _destinations.
  void _openAccount() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AccountScreen(supabase: widget.supabase)),
    );
  }

  /// Opens whatever is playing, when it said where it came from.
  void _openPlayingSong(String projectId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Open Mic song'),
      builder: (context) => OpenMicSongScreen(
        projectId: projectId,
        repository: BetaScope.of(context, listen: false).repository,
      ),
    ));
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
  /// Left to right, the life of a song: what you have, what you are making,
  /// what you are finishing.
  ///
  /// The bar used to end in the Toolbox — chord shapes, a capo chart, scale
  /// formulas. Reference material, and the only tab that was not about your
  /// own songs. It was also mostly empty: seven categories of which five said
  /// "Coming soon". A quarter of the navigation spent on dead ends.
  ///
  /// The Studio and the Control Room are a real facility's floor plan, and
  /// borrowing it does the teaching that no onboarding copy could: the studio
  /// is where you play, the control room is where you listen back and decide.
  /// It also puts the free thing and the paid thing in different rooms, which
  /// is a better way to explain a price than a badge.
  static const _destinations = <_Destination>[
    _Destination('Your music', Icons.library_music_rounded),
    _Destination('Open Mic', Icons.mic_external_on_rounded),
  ];

  /// Your work, or everybody else's, depending on whether you have any yet.
  ///
  /// Read once, on launch. Re-deciding it later would move the ground under
  /// somebody the moment they made their first song, which is exactly the
  /// wrong moment to move anything.
  int _landing() {
    try {
      final controller = BetaScope.of(context, listen: false);
      final anySongs =
          controller.rooms.any((room) => room.projects.isNotEmpty);
      return anySongs ? 0 : 1;
    } catch (_) {
      // No scope yet in some test harnesses. Your own music is the safe
      // default: it is the tab that works with no network at all.
      return 0;
    }
  }

  /// Recording, from anywhere.
  ///
  /// The Studio's one capability nothing else had was *record something that
  /// has no home yet*, and that is a button rather than a destination. As a
  /// tab it cost a permanent quarter of the navigation to hold a list of
  /// unfiled takes; as a button it is one tap from all three tabs instead of
  /// one tap from whichever one you happened to be on.
  Future<void> _record() async {
    final controller = BetaScope.of(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      // The song exists before the recording does. That is the whole change:
      // there is no holding pen a recording sits in until somebody converts
      // it, because conversion is what once forked a song into two projects
      // with the same name and half the words each.
      final project = await controller.startIdea();
      await navigator.push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'Song sheet'),
        builder: (_) => SongAnalysisScreen(project: project, autoRecord: true),
      ));

      // Sweep up if nobody recorded anything.
      //
      // The song is created on the tap, before the recorder is on screen, so
      // a thumb brushing this button leaves a permanent auto-named empty song
      // behind — which is exactly what it did, repeatedly, in real use.
      //
      // Creating the song later would be the deeper fix and would reintroduce
      // the holding pen that 0066 spent 2,809 lines removing: audio waiting
      // somewhere to be converted is what used to fork a song into two with
      // the same name and half the words each. So the song is still made
      // first, and anything nobody touched is taken back.
      //
      // The server decides what "untouched" means and is deliberately timid
      // about it: no takes, no recording, no words, never published, yours,
      // made in the last two hours. Anything else stays.
      final discarded = await controller.repository.discardIfUntouched(project.id);
      if (discarded) await controller.load();
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(reportAndDescribe(
            error,
            service: 'app',
            stage: 'start_idea',
            route: 'Home',
          )),
        ));
    }
  }

  /// The tab contents, but each one only constructed once it has actually
  /// been opened.
  ///
  /// IndexedStack keeps every child alive, which is what preserves scroll
  /// position and typed state when switching tabs — but it also *builds*
  /// them all immediately. That meant launching the app constructed Studio,
  /// which fetches drafts over the network, before the user had looked at it
  /// — paying for work nobody asked for on the slowest frame there is. Once a
  /// tab has been visited it stays built, so the state-preserving behaviour is
  /// unchanged.
  List<Widget> get _lazyScreens => <Widget>[
        for (var i = 0; i < _screens.length; i += 1)
          _LazyTab(active: _index == i, child: _screens[i]),
      ];

  /// Moves to a destination and says so, so a failure anywhere under it is
  /// reported against the right quarter of the app.
  void _go(int value) {
    setState(() => _index = value);
    CurrentRoute.enter(_destinations[value].label);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        if (wide) {
          return Scaffold(
            body: SafeArea(
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 116,
                          child: _NavigationRail(
                            index: _index,
                            destinations: _destinations,
                            onSelect: _go,
                          ),
                        ),
                        Expanded(
                          child: IndexedStack(
                              index: _index, children: _lazyScreens),
                        ),
                      ],
                    ),
                  ),
                  NowPlayingBar(onOpen: _openPlayingSong),
                ],
              ),
            ),
            floatingActionButton: _RecordButton(
                onTap: () => unawaited(_record()), extended: true),
          );
        }

        return Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: _index, children: _lazyScreens)),
          floatingActionButton: _RecordButton(
              onTap: () => unawaited(_record()), extended: false),
          // The bar sits above the tabs and below everything else, so it
          // survives switching tabs — which is the entire point. Wrapped with
          // the navigation rather than placed in the body, or it would scroll
          // away with whichever list started it.
          bottomNavigationBar: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                NowPlayingBar(onOpen: _openPlayingSong),
                _BottomNavigation(
              index: _index,
                  destinations: _destinations,
                  onSelect: (value) => setState(() => _index = value),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The one thing you can always do.
///
/// Gold, because gold is what this app spends on the things that matter most,
/// and because it must not read as part of the tab bar sitting under it —
/// a fourth destination is exactly what this change removed.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.onTap, required this.extended});

  final VoidCallback onTap;

  /// Wide layouts have the room for the word; a phone does not, and an
  /// unlabelled circle with a microphone in it is not ambiguous.
  final bool extended;

  @override
  Widget build(BuildContext context) {
    if (extended) {
      return FloatingActionButton.extended(
        key: const Key('shell_record_button'),
        onPressed: onTap,
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.ink,
        icon: const Icon(Icons.mic_rounded),
        label: const Text('Record',
            style: TextStyle(fontWeight: FontWeight.w800)),
      );
    }
    return FloatingActionButton(
      key: const Key('shell_record_button'),
      onPressed: onTap,
      backgroundColor: AppColors.gold,
      foregroundColor: AppColors.ink,
      tooltip: 'Record something',
      child: const Icon(Icons.mic_rounded),
    );
  }
}

/// Renders [child] only after this tab has been selected at least once,
/// then keeps it. Deferring construction is the point; discarding it again
/// afterwards would throw away exactly the state IndexedStack is here for.
class _LazyTab extends StatefulWidget {
  const _LazyTab({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_LazyTab> createState() => _LazyTabState();
}

class _LazyTabState extends State<_LazyTab> {
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    _opened = _opened || widget.active;
    return _opened ? widget.child : const SizedBox.shrink();
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
              // One line, shrunk if it has to be.
              //
              // "Control Room" is two words where every other label is one,
              // and on a narrow tab it wrapped — which overflowed the fixed
              // 56-pixel column by a single pixel and failed the landscape
              // layout test. Scaling down beats truncating: "Control R…" is
              // not a name.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                        color: color, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
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
