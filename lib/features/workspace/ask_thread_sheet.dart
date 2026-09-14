import 'package:flutter/material.dart';

import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../widgets/thread_sheet.dart';

/// The thread on one ask: what people have said back, and a place to say
/// something.
///
/// Until this existed an ask had two answers, a take and silence. Everything
/// a band would actually say about a request -- "I hear pedal steel on the
/// chorus", "Thursday, if that's soon enough", "what key is it in?" -- had
/// nowhere to go. This is where it goes. It is the same sheet from both ends,
/// opened from the chip on the song by whoever can see it and from the inbox
/// card by the one person it was sent to.
Future<void> showAskThread(
  BuildContext context, {
  required MusicRepository repository,
  required String askId,
  required String headline,
  String note = '',
}) {
  return showThreadSheet(
    context,
    sheet: AskThreadSheet(
      repository: repository,
      askId: askId,
      headline: headline,
      note: note,
    ),
  );
}

class AskThreadSheet extends StatelessWidget {
  const AskThreadSheet({
    required this.repository,
    required this.askId,
    required this.headline,
    this.note = '',
    super.key,
  });

  final MusicRepository repository;
  final String askId;

  /// The ask, in one line, in whichever words the caller already had.
  final String headline;

  /// What the asker said about it, if anything.
  final String note;

  ThreadLine _line(AskReply reply) => ThreadLine(
        id: reply.id,
        authorId: reply.authorId,
        authorName: reply.authorName,
        body: reply.body,
        createdAt: reply.createdAt,
        source: reply,
      );

  @override
  Widget build(BuildContext context) {
    return ThreadSheet(
      keyPrefix: 'ask_thread',
      stage: 'ask_thread',
      headline: headline,
      note: note,
      currentUserId: repository.currentUserId,
      emptyLine:
          'Nothing said yet. Say what you hear, or when you could do it.',
      load: () async => <ThreadLine>[
        for (final reply in await repository.loadAskReplies(askId))
          _line(reply),
      ],
      send: (body) async =>
          _line(await repository.replyToAsk(askId: askId, body: body)),
      takeBack: (line) => repository.deleteAskReply(line.source! as AskReply),
    );
  }
}
