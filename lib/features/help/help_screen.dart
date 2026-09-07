import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/user_facing_error.dart';
import 'help_answers.dart';

/// Somewhere to ask.
///
/// The only way to say anything to whoever runs this app was a box labelled
/// "Tell us what happened", which is for reporting a fault. Somebody who
/// simply does not know how to do something had nowhere to go.
///
/// **It answers from a written list, not from a model.** Asked for a refund
/// policy, a model produces a confident, plausible, wrong answer — and this
/// app has nothing to refund, which is exactly the sort of fact no general
/// system knows. Every answer here was checked against what the app does.
///
/// **And it says when it does not know.** That is the harder half. A help
/// system that always produces something produces the wrong thing most of the
/// time, and a confidently wrong answer costs more than a shrug and a route
/// to a person.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final TextEditingController _asked = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// What has been said, oldest first. Kept rather than replaced, so somebody
  /// can ask three things and still see the first answer.
  final List<_Said> _said = <_Said>[];

  bool _sending = false;

  /// What has been asked before, and what came back. Loaded once: somebody
  /// who asked something last week opens this screen to find out whether
  /// anybody answered, and there was nowhere for that to be shown.
  ///
  /// Not `_asked`, which is the field they are typing into.
  List<HelpRequest> _history = const <HelpRequest>[];

  /// The route they were on when they opened this, captured once.
  ///
  /// Read at construction rather than at send time, because by then the
  /// current route is this screen — which tells whoever reads the queue
  /// nothing at all.
  late final String? _cameFrom = CurrentRoute.name;

  @override
  void initState() {
    super.initState();
    CurrentRoute.enter('Help');
    unawaited(_loadAsked());
  }

  Future<void> _loadAsked() async {
    try {
      final asked =
          await BetaScope.of(context, listen: false).repository.myHelpRequests();
      if (mounted) setState(() => _history = asked);
    } catch (_) {
      // A history that will not load is not a reason to stop somebody
      // asking something new.
    }
  }

  @override
  void dispose() {
    _asked.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      unawaited(_scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      ));
    });
  }

  void _ask([String? preset]) {
    final question = (preset ?? _asked.text).trim();
    if (question.isEmpty) return;
    final answer = bestHelpAnswer(question);
    setState(() {
      _said.add(_Said.asked(question));
      _said.add(answer == null ? _Said.stumped() : _Said.answered(answer));
      _asked.clear();
    });
    _toBottom();
  }

  /// Sends the question on, and says so plainly.
  ///
  /// Recorded whether or not an answer was offered: a question that matched
  /// something and was sent anyway means the answer is wrong, and nothing
  /// else in the app can see that happening.
  Future<void> _sendToSupport() async {
    final question = _lastQuestion;
    if (question == null || _sending) return;
    setState(() => _sending = true);
    try {
      await BetaScope.of(context, listen: false).repository.askForHelp(
            question: question,
            matchedAnswer: _lastMatchId,
            route: _cameFrom,
          );
      if (!mounted) return;
      setState(() {
        _said.add(_Said.sent());
        _sending = false;
      });
      _toBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(reportAndDescribe(
            error,
            service: 'app',
            stage: 'ask_for_help',
            route: 'Help',
          )),
        ));
    }
  }

  /// The mail app, with the question already in it.
  ///
  /// Offered alongside rather than instead. Sending it in the app records it
  /// where it can be counted; email is the one somebody can reply to, and a
  /// person who wants a reply should not have to trust that a button did
  /// something.
  Future<void> _email() async {
    final question = _lastQuestion ?? '';
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@colabroom.com',
      queryParameters: <String, String>{
        'subject': 'CoLabRoom help',
        'body': '$question\n\n---\nAsked from: ${_cameFrom ?? 'the app'}',
      },
    );
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('No mail app to open. Write to support@colabroom.com.'),
        ));
    }
  }

  String? get _lastQuestion {
    for (final said in _said.reversed) {
      if (said.kind == _Kind.asked) return said.text;
    }
    return null;
  }

  String? get _lastMatchId {
    for (final said in _said.reversed) {
      if (said.kind == _Kind.answered) return said.answerId;
      if (said.kind == _Kind.asked) return null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: const Text('Help'),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                children: <Widget>[
                  if (_said.isEmpty) ...<Widget>[
                    const Text(
                      'Ask anything about the app. If it is something we have '
                      'written down you get the answer straight away, and if '
                      'it is not, you can send the question on.',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 13, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'COMMON QUESTIONS',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Browsable, not only searchable. Somebody who does not
                    // know what the app can do does not know what to type.
                    for (final answer in helpAnswers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: _Suggestion(
                          label: answer.question,
                          onTap: () => _ask(answer.question),
                        ),
                      ),

                    // What you asked before. Below the common questions,
                    // because most people are here with a new one — and
                    // present at all because sending a question into a table
                    // and never mentioning it again is not asking anybody.
                    if (_history.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 22),
                      const Text(
                        'WHAT YOU ASKED',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 10),
                      for (final asked in _history)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _Asked(request: asked),
                        ),
                    ],
                  ],
                  for (final said in _said)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _Bubble(said: said),
                    ),
                  if (_said.isNotEmpty &&
                      _said.last.kind != _Kind.sent) ...<Widget>[
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('help_send_to_support'),
                            onPressed:
                                _sending ? null : () => unawaited(_sendToSupport()),
                            icon: const Icon(Icons.forum_outlined, size: 17),
                            label: Text(_sending
                                ? 'Sending…'
                                : 'Send this to a person'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.cyan,
                              side: const BorderSide(color: AppColors.line),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Email support@colabroom.com',
                          onPressed: () => unawaited(_email()),
                          icon: const Icon(Icons.mail_outline_rounded,
                              size: 20, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('help_question_field'),
                      controller: _asked,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _ask(),
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'How do I…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('help_ask_button'),
                    onPressed: _ask,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(52, 46),
                      backgroundColor: AppColors.cyan,
                      foregroundColor: AppColors.ink,
                    ),
                    child: const Icon(Icons.arrow_upward_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Kind { asked, answered, stumped, sent }

class _Said {
  const _Said(this.kind, this.text, {this.title, this.answerId});

  factory _Said.asked(String question) => _Said(_Kind.asked, question);

  factory _Said.answered(HelpAnswer answer) => _Said(
        _Kind.answered,
        answer.answer,
        title: answer.question,
        answerId: answer.id,
      );

  /// Said plainly, and immediately followed by somewhere to go.
  ///
  /// "I could not find that" is a better thing to read than a confident
  /// answer to a question nobody asked.
  factory _Said.stumped() => const _Said(
        _Kind.stumped,
        'We have not written an answer for that one. Send it on and a '
        'person will read it — questions that end up here are how the list '
        'above gets longer.',
      );

  factory _Said.sent() => const _Said(
        _Kind.sent,
        'Sent. Somebody reads these, and if it needs a reply it goes to the '
        'email on your account. You can also write to support@colabroom.com '
        'directly.',
      );

  final _Kind kind;
  final String text;
  final String? title;
  final String? answerId;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.said});

  final _Said said;

  @override
  Widget build(BuildContext context) {
    final mine = said.kind == _Kind.asked;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
          decoration: BoxDecoration(
            color: mine
                ? AppColors.cyan.withValues(alpha: 0.14)
                : AppColors.raised,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: mine
                  ? AppColors.cyan.withValues(alpha: 0.4)
                  : AppColors.line,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (said.title != null) ...<Widget>[
                Text(
                  said.title!,
                  style: const TextStyle(
                    color: AppColors.cyan,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
              ],
              Text(
                said.text,
                style: TextStyle(
                  color: mine ? AppColors.text : AppColors.text,
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.raised,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: const BorderSide(color: AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 11, 11),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: AppColors.text, fontSize: 13.5),
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}


/// A question you asked, with the answer under it when there is one.
class _Asked extends StatelessWidget {
  const _Asked({required this.request});

  final HelpRequest request;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: request.answered
              ? AppColors.cyan.withValues(alpha: 0.45)
              : AppColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            request.question,
            style: const TextStyle(
                color: AppColors.text, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 7),
          if (request.answered) ...<Widget>[
            const Divider(height: 14, color: AppColors.line),
            Text(
              request.notes.trim(),
              style: const TextStyle(
                  color: AppColors.cyan, fontSize: 13, height: 1.5),
            ),
          ] else
            // Said plainly rather than left blank. "Waiting" is a real state
            // and somebody who cannot tell the difference between waiting
            // and ignored assumes ignored.
            const Text(
              'Waiting for an answer.',
              style: TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
        ],
      ),
    );
  }
}
