/// Calls in a room (0134, call-token).
///
/// Stage A, agreed with Taylor on 16 September 2026: people who share a room
/// and are 18 or over. 13-17 come next, through a parent or guardian. Nothing
/// is recorded.
library;

/// Where somebody stands for calls, as the server says.
enum CallStanding {
  /// Never asked for a birth month. Asked before the first call.
  unknown,
  adult,

  /// Under 18. Calls come with the guardian stage.
  minor,
}

CallStanding callStandingFrom(String? raw) => switch (raw) {
      'adult' => CallStanding.adult,
      'minor' => CallStanding.minor,
      _ => CallStanding.unknown,
    };

/// A ticket into one room's call, from call-token.
class CallTicket {
  const CallTicket({
    required this.url,
    required this.token,
    required this.room,
    required this.identity,
  });

  final String url;
  final String token;
  final String room;
  final String identity;
}

/// Somebody the room shows as in its call right now.
class InCallPerson {
  const InCallPerson({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}

/// A call that would not let somebody in, with the reason said to them.
class CallRefused implements Exception {
  const CallRefused(this.message, {this.birthMonthNeeded = false});

  final String message;

  /// Not a no: the server needs a birth month before it can answer.
  final bool birthMonthNeeded;

  @override
  String toString() => message;
}
