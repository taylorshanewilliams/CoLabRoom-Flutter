/// What just went wrong, so the person can be asked about it.
///
/// Failures in this app are already reported. `reportAndDescribe` is called in
/// around forty places and every one of them lands a row in `analysis_errors`
/// with the exception, the stage and the route. That half works.
///
/// The half that does not is the person's. They are shown a sentence — "That
/// did not go through" — and then nothing asks them the only question the
/// table cannot answer: *what were you trying to do?* The Account screen has
/// had a form for it since the first build and it has never once been used,
/// because a form on one screen is a form somebody has to go and find after
/// the moment has passed, which is the moment they decide a text message is
/// easier.
///
/// So the sentence gets a way to say more, and what they say arrives with the
/// exception already attached rather than asking them to describe an error
/// message they were shown and dismissed.
library;

/// The last failure this session, if it is still recent enough to be the one
/// somebody is talking about.
abstract final class RecentTrouble {
  static String? _detail;
  static String? _route;
  static DateTime? _at;

  /// How long a failure stays attachable.
  ///
  /// Somebody opening the feedback form twenty minutes later is writing about
  /// something else, and silently stapling an unrelated stack trace to their
  /// message would make the report worse rather than better — it would look
  /// like a diagnosis and point at the wrong thing.
  static const Duration _freshFor = Duration(minutes: 5);

  /// Called by [reportAndDescribe] for every failure it describes.
  static void remember(Object error, {String? route}) {
    _detail = error.toString();
    _route = route;
    _at = DateTime.now();
  }

  static bool get _fresh {
    final at = _at;
    return at != null && DateTime.now().difference(at) < _freshFor;
  }

  /// The exception, if there was a recent one.
  static String? get detail => _fresh ? _detail : null;

  /// Where it happened, if there was a recent one.
  static String? get route => _fresh ? _route : null;

  /// After a report is sent, so the next one does not carry it again.
  static void clear() {
    _detail = null;
    _route = null;
    _at = null;
  }
}
