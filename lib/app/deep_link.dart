import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/music_repository.dart';
import '../features/account/account_screen.dart';
import '../features/account/blocked_people_screen.dart';
import '../features/account/what_you_get.dart';
import '../features/dev/latency_probe_screen.dart';
import '../features/help/help_screen.dart';
import '../features/layers/a_moment_from_a_link.dart';
import '../features/meeting/add_person_screen.dart';
import '../features/meeting/your_code_screen.dart';
import '../features/notifications/notification_settings_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/openmic/musician_profile_screen.dart';
import '../features/openmic/open_mic_song_screen.dart';
import '../features/rooms/room_detail_screen.dart';
import '../features/rooms/setlist_detail_screen.dart';
import '../features/workspace/song_workspace_screen.dart';
import '../services/incoming_addresses.dart';
import 'beta_config.dart';
import 'routes.dart';

/// Turning an address back into the place it names.
///
/// [AppRoutes] gave every screen an address and the address bar started
/// saying where you are. This is the other direction, and it is the half
/// somebody notices: paste a link to a song and land on that song; press
/// refresh and still be there; send a profile to somebody and have it open
/// for them.
///
/// It is deliberately not a router rewrite. Flutter already has the hook for
/// exactly this — `Navigator.onGenerateInitialRoutes` builds a *stack* from
/// the incoming route — so the shell goes on the bottom and the deep-linked
/// screen on top of it. Back then works from a pasted link, which it would
/// not if the link replaced the app.
abstract final class DeepLink {
  /// Where the app was opened, as the engine reports it.
  ///
  /// On the web this is the path in the address bar. On a phone it is `/`
  /// unless a link opened the app, and then it is the whole link, which
  /// [AppRoutes.match] reads the path from. A link that arrived while nothing
  /// could open it — tapped while the sign-in screen was up — goes first:
  /// it is the more recent of the two. See IncomingAddresses.
  static String initialRoute(WidgetsBinding binding) =>
      IncomingAddresses.waiting?.toString() ?? binding.platformDispatcher.defaultRouteName;

  /// The stack an address should open as.
  ///
  /// Always the shell first: a link that replaces the app leaves somebody on
  /// a song with nowhere to go back to, which is the phone-in-a-browser
  /// problem wearing a different hat.
  static List<Route<dynamic>> stackFor({
    required String path,
    required Widget Function(int tab) shell,
    required MusicRepository repository,
    SupabaseClient? supabase,
    bool devTools = BetaConfig.devTools,
  }) {
    final target = AppRoutes.match(path);
    final tab = target?.place == RoutePlace.openMic ||
            target?.place == RoutePlace.listen
        ? 1
        : 0;
    final routes = <Route<dynamic>>[
      MaterialPageRoute<void>(
        settings: RouteSettings(name: tab == 1 ? AppRoutes.openMic : AppRoutes.home),
        builder: (_) => shell(tab),
      ),
    ];

    final on = _routeFor(target,
        repository: repository, supabase: supabase, devTools: devTools);
    if (on != null) routes.add(on);
    return routes;
  }

  /// The screen an address names, for an address that arrives while the app
  /// is already open — the browser's forward button, a link pasted into the
  /// bar. Null when it names nothing that opens cold, which includes the two
  /// tabs: those are a place to *return* to, and the caller pops for them.
  static Route<dynamic>? routeFor(
    String path, {
    required MusicRepository repository,
    SupabaseClient? supabase,
    bool devTools = BetaConfig.devTools,
  }) =>
      _routeFor(AppRoutes.match(path),
          repository: repository, supabase: supabase, devTools: devTools);

  /// Whether an address is one of the two tabs rather than a screen on top.
  static bool isATab(String path) {
    final place = AppRoutes.match(path)?.place;
    return place == RoutePlace.home || place == RoutePlace.openMic;
  }

  /// One screen, from one address, or null when the address names no screen
  /// that can be rebuilt from an id alone.
  ///
  /// The song sub-pages are the honest gap. `SongAnalysisScreen` and the
  /// others take a loaded `SongProject` rather than an id, so an address like
  /// `/song/x/sheet` cannot be opened cold without a loader that does not
  /// exist yet. Rather than invent one here, those fall back to the song
  /// itself — which is where somebody would have to go first anyway, and is
  /// one tap from the sheet.
  static Route<dynamic>? _routeFor(
    RouteTarget? target, {
    required MusicRepository repository,
    SupabaseClient? supabase,
    required bool devTools,
  }) {
    if (target == null) return null;
    final id = target.id;

    Route<dynamic> page(String name, Widget child) => MaterialPageRoute<void>(
          settings: RouteSettings(name: name),
          builder: (_) => child,
        );

    return switch (target.place) {
      RoutePlace.home || RoutePlace.openMic => null,
      // The stage is a mode of the Open Mic rather than a screen that opens
      // cold — it wants the filter somebody chose, and a cold link has none.
      RoutePlace.listen => null,
      RoutePlace.song ||
      RoutePlace.songSheet ||
      RoutePlace.songTakes ||
      RoutePlace.songLive ||
      RoutePlace.songLyrics ||
      RoutePlace.songHistory =>
        id == null
            ? null
            : page(AppRoutes.song(id), SongWorkspaceScreen(projectId: id)),
      // A link to a moment of a recording, which opens for a member and
      // refuses everybody else. The screen decides which, because deciding
      // needs the library and a route table has none.
      RoutePlace.moment => target.at == null
          ? null
          : page(target.at!.path, MomentFromALink(at: target.at!)),
      RoutePlace.heard => id == null
          ? null
          : page(
              AppRoutes.heard(id),
              OpenMicSongScreen(projectId: id, repository: repository),
            ),
      RoutePlace.musician => id == null
          ? null
          : page(
              AppRoutes.musician(id),
              MusicianProfileScreen(profileId: id, repository: repository),
            ),
      RoutePlace.meet => id == null
          ? null
          : page(AppRoutes.meet(id), AddPersonScreen(code: id, repository: repository)),
      RoutePlace.yourCode =>
        page(AppRoutes.yourCode, YourCodeScreen(repository: repository)),
      RoutePlace.room =>
        id == null ? null : page(AppRoutes.room(id), RoomDetailScreen(roomId: id)),
      RoutePlace.setlist => id == null
          ? null
          : page(AppRoutes.setlist(id), SetlistDetailScreen(setlistId: id)),
      RoutePlace.account =>
        page(AppRoutes.account, AccountScreen(supabase: supabase)),
      RoutePlace.notifications =>
        page(AppRoutes.notifications, const NotificationsScreen()),
      RoutePlace.help => page(AppRoutes.help, const HelpScreen()),
      RoutePlace.whatYouGet => page(AppRoutes.whatYouGet, const WhatYouGet()),
      RoutePlace.notificationSettings => page(
          AppRoutes.notificationSettings, const NotificationSettingsScreen()),
      RoutePlace.blocked => page(
          AppRoutes.blocked, BlockedPeopleScreen(repository: repository)),
      // Behind the same switch as the row on Account. Hiding only the row
      // left the tool one remembered link away on every tester's phone
      // (review of the audit fixes, 17 September 2026); without the switch
      // the address opens the app, like any address that names nothing.
      RoutePlace.latency => devTools
          ? page(AppRoutes.latency, const LatencyProbeScreen())
          : null,
    };
  }
}
