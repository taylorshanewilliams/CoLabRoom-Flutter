/// Every place in this app that deserves an address.
///
/// A phone app does not need one. You are wherever the last tap put you, the
/// back gesture is a swipe, and nobody types a screen's name. So this app was
/// built with thirty-odd anonymous `Navigator.push` calls, which is the right
/// shape for a phone and the reason the web build felt like a phone in a
/// browser: **addressable state is most of what separates the two.**
///
/// This is the table. Nothing here does the navigating — the pushes stay
/// where they are — but every one of them names itself from here, so the
/// address bar says where you are, browser history has somewhere to go back
/// to, and a crash report can name the screen rather than the tab.
///
/// It is also the input to the next step. Turning these into real deep links
/// — paste a song address and land on the song, refresh and stay put — needs
/// the Router API reading exactly these paths, and a parser wants a table to
/// parse against. That is why [match] exists before anything uses it.
///
/// **What is deliberately not here:** sheets, dialogs and pickers. A modal is
/// not a place. Giving one an address means the back button dismisses it in
/// some browsers and reopens it on refresh, which is worse than leaving it
/// anonymous.
abstract final class AppRoutes {
  // ---------------------------------------------------------------- shell
  static const String home = '/';
  static const String openMic = '/openmic';
  static const String listen = '/openmic/listen';

  // ------------------------------------------------------------- a song
  static String song(String id) => '/song/$id';
  static String songSheet(String id) => '/song/$id/sheet';
  static String songTakes(String id) => '/song/$id/takes';
  static String songLive(String id) => '/song/$id/live';
  static String songLyrics(String id) => '/song/$id/lyrics';
  static String songHistory(String id) => '/song/$id/history';

  // -------------------------------------------------- somebody else's work
  /// A song on the Open Mic, as heard by somebody who is not in the room.
  ///
  /// Not `/song/:id`, deliberately: it is a different page with a different
  /// audience, and one address for both would mean a link behaving
  /// differently depending on who opened it.
  static String heard(String id) => '/heard/$id';
  static String musician(String id) => '/musician/$id';

  // -------------------------------------------------------------- places
  static String room(String id) => '/room/$id';
  static String setlist(String id) => '/set/$id';

  // ---------------------------------------------------------------- yours
  static const String account = '/account';
  static const String notifications = '/notifications';
  static const String help = '/help';
  static const String whatYouGet = '/what-you-get';
  static const String notificationSettings = '/settings/notifications';
  static const String blocked = '/settings/blocked';
  static const String latency = '/settings/latency';

  /// What a path points at, or null when nothing does.
  ///
  /// Exists so the table can be read as well as written. A parser that has to
  /// re-derive these shapes from string literals scattered through the app is
  /// how the two halves drift apart.
  static RouteTarget? match(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null) return null;
    final parts = uri.pathSegments;
    if (parts.isEmpty) return const RouteTarget(RoutePlace.home);
    switch (parts.first) {
      case 'song':
        if (parts.length < 2) return null;
        final id = parts[1];
        if (parts.length == 2) return RouteTarget(RoutePlace.song, id);
        return switch (parts[2]) {
          'sheet' => RouteTarget(RoutePlace.songSheet, id),
          'takes' => RouteTarget(RoutePlace.songTakes, id),
          'live' => RouteTarget(RoutePlace.songLive, id),
          'lyrics' => RouteTarget(RoutePlace.songLyrics, id),
          'history' => RouteTarget(RoutePlace.songHistory, id),
          _ => null,
        };
      case 'heard':
        return parts.length < 2 ? null : RouteTarget(RoutePlace.heard, parts[1]);
      case 'musician':
        return parts.length < 2
            ? null
            : RouteTarget(RoutePlace.musician, parts[1]);
      case 'room':
        return parts.length < 2 ? null : RouteTarget(RoutePlace.room, parts[1]);
      case 'set':
        return parts.length < 2
            ? null
            : RouteTarget(RoutePlace.setlist, parts[1]);
      case 'openmic':
        return parts.length > 1 && parts[1] == 'listen'
            ? const RouteTarget(RoutePlace.listen)
            : const RouteTarget(RoutePlace.openMic);
      case 'account':
        return const RouteTarget(RoutePlace.account);
      case 'notifications':
        return const RouteTarget(RoutePlace.notifications);
      case 'help':
        return const RouteTarget(RoutePlace.help);
      case 'what-you-get':
        return const RouteTarget(RoutePlace.whatYouGet);
      case 'settings':
        if (parts.length < 2) return null;
        return switch (parts[1]) {
          'notifications' => const RouteTarget(RoutePlace.notificationSettings),
          'blocked' => const RouteTarget(RoutePlace.blocked),
          'latency' => const RouteTarget(RoutePlace.latency),
          _ => null,
        };
      default:
        return null;
    }
  }
}

enum RoutePlace {
  home,
  openMic,
  listen,
  song,
  songSheet,
  songTakes,
  songLive,
  songLyrics,
  songHistory,
  heard,
  musician,
  room,
  setlist,
  account,
  notifications,
  help,
  whatYouGet,
  notificationSettings,
  blocked,
  latency,
}

/// A place, and the thing it is about when it is about something.
class RouteTarget {
  const RouteTarget(this.place, [this.id]);

  final RoutePlace place;
  final String? id;

  @override
  bool operator ==(Object other) =>
      other is RouteTarget && other.place == place && other.id == id;

  @override
  int get hashCode => Object.hash(place, id);

  @override
  String toString() => id == null ? '$place' : '$place($id)';
}
