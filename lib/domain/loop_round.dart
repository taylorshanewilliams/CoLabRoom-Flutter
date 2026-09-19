import 'package:flutter/foundation.dart';

/// A passage of a song going round a room in turns (migration 0159).
///
/// Every Musician, Same Song, 17 September 2026, slice 33: "A beat goes round
/// a room in 16-bar turns. 'Skip me' is always free. It plays back as one
/// conversation." Cyphers, trading fours, bluegrass breaks, jugalbandi by
/// post -- the one way of playing together that fits the physics, because
/// nobody has to be in time with anybody else's phone.
///
/// A round is a passage, kept as two times and named on each phone from its
/// own bars (see loopFor), and an order of people. A turn is an ordinary
/// take that starts on the passage, so its level, its expiry and its
/// player's say over who hears it are the ones every take already has.
///
/// What is not here is on purpose: no score, no vote, no count, no timer and
/// no winner. There is nowhere in this object to put one.

/// What a seat reads as. Three words, none of them a verdict.
enum SeatState {
  /// In the order and not played yet.
  waiting,

  /// Their turn is on the song and the room can hear it.
  played,

  /// Sitting this one out: skipped, passed over while away, or their take
  /// pulled. Only ever seen on your own seat -- the database leaves
  /// everybody else's quiet seats out of the list entirely.
  out;

  static SeatState parse(String? value) => switch (value) {
        'played' => SeatState.played,
        'out' => SeatState.out,
        _ => SeatState.waiting,
      };
}

/// One person in the order.
@immutable
class LoopSeat {
  const LoopSeat({
    required this.userId,
    required this.name,
    required this.state,
    this.layerId,
  });

  final String userId;
  final String name;
  final SeatState state;

  /// The take that was their turn. Set exactly when [state] is played.
  final String? layerId;

  factory LoopSeat.fromJson(Map<String, dynamic> json) {
    final state = SeatState.parse(json['state'] as String?);
    return LoopSeat(
      userId: json['id'] as String? ?? '',
      name: (json['name'] as String?)?.trim().isNotEmpty ?? false
          ? (json['name'] as String).trim()
          : 'Somebody',
      state: state,
      layerId: state == SeatState.played ? json['layer_id'] as String? : null,
    );
  }
}

/// One round on one song.
@immutable
class LoopRound {
  const LoopRound({
    required this.id,
    required this.projectId,
    required this.startMs,
    required this.endMs,
    required this.startedAt,
    required this.seats,
    this.startedBy,
    this.startedByName,
    this.ended = false,
    this.upId,
  });

  final String id;
  final String projectId;

  /// The passage, in milliseconds of the song. Two times and no name: two
  /// phones cannot misread a number the way they can misread "Chorus 2".
  final int startMs;
  final int endMs;

  /// When it was started. Never shown. It is how the screen tells a draft
  /// recorded for this round from an older take on the same bars.
  final DateTime startedAt;

  /// Null when the account that started it is gone.
  final String? startedBy;
  final String? startedByName;

  /// Ended by whoever started it, or the room's owner. It can still be
  /// heard; nobody can join it or hand a turn in.
  final bool ended;

  /// Whose turn it is, as the database worked it out: the first person in
  /// the order still waiting who can still record in the room. Null when
  /// nobody is waiting.
  final String? upId;

  /// The order, first to last. Everybody waiting or played, and your own
  /// seat whatever it reads as.
  final List<LoopSeat> seats;

  int get lengthMs => endMs - startMs;

  LoopSeat? seatOf(String? userId) {
    if (userId == null) return null;
    for (final seat in seats) {
      if (seat.userId == userId) return seat;
    }
    return null;
  }

  bool isUp(String? userId) => !ended && userId != null && upId == userId;

  /// The turns the room can hear, in the order of the round.
  List<LoopSeat> get played => <LoopSeat>[
        for (final seat in seats)
          if (seat.state == SeatState.played && seat.layerId != null) seat,
      ];

  /// The takes that are turns of this round, for leaving them out of the
  /// ordinary mix: every one of them sits on the same bars.
  Set<String> get turnLayerIds =>
      <String>{for (final seat in played) seat.layerId!};

  /// The name of whoever is up, for the line on the card.
  String? get upName => seatOf(upId)?.name;

  factory LoopRound.fromRow(Map<String, dynamic> row, {required String projectId}) {
    return LoopRound(
      id: row['id'] as String,
      projectId: projectId,
      startMs: (row['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (row['end_ms'] as num?)?.toInt() ?? 0,
      startedAt: DateTime.tryParse('${row['started_at']}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      startedBy: row['started_by'] as String?,
      startedByName: row['started_by_name'] as String?,
      ended: row['ended'] as bool? ?? false,
      upId: row['up'] as String?,
      seats: <LoopSeat>[
        for (final seat in (row['seats'] as List<dynamic>? ?? const <dynamic>[]))
          LoopSeat.fromJson(Map<String, dynamic>.from(seat as Map)),
      ],
    );
  }
}
