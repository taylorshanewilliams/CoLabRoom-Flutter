import 'music_models.dart';

/// Somebody who is yours: a connection, a band-mate, or both.
class KnownPerson {
  const KnownPerson({
    required this.id,
    required this.name,
    required this.line,
    required this.canMessage,
    this.avatarPath,
    this.connected = false,
    this.roomNames = const <String>[],
  });

  final String id;
  final String name;
  final String? avatarPath;

  /// What to say under the name: what they play, where they are, or which
  /// room you share.
  final String line;

  /// Whether a message to them would go (0102's may_tell: connected, or in
  /// a room together).
  final bool canMessage;

  /// An accepted connection.
  final bool connected;

  /// The rooms you are both in, by name. Empty for a connection you have
  /// never shared a room with.
  final List<String> roomNames;

  bool get roomMate => roomNames.isNotEmpty;
}

/// Everybody who is yours, in one list, from what the app already holds.
///
/// Taylor, 15 Sep: his three band-mates showed under "asked, no answer yet"
/// and nowhere else. He had sent each a connection request months ago;
/// none had answered; and the People screen took an unanswered request to
/// mean *not your people* -- while the same three were in his room, on
/// his songs, and one thread away. A band-mate is one of your people
/// whether or not they pressed a button, and the app already lets you
/// write to them (0102).
///
/// So: accepted connections first, then everybody who shares a room with
/// you, then anybody the server suggests on top (somebody who played on a
/// song of yours through an ask). Nobody twice. A pending request to a
/// band-mate is not worth a row of its own; they are already here.
List<KnownPerson> yourPeople({
  required String me,
  required List<MusicRoom> rooms,
  required List<Connection> connections,
  List<SuggestedPerson> suggested = const <SuggestedPerson>[],
}) {
  final roomsWith = <String, List<String>>{};
  final members = <String, RoomMember>{};
  for (final room in rooms) {
    for (final member in room.members) {
      if (member.userId == me) continue;
      roomsWith.putIfAbsent(member.userId, () => <String>[]).add(room.name);
      members.putIfAbsent(member.userId, () => member);
    }
  }

  final seen = <String>{};
  final people = <KnownPerson>[];

  for (final c in connections) {
    if (!c.accepted || !seen.add(c.personId)) continue;
    people.add(KnownPerson(
      id: c.personId,
      name: c.displayName,
      avatarPath: c.avatarPath,
      line: c.availabilityLine ?? c.plays.join(' · '),
      canMessage: true,
      connected: true,
      roomNames: roomsWith[c.personId] ?? const <String>[],
    ));
  }

  final mates = members.keys.where(seen.add).toList()
    ..sort((a, b) => members[a]!.displayName.toLowerCase()
        .compareTo(members[b]!.displayName.toLowerCase()));
  for (final id in mates) {
    final member = members[id]!;
    final names = roomsWith[id]!;
    people.add(KnownPerson(
      id: id,
      name: member.displayName,
      avatarPath: member.avatarPath,
      line: 'In ${names.join(', ')} with you',
      canMessage: true,
      roomNames: names,
    ));
  }

  for (final s in suggested) {
    if (!seen.add(s.personId)) continue;
    people.add(KnownPerson(
      id: s.personId,
      name: s.displayName,
      avatarPath: s.avatarPath,
      line: s.because,
      canMessage: s.canMessage,
    ));
  }

  return people;
}
