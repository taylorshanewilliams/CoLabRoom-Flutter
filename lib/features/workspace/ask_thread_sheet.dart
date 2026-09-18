import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';
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
///
/// From the answering end it offers three doors -- what stayed with me, a
/// question, an opinion -- and from the asking end it offers one quiet
/// control, "I'm ready for opinions", until it has been tapped once (Every
/// Musician, Same Song, 17 September 2026). The asker's own lines go through
/// no door: they are answering people, not a song.
Future<void> showAskThread(
  BuildContext context, {
  required MusicRepository repository,
  required String askId,
  required String headline,
  required String askedBy,
  String note = '',
  bool opinionsOpened = false,
}) {
  return showThreadSheet(
    context,
    sheet: AskThreadSheet(
      repository: repository,
      askId: askId,
      headline: headline,
      askedBy: askedBy,
      note: note,
      opinionsOpened: opinionsOpened,
    ),
  );
}

class AskThreadSheet extends StatefulWidget {
  const AskThreadSheet({
    required this.repository,
    required this.askId,
    required this.headline,
    required this.askedBy,
    this.note = '',
    this.opinionsOpened = false,
    super.key,
  });

  final MusicRepository repository;
  final String askId;

  /// The ask, in one line, in whichever words the caller already had.
  final String headline;

  /// Who asked. Whether that is you decides which end of the sheet you get.
  final String askedBy;

  /// What the asker said about it, if anything.
  final String note;

  /// Whether the asker has already said they are ready to read opinions.
  /// Only matters when the asker is you.
  final bool opinionsOpened;

  @override
  State<AskThreadSheet> createState() => _AskThreadSheetState();
}

class _AskThreadSheetState extends State<AskThreadSheet> {
  late bool _opened = widget.opinionsOpened;
  bool _opening = false;

  /// Bumped after "I'm ready", so the sheet reads the thread again and the
  /// opinions that were held come in with everything else.
  final ValueNotifier<int> _reads = ValueNotifier<int>(0);

  bool get _mine => widget.askedBy == widget.repository.currentUserId;

  /// The three doors, in the plan's order, as the sheet draws them.
  static final List<ThreadDoor> _doors = <ThreadDoor>[
    for (final door in ReplyDoor.values)
      ThreadDoor(
        id: door.wireName,
        label: door.label,
        hint: door.hint,
        notice: door.notice,
      ),
  ];

  @override
  void dispose() {
    _reads.dispose();
    super.dispose();
  }

  ThreadLine _line(AskReply reply) => ThreadLine(
        id: reply.id,
        authorId: reply.authorId,
        authorName: reply.authorName,
        body: reply.body,
        createdAt: reply.createdAt,
        label: reply.door?.label,
        source: reply,
      );

  Future<void> _ready() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.repository.openOpinions(widget.askId);
      if (!mounted) return;
      setState(() => _opened = true);
      _reads.value++;
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error,
            service: 'app', stage: 'ask_thread_ready')),
      ));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    return ThreadSheet(
      keyPrefix: 'ask_thread',
      stage: 'ask_thread',
      headline: widget.headline,
      note: widget.note,
      currentUserId: repository.currentUserId,
      changes: _reads,
      emptyLine:
          'Nothing said yet. Say what you hear, or when you could do it.',
      // One quiet control, and nothing that says whether anything is
      // waiting behind it. It goes once it has been tapped, and stays gone.
      belowHeader: _mine && !_opened
          ? TextButton(
              key: const Key('ask_thread_ready'),
              onPressed: _opening ? null : () => unawaited(_ready()),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.muted,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text(
                "I'm ready for opinions",
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
            )
          : null,
      doors: _mine ? null : _doors,
      load: () async => <ThreadLine>[
        for (final reply in await repository.loadAskReplies(widget.askId))
          _line(reply),
      ],
      send: (body) async =>
          _line(await repository.replyToAsk(askId: widget.askId, body: body)),
      sendThrough: (door, body) async => _line(await repository.replyToAsk(
        askId: widget.askId,
        body: body,
        door: ReplyDoor.fromWireName(door.id),
      )),
      takeBack: (line) => repository.deleteAskReply(line.source! as AskReply),
    );
  }
}
