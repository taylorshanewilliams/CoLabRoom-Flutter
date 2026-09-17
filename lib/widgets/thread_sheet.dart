import 'dart:async';

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../services/user_facing_error.dart';
import 'send_on_enter.dart';

/// One line in a conversation, whoever said it and wherever it is kept.
class ThreadLine {
  const ThreadLine({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
    this.source,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;

  /// The stored object this line came from, handed back to
  /// [ThreadSheet.takeBack] so the caller need not look it up again.
  final Object? source;
}

/// Opens a thread as a sheet over whatever is on screen.
Future<void> showThreadSheet(BuildContext context, {required Widget sheet}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => sheet,
  );
}

/// A conversation: what has been said, in order, and a box to say something.
///
/// Deliberately small -- a list and one box, no reactions, no threads inside
/// threads. The same sheet serves the thread on an ask and the one between
/// two people; what differs is where the lines live, and the three callbacks
/// decide that. Until this existed nobody in the app had typed a sentence to
/// anybody: a request could be answered with a take or with silence, and a
/// person you had connected with could be found, told and asked, but not
/// answered.
class ThreadSheet extends StatefulWidget {
  const ThreadSheet({
    required this.headline,
    required this.currentUserId,
    required this.load,
    required this.send,
    required this.takeBack,
    this.note = '',
    this.emptyLine = 'Nothing said yet.',
    this.keyPrefix = 'thread',
    this.stage = 'thread',
    this.changes,
    this.header,
    super.key,
  });

  /// What the conversation is about, in one line.
  final String headline;

  /// A second line under it, in the words the other side already used.
  final String note;

  /// Whose lines are "You" and can be taken back.
  final String currentUserId;

  final Future<List<ThreadLine>> Function() load;
  final Future<ThreadLine> Function(String body) send;
  final Future<void> Function(ThreadLine line) takeBack;

  /// What to say when nobody has said anything.
  final String emptyLine;

  /// Prefix for the widget keys tests and callers find things by.
  final String keyPrefix;

  /// Where a failure is filed, so the report says which thread this was.
  final String stage;

  /// Something that fires when the world changes -- the controller, which
  /// reloads on every notification that arrives, and a message from
  /// anybody writes one. While this sheet is open, each such change
  /// re-reads the thread, so a conversation is one without closing and
  /// reopening it to see the answer. Null means the sheet reads once.
  final Listenable? changes;

  /// Something richer than a headline at the top -- a room's picture,
  /// name, people and actions. When given, drawn instead of [headline]
  /// and [note]; the headline still names the sheet for accessibility.
  final Widget? header;

  @override
  State<ThreadSheet> createState() => _ThreadSheetState();
}

class _ThreadSheetState extends State<ThreadSheet> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<ThreadLine>? _lines;
  String? _problem;
  bool _sending = false;
  Timer? _rereadDebounce;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_changed);
    unawaited(_load());
  }

  /// The world moved; read the thread again, a beat later. A reload
  /// keeps what is on screen until the new lines arrive, so nothing
  /// flickers, and it waits for a send in flight rather than racing it.
  void _changed() {
    _rereadDebounce?.cancel();
    _rereadDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _sending) return;
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_changed);
    _rereadDebounce?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Key _key(String part) => Key('${widget.keyPrefix}_$part');

  Future<void> _load() async {
    try {
      final lines = await widget.load();
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _problem = null;
      });
      _scrollToNewest();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lines = const <ThreadLine>[];
        _problem = reportAndDescribe(error, service: 'app', stage: widget.stage);
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
      final line = await widget.send(body);
      if (!mounted) return;
      setState(() {
        _lines = <ThreadLine>[...?_lines, line];
        _composer.clear();
      });
      _scrollToNewest();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error,
            service: 'app', stage: '${widget.stage}_send')),
      ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _takeBack(ThreadLine line) async {
    try {
      await widget.takeBack(line);
      if (!mounted) return;
      setState(() {
        _lines = <ThreadLine>[
          for (final existing in _lines ?? const <ThreadLine>[])
            if (existing.id != line.id) existing,
        ];
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error,
            service: 'app', stage: '${widget.stage}_delete')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
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
              child: widget.header ?? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.headline,
                    key: _key('headline'),
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
              child: lines == null
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : lines.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              _problem ?? widget.emptyLine,
                              key: _key('empty'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.muted, height: 1.4),
                            ),
                          ),
                        )
                      : ListView.separated(
                          key: _key('list'),
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                          itemCount: lines.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 14),
                          itemBuilder: (_, index) => _LineRow(
                            line: lines[index],
                            mine: lines[index].authorId ==
                                widget.currentUserId,
                            takeBackKey: _key('take_back_${lines[index].id}'),
                            onTakeBack: () =>
                                unawaited(_takeBack(lines[index])),
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
                      child: SendOnEnter(
                        onSend: () => unawaited(_send()),
                        child: TextField(
                        key: _key('composer'),
                        controller: _composer,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(
                            color: AppColors.text, fontSize: 14.5),
                        decoration: const InputDecoration(
                          hintText: 'Say something…',
                          counterText: '',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => unawaited(_send()),
                      ),
                      ),
                    ),
                    IconButton(
                      key: _key('send'),
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

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.mine,
    required this.takeBackKey,
    required this.onTakeBack,
  });

  final ThreadLine line;
  final bool mine;
  final Key takeBackKey;
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
                '${mine ? 'You' : line.authorName} · ${_when(line.createdAt)}',
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
                key: takeBackKey,
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
          line.body,
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
