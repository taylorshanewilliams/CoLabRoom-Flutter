import 'package:flutter/material.dart';

import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../widgets/thread_sheet.dart';

/// The thread between you and one person.
///
/// Opened from their row on the People screen, from their profile, and from
/// a message of theirs in the inbox. Whoever can be written to is decided on
/// the server by the same rule as telling somebody about a song: connected,
/// or in a room together, and no block either way.
Future<void> showPersonThread(
  BuildContext context, {
  required MusicRepository repository,
  Listenable? changes,
  required String personId,
  required String personName,
}) {
  return showThreadSheet(
    context,
    sheet: PersonThreadSheet(
      repository: repository,
      changes: changes,
      personId: personId,
      personName: personName,
    ),
  );
}

class PersonThreadSheet extends StatelessWidget {
  const PersonThreadSheet({
    required this.repository,
    this.changes,
    required this.personId,
    required this.personName,
    super.key,
  });

  final MusicRepository repository;

  /// Fires when the world changes; the sheet re-reads. See ThreadSheet.
  final Listenable? changes;
  final String personId;
  final String personName;

  ThreadLine _line(DirectMessage message) => ThreadLine(
        id: message.id,
        authorId: message.authorId,
        authorName: message.authorName,
        body: message.body,
        createdAt: message.createdAt,
        source: message,
      );

  @override
  Widget build(BuildContext context) {
    return ThreadSheet(
      keyPrefix: 'person_thread',
      stage: 'person_thread',
      headline: personName,
      currentUserId: repository.currentUserId,
      changes: changes,
      emptyLine: 'Nothing said yet. Whatever you say here stays between the '
          'two of you.',
      load: () async => <ThreadLine>[
        for (final message in await repository.loadMessagesWith(personId))
          _line(message),
      ],
      send: (body) async =>
          _line(await repository.sendMessageTo(personId: personId, body: body)),
      takeBack: (line) => repository.deleteMessage(line.source! as DirectMessage),
    );
  }
}
