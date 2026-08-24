import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/cowork_service.dart';

/// The song's stream: what people said and what the app did, in one place.
///
/// Both in one list on purpose. A chat panel that only carries typed messages
/// starts empty and stays empty — nobody opens a blank box to talk to nobody.
/// This one is filled by the app before anyone says a word, so there is
/// always something here, and saying something into it is the obvious next
/// move rather than a leap of faith.
class CoworkPanel extends StatefulWidget {
  const CoworkPanel({
    required this.projectId,
    required this.service,
    super.key,
  });

  final String projectId;
  final CoworkService service;

  @override
  State<CoworkPanel> createState() => _CoworkPanelState();
}

class _CoworkPanelState extends State<CoworkPanel> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<List<ProjectEvent>>? _eventsSub;
  StreamSubscription<List<CoworkPresence>>? _presenceSub;

  List<ProjectEvent> _events = const <ProjectEvent>[];
  List<CoworkPresence> _here = const <CoworkPresence>[];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _eventsSub = widget.service.events.listen((events) {
      if (!mounted) return;
      setState(() => _events = events);
      _scrollToNewest();
    });
    _presenceSub = widget.service.presence.listen((here) {
      if (mounted) setState(() => _here = here);
    });
  }

  @override
  void dispose() {
    unawaited(_eventsSub?.cancel());
    unawaited(_presenceSub?.cancel());
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToNewest() {
    // After the frame that renders the new entry, or there is nothing to
    // scroll to yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    // Cleared first so the box is ready for the next thought rather than
    // holding text hostage until the network agrees.
    _composer.clear();
    setState(() => _sending = true);
    try {
      await widget.service.send(widget.projectId, text);
    } catch (error) {
      if (mounted) {
        _composer.text = text;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not send that: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _HereNow(here: _here),
        Expanded(
          child: _events.isEmpty
              ? const _Quiet()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  itemCount: _events.length,
                  itemBuilder: (context, index) => _EventLine(event: _events[index]),
                ),
        ),
        _Composer(controller: _composer, sending: _sending, onSend: _send),
      ],
    );
  }
}

/// Who has this song open right now.
///
/// The reason the panel works: you type because you can see somebody is
/// there. Hidden entirely when you're alone rather than showing "1 person
/// here", which is a lonelier thing to read than nothing.
class _HereNow extends StatelessWidget {
  const _HereNow({required this.here});

  final List<CoworkPresence> here;

  @override
  Widget build(BuildContext context) {
    if (here.length < 2) return const SizedBox.shrink();
    final others = here.skip(1).map((person) => person.displayName).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: AppColors.green.withValues(alpha: 0.10),
      child: Row(
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              here.length == 2
                  ? '${others.first} is here too'
                  : '${here.length} of you are in this song',
              style: const TextStyle(
                color: AppColors.green,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Quiet extends StatelessWidget {
  const _Quiet();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 28),
      child: Center(
        child: Text(
          'Everything that happens to this song shows up here — recordings, '
          'analyses, edits — and you can talk about it in the same place.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.5),
        ),
      ),
    );
  }
}

class _EventLine extends StatelessWidget {
  const _EventLine({required this.event});

  final ProjectEvent event;

  String get _time {
    final at = event.createdAt;
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return '$hour:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    // The app's own lines sit quieter than people's. They're context, not
    // conversation, and typography is what says so without a label.
    if (!event.isMessage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 8),
              child: Icon(Icons.auto_awesome_rounded, size: 12, color: AppColors.muted),
            ),
            Expanded(
              child: Text(
                event.systemText,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                ),
              ),
            ),
            Text(
              _time,
              style: const TextStyle(color: AppColors.muted, fontSize: 10),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                event.actorName ?? 'Someone',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 7),
              Text(_time, style: const TextStyle(color: AppColors.muted, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            event.body,
            style: const TextStyle(color: AppColors.text, fontSize: 13.5, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(onSend()),
              decoration: const InputDecoration(
                hintText: 'Say something about this song',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: sending ? null : () => unawaited(onSend()),
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded, color: AppColors.gold),
          ),
        ],
      ),
    );
  }
}
