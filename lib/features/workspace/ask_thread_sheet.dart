import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';

/// The thread on one ask: what people have said back, and a place to say
/// something.
///
/// Until this existed an ask had two answers, a take and silence. Everything
/// a band would actually say about a request -- "I hear pedal steel on the
/// chorus", "Thursday, if that's soon enough", "what key is it in?" -- had
/// nowhere to go. This is where it goes. Deliberately small: a list and one
/// box, no reactions, no threads inside threads. It is the same sheet from
/// both ends, opened from the chip on the song by whoever can see it and
/// from the inbox card by the one person it was sent to.
Future<void> showAskThread(
  BuildContext context, {
  required MusicRepository repository,
  required String askId,
  required String headline,
  String note = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => AskThreadSheet(
      repository: repository,
      askId: askId,
      headline: headline,
      note: note,
    ),
  );
}

class AskThreadSheet extends StatefulWidget {
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

  @override
  State<AskThreadSheet> createState() => _AskThreadSheetState();
}

class _AskThreadSheetState extends State<AskThreadSheet> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<AskReply>? _replies;
  String? _problem;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final replies = await widget.repository.loadAskReplies(widget.askId);
      if (!mounted) return;
      setState(() {
        _replies = replies;
        _problem = null;
      });
      _scrollToNewest();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _replies = const <AskReply>[];
        _problem =
            reportAndDescribe(error, service: 'app', stage: 'ask_thread');
      });
    }
  }

  void _scrollToNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final reply = await widget.repository
          .replyToAsk(askId: widget.askId, body: body);
      if (!mounted) return;
      setState(() {
        _replies = <AskReply>[...?_replies, reply];
        _composer.clear();
      });
      _scrollToNewest();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            reportAndDescribe(error, service: 'app', stage: 'ask_reply')),
      ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _takeBack(AskReply reply) async {
    try {
      await widget.repository.deleteAskReply(reply);
      if (!mounted) return;
      setState(() {
        _replies = <AskReply>[
          for (final existing in _replies ?? const <AskReply>[])
            if (existing.id != reply.id) existing,
        ];
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error,
            service: 'app', stage: 'ask_reply_delete')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final replies = _replies;
    final me = widget.repository.currentUserId;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.headline,
                    key: const Key('ask_thread_headline'),
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                  if (widget.note.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      '“${widget.note.trim()}”',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 13.5,
                        height: 1.4,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.line),
            Expanded(
              child: replies == null
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : replies.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              _problem ??
                                  'Nothing said yet. Say what you hear, or '
                                      'when you could do it.',
                              key: const Key('ask_thread_empty'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.muted, height: 1.4),
                            ),
                          ),
                        )
                      : ListView.separated(
                          key: const Key('ask_thread_list'),
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                          itemCount: replies.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 14),
                          itemBuilder: (_, index) => _ReplyRow(
                            reply: replies[index],
                            mine: replies[index].authorId == me,
                            onTakeBack: () =>
                                unawaited(_takeBack(replies[index])),
                          ),
                        ),
            ),
            const Divider(height: 1, color: AppColors.line),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const Key('ask_thread_composer'),
                        controller: _composer,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(
                            color: AppColors.text, fontSize: 14.5),
                        decoration: const InputDecoration(
                          hintText: 'Say something back…',
                          counterText: '',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => unawaited(_send()),
                      ),
                    ),
                    IconButton(
                      key: const Key('ask_thread_send'),
                      tooltip: 'Send',
                      onPressed: _sending ? null : () => unawaited(_send()),
                      color: AppColors.cyan,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyRow extends StatelessWidget {
  const _ReplyRow({
    required this.reply,
    required this.mine,
    required this.onTakeBack,
  });

  final AskReply reply;
  final bool mine;
  final VoidCallback onTakeBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${mine ? 'You' : reply.authorName} · ${_when(reply.createdAt)}',
                style: TextStyle(
                  color: mine ? AppColors.cyan : AppColors.gold,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            // Your own words, takeable back. Labelled, because a swipe or a
            // long press on a line of text is a thing nobody finds.
            if (mine)
              TextButton(
                key: Key('ask_thread_take_back_${reply.id}'),
                onPressed: onTakeBack,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Take back', style: TextStyle(fontSize: 11.5)),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          reply.body,
          style: const TextStyle(
              color: AppColors.text, fontSize: 14.5, height: 1.4),
        ),
      ],
    );
  }

  static String _when(DateTime time) {
    final gap = DateTime.now().difference(time);
    if (gap.inMinutes < 1) return 'just now';
    if (gap.inHours < 1) return '${gap.inMinutes} min ago';
    if (gap.inDays < 1) return '${gap.inHours} h ago';
    if (gap.inDays < 7) return '${gap.inDays} d ago';
    return '${time.day}/${time.month}';
  }
}
