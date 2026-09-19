import '../app/routes.dart';
import 'incoming_addresses.dart';

/// A link to one moment of one recording, for the people in the room.
///
/// Every Musician, Same Song, 17 September 2026 (schools, item 1): "listen
/// to bar 33" is the sentence a teacher says most, and until now there was
/// no way to say it in writing. A student pastes this into Canvas, a
/// bandmate texts it, and it opens the song at that moment of that take.
///
/// The host is the one the phone claims (see IncomingAddresses and the App
/// Links in the manifest), so the same link opens the app on a phone that
/// has it and the web app everywhere else. The path is [AppRoutes.moment],
/// which is also what the parser reads back: an address written in one place
/// and read in another is how the two halves drift apart.
///
/// It carries no title and no name. Somebody who cannot open it learns only
/// that they cannot open it — there is no public page for anything inside a
/// room (the 0096 stance).
String momentLink({
  required String roomId,
  required String projectId,
  String? takeId,
  required int atMs,
}) {
  final path = AppRoutes.moment(
    roomId: roomId,
    projectId: projectId,
    takeId: takeId,
    atMs: atMs,
  );
  return 'https://${IncomingAddresses.host}$path';
}
