import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/invite_link.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/qr_code.dart';
import 'add_person_screen.dart';

/// Your code, for meeting people in person.
///
/// Taylor, 16 September 2026: "could each user have one in their profile?
/// say you meet someone at a concert, or open mic night, or anywhere, you
/// could just scan each other's codes and become friends in the app."
///
/// Held up in a loud room, so it does one thing at a time: the code, big;
/// then, while it is up, whoever has just scanned it, with the one button
/// that finishes the job. Nobody standing next to you should have to wait for
/// a notification to find out it worked, so the screen asks every few
/// seconds while it is open, and stops when it is not.
///
/// Below that, the typed way in, for a camera that will not focus in the
/// dark.
class YourCodeScreen extends StatefulWidget {
  const YourCodeScreen({
    required this.repository,
    this.lookEvery = const Duration(seconds: 3),
    super.key,
  });

  final MusicRepository repository;

  /// How often the screen looks for somebody who has just scanned it.
  final Duration lookEvery;

  @override
  State<YourCodeScreen> createState() => _YourCodeScreenState();
}

class _YourCodeScreenState extends State<YourCodeScreen> {
  final TextEditingController _typed = TextEditingController();
  String? _code;
  String? _typedProblem;
  bool _loading = true;

  /// Asked you and not answered yet, newest first.
  List<Connection> _waiting = const <Connection>[];

  /// Who you were connected to when the screen opened, so the ones that
  /// join while it is up can be said out loud.
  Set<String>? _connectedAtOpen;
  List<Connection> _connectedHere = const <Connection>[];

  final Set<String> _answering = <String>{};
  Timer? _look;
  bool _looking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _look = Timer.periodic(widget.lookEvery, (_) => unawaited(_lookForPeople()));
  }

  @override
  void dispose() {
    _look?.cancel();
    _typed.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final code = await widget.repository.myMeetingCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _say(reportAndDescribe(error, service: 'app', stage: 'meeting.code', route: 'Your code'));
    }
    await _lookForPeople();
  }

  /// Quietly: a missed look is caught by the next one, and a snackbar every
  /// three seconds in a basement with no signal would be the whole screen.
  Future<void> _lookForPeople() async {
    if (_looking) return;
    _looking = true;
    try {
      final all = await widget.repository.listConnections();
      if (!mounted) return;
      final accepted = all.where((c) => c.accepted).toList();
      final before = _connectedAtOpen ??= accepted.map((c) => c.personId).toSet();
      final waiting = all.where((c) => !c.accepted && c.incoming).toList()
        ..sort((a, b) => (b.since ?? DateTime(0)).compareTo(a.since ?? DateTime(0)));
      setState(() {
        _waiting = waiting;
        _connectedHere = accepted.where((c) => !before.contains(c.personId)).toList();
      });
    } catch (_) {
      // The next look will do.
    } finally {
      _looking = false;
    }
  }

  Future<void> _answer(Connection person, {required bool accept}) async {
    if (!_answering.add(person.personId)) return;
    setState(() {});
    try {
      await widget.repository.respondToConnection(person.personId, accept: accept);
      await _lookForPeople();
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'meeting.answer', route: 'Your code'));
    } finally {
      _answering.remove(person.personId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _changeCode() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Make a new code?'),
        content: const Text(
          'Your old code stops opening your card, wherever it is. '
          'Everybody you have already added stays added.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep it')),
          FilledButton(
            key: const Key('meet_change_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('New code'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      final code = await widget.repository.changeMyMeetingCode();
      if (!mounted) return;
      setState(() => _code = code);
      _say('New code. The old one opens nobody now.');
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'meeting.change', route: 'Your code'));
    }
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: meetingLink(code)));
    _say('Link copied. Anybody who opens it can ask to add you.');
  }

  void _openTyped() {
    final code = meetingCodeFromText(_typed.text);
    if (code == null) {
      setState(() => _typedProblem = 'Codes look like k7m2-9xqp.');
      return;
    }
    setState(() => _typedProblem = null);
    FocusScope.of(context).unfocus();
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.meet(code)),
      builder: (_) => AddPersonScreen(code: code, repository: widget.repository),
    )));
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Your code'),
        actions: <Widget>[
          if (code != null)
            PopupMenuButton<String>(
              key: const Key('meet_menu'),
              onSelected: (value) {
                if (value == 'change') unawaited(_changeCode());
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  key: Key('meet_change'),
                  value: 'change',
                  child: Text('Make a new code'),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: const Key('meet_list'),
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 32),
                children: <Widget>[
                  const Text(
                    'Scan each other\'s codes',
                    style: TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Show this to somebody you have just met. Their phone camera '
                    'opens your card and they ask to add you. Scan theirs back and '
                    'you are connected.',
                    style: TextStyle(color: AppColors.muted, fontSize: 14, height: 1.45),
                  ),
                  const SizedBox(height: 20),
                  if (code != null) ..._codeBlock(code),
                  ..._people(),
                  const SizedBox(height: 26),
                  ..._typedWayIn(),
                ],
              ),
      ),
    );
  }

  List<Widget> _codeBlock(String code) => <Widget>[
        Center(
          child: QrCode(
            key: const Key('meet_qr'),
            data: meetingLink(code),
            size: 240,
            label: 'QR code that opens your card',
          ),
        ),
        const SizedBox(height: 14),
        SelectableText(
          meetingCodeSaid(code),
          key: const Key('meet_code'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.gold, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 3),
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton.icon(
            key: const Key('meet_copy'),
            onPressed: () => unawaited(_copy(code)),
            icon: const Icon(Icons.link_rounded, size: 18),
            label: const Text('Copy my link'),
          ),
        ),
      ];

  List<Widget> _people() => <Widget>[
        for (final person in _connectedHere) ...<Widget>[
          const SizedBox(height: 10),
          _Row(
            key: Key('meet_connected_${person.personId}'),
            person: person,
            icon: const Icon(Icons.check_circle_rounded, color: AppColors.gold),
            line: 'You are connected.',
          ),
        ],
        for (final person in _waiting) ...<Widget>[
          const SizedBox(height: 10),
          _Row(
            key: Key('meet_waiting_${person.personId}'),
            person: person,
            line: 'Wants to add you.',
            actions: <Widget>[
                TextButton(
                  key: Key('meet_not_now_${person.personId}'),
                  onPressed: _answering.contains(person.personId)
                      ? null
                      : () => unawaited(_answer(person, accept: false)),
                  child: const Text('Not now', style: TextStyle(color: AppColors.muted)),
                ),
                FilledButton(
                  key: Key('meet_add_back_${person.personId}'),
                  onPressed: _answering.contains(person.personId)
                      ? null
                      : () => unawaited(_answer(person, accept: true)),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: AppColors.ink),
                  child: const Text('Add back'),
                ),
              ],
          ),
        ],
      ];

  List<Widget> _typedWayIn() => <Widget>[
        const Text(
          'Camera will not scan? Type their code.',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('meet_typed'),
                controller: _typed,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(color: AppColors.text, fontSize: 16, letterSpacing: 1.5),
                decoration: InputDecoration(
                  hintText: 'k7m2-9xqp',
                  errorText: _typedProblem,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _openTyped(),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              key: const Key('meet_open'),
              onPressed: _openTyped,
              child: const Text('Open'),
            ),
          ],
        ),
      ];
}

/// One person who has just scanned your code.
///
/// The buttons sit under the name rather than beside it: a long name at a
/// large text size on a small phone has nowhere else to go.
class _Row extends StatelessWidget {
  const _Row({required this.person, required this.line, this.icon, this.actions = const <Widget>[], super.key});

  final Connection person;
  final String line;
  final Widget? icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final plays = person.plays.isEmpty ? '' : ' · ${person.plays.join(', ')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.raised,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      person.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text, fontSize: 15.5, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '$line$plays',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              if (icon case final shown?) ...<Widget>[const SizedBox(width: 8), shown],
            ],
          ),
          if (actions.isNotEmpty)
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: actions,
            ),
        ],
      ),
    );
  }
}
