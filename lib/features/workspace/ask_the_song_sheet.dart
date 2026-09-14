import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../domain/musical_roles.dart';
import '../../services/user_facing_error.dart';

/// Ask the app about this song.
///
/// The app already knows a lot about a song it has analysed -- the key, the
/// chords in the order they come, the sections, the words, who has played
/// what on it -- and until now the only way to ask it anything was to tap a
/// chord. This puts a question box in front of all of it. The server hands
/// the model only what the app worked out, and the answer is a guess from
/// what it heard, said as such.
///
/// **Every answer ends in "or ask somebody".** The app is not the band. Its
/// best answer to "what would go here" is a sentence; a person's is a take.
/// So under every answer is the way to the person, pre-filled with the part
/// the question was about, and that seam is the point of the feature.
Future<void> showAskTheSong(
  BuildContext context, {
  required MusicRepository repository,
  required String projectId,
  required String songTitle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => AskTheSongSheet(
      repository: repository,
      projectId: projectId,
      songTitle: songTitle,
    ),
  );
}

class AskTheSongSheet extends StatefulWidget {
  const AskTheSongSheet({
    required this.repository,
    required this.projectId,
    required this.songTitle,
    super.key,
  });

  final MusicRepository repository;
  final String projectId;
  final String songTitle;

  /// Questions people actually have, one tap each. Typed questions work
  /// too; these save the typing and show what kind of thing to ask.
  static const List<String> starters = <String>[
    'What chords fit that this song has not used?',
    'What would a harmony sing over the chorus?',
    'Where could a bridge go, and in what key?',
  ];

  @override
  State<AskTheSongSheet> createState() => _AskTheSongSheetState();
}

class _AskTheSongSheetState extends State<AskTheSongSheet> {
  final TextEditingController _question = TextEditingController();
  SongAnswer? _answer;
  String? _asked;
  String? _problem;
  bool _thinking = false;
  bool _asking = false;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask([String? starter]) async {
    final question = (starter ?? _question.text).trim();
    if (question.isEmpty || _thinking) return;
    if (starter != null) _question.text = starter;
    setState(() {
      _thinking = true;
      _problem = null;
      _asked = question;
    });
    try {
      final answer = await widget.repository.askTheSong(
        projectId: widget.projectId,
        question: question,
      );
      if (!mounted) return;
      setState(() => _answer = answer);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _answer = null;
        _problem =
            reportAndDescribe(error, service: 'app', stage: 'ask_the_song');
      });
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  /// The seam. The answer names a part; this asks the room for it, the
  /// same way the ask bar on the song does.
  Future<void> _orAskSomebody(SongAnswer answer) async {
    if (_asking) return;
    final part = answer.askPart;
    final label = part == null
        ? 'Ask the room what this song needs?'
        : 'Ask the room for ${MusicalRole.labelFor(part).toLowerCase()}?';
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text(label),
        content: const Text(
          'Everybody in the room hears about it. Somebody who answers '
          'with a take answers better than any sentence can.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const Key('ask_song_or_ask_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Ask'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _asking = true);
    try {
      await widget.repository.askFor(projectId: widget.projectId, part: part);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(part == null
            ? 'Asked the room what it needs.'
            : 'Asked the room for ${MusicalRole.labelFor(part).toLowerCase()}.'),
      ));
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error, service: 'app', stage: 'ask')),
      ));
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'Ask about ${widget.songTitle}',
                key: const Key('ask_song_headline'),
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                children: <Widget>[
                  if (answer == null && _asked == null) ...<Widget>[
                    const Text(
                      'It answers from what it worked out: the key, the '
                      'chords, the sections, the words, and who has played '
                      'what. A guess from what it heard, and it says so.',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 12.5, height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (var i = 0;
                            i < AskTheSongSheet.starters.length;
                            i += 1)
                          ActionChip(
                            key: Key('ask_song_starter_$i'),
                            label: Text(AskTheSongSheet.starters[i]),
                            onPressed: () =>
                                unawaited(_ask(AskTheSongSheet.starters[i])),
                          ),
                      ],
                    ),
                  ],
                  if (_asked != null) ...<Widget>[
                    Text(
                      _asked!,
                      style: const TextStyle(
                        color: AppColors.cyan,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_thinking)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_problem != null)
                    Text(
                      _problem!,
                      key: const Key('ask_song_problem'),
                      style: const TextStyle(
                          color: AppColors.orange, fontSize: 12.5, height: 1.4),
                    ),
                  if (answer != null) ...<Widget>[
                    Text(
                      answer.answer,
                      key: const Key('ask_song_answer'),
                      style: const TextStyle(
                          color: AppColors.text, fontSize: 14.5, height: 1.5),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'A guess from what the app heard. Check it against '
                      'your ears.',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 11.5, height: 1.4),
                    ),
                    const SizedBox(height: 14),
                    // The seam, under every answer, in the room's colour.
                    OutlinedButton.icon(
                      key: const Key('ask_song_or_ask'),
                      onPressed: _asking ? null : () => unawaited(_orAskSomebody(answer)),
                      icon: const Icon(Icons.campaign_outlined, size: 18),
                      label: Text(
                        answer.askLabel,
                        textAlign: TextAlign.center,
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        foregroundColor: AppColors.gold,
                        side: BorderSide(
                            color: AppColors.gold.withValues(alpha: 0.45)),
                      ),
                    ),
                  ],
                ],
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
                        key: const Key('ask_song_question'),
                        controller: _question,
                        minLines: 1,
                        maxLines: 3,
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(
                            color: AppColors.text, fontSize: 14.5),
                        decoration: const InputDecoration(
                          hintText: 'Ask about this song…',
                          counterText: '',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => unawaited(_ask()),
                      ),
                    ),
                    IconButton(
                      key: const Key('ask_song_send'),
                      tooltip: 'Ask',
                      onPressed: _thinking ? null : () => unawaited(_ask()),
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
