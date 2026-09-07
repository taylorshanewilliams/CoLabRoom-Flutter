import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/song_layer_service.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/play_button.dart';
import 'ask_musician_sheet.dart';
import 'report_sheet.dart';

/// A song somebody put up for anybody to hear.
///
/// The page a stranger lands on, and the thing three features have been
/// waiting behind. It answers one question — *do I want to play on this?* — so
/// it holds what somebody needs to decide that and nothing else. Not the
/// catalog it lives in, not the other songs beside it, not who else is in the
/// band. Which songs sit next to this one is the band's business.
///
/// **You hear only what the room has already heard.** 0057 made a take
/// private to its recorder until they share it, and putting a song up does
/// not override that — including when the person who put it up is not the
/// person who recorded the take. The owner offers the song; they never offer
/// somebody else's unheard draft.
class OpenMicSongScreen extends StatefulWidget {
  const OpenMicSongScreen({
    required this.projectId,
    required this.repository,
    this.initial,
    super.key,
  });

  final String projectId;
  final MusicRepository repository;

  /// The row the list already had, so tapping does not open a spinner.
  final OpenMicSong? initial;

  @override
  State<OpenMicSongScreen> createState() => _OpenMicSongScreenState();
}

class _OpenMicSongScreenState extends State<OpenMicSongScreen> {
  OpenMicSong? _song;
  List<SharedLayer>? _takes;
  String? _error;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _song = widget.initial;
    CurrentRoute.enter('Open Mic song');
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final song = await widget.repository.openMicSong(widget.projectId);
      if (!mounted) return;
      if (song == null && widget.initial == null) {
        setState(() => _missing = true);
        return;
      }
      setState(() {
        if (song != null) _song = song;
        _error = null;
      });

      // Separately and after, because the page is worth drawing without them.
      // A take list that fails should not take the song down with it.
      final takes = await SongLayerService().listLayers(widget.projectId);
      if (mounted) setState(() => _takes = takes);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _takes = const <SharedLayer>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'open_mic_song',
          route: 'Open Mic song',
        );
      });
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Offering to play on it, which is the point of the page.
  ///
  /// It reuses the ask sheet backwards. Everywhere else you pick a musician
  /// and offer them a song; here you have the song and you are offering
  /// yourself — so this sends the song's owner an ask naming you, and the
  /// same consent rule applies in the same direction: nothing of theirs opens
  /// up, and nothing of yours does either, until somebody says yes.
  Future<void> _offer() async {
    final song = _song;
    if (song == null || song.ownerId == null) return;
    final me = await widget.repository.loadMusician(
      widget.repository.currentUserId,
    );
    if (!mounted || me == null) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: AskMusicianSheet(
          musician: me,
          repository: widget.repository,
        ),
      ),
    );
    if (sent == true && mounted) {
      _say('Sent. ${song.ownerName} will hear about it.');
    }
  }

  Future<void> _report() async {
    final song = _song;
    if (song == null) return;
    final sent = await showReportSheet(
      context,
      repository: widget.repository,
      kind: 'song',
      about: song.title,
      projectId: song.id,
    );
    if (sent && mounted) {
      _say('Report sent. Thank you — somebody reads every one of these.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: Text(
          song?.title ?? 'On the Open Mic',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17),
        ),
        actions: <Widget>[
          if (song != null)
            IconButton(
              tooltip: 'Report this song',
              onPressed: () => unawaited(_report()),
              icon: const Icon(Icons.flag_outlined, size: 20),
            ),
        ],
      ),
      body: SafeArea(
        child: song == null
            ? Center(
                child: _missing
                    ? const Padding(
                        padding: EdgeInsets.all(28),
                        child: Text(
                          'This song is not on the Open Mic any more.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: AppColors.muted, fontSize: 13.5),
                        ),
                      )
                    : const CircularProgressIndicator(color: AppColors.gold),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
                children: <Widget>[
                  // The song, playable from the top of its own page.
                  //
                  // This page had a section headed "Listen" under which
                  // nothing could be listened to. Whatever the room heard
                  // first plays here; the parts below are the detail.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(right: 14, top: 2),
                        child: PlayButton(
                          storagePath: song.storagePath,
                          durationMs: song.durationMs,
                          title: song.title,
                          size: 54,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              song.title,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              'Put up by ${song.ownerName}',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (song.musicalKey != null || song.bpm != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        if (song.musicalKey != null)
                          _Fact(label: 'Key', value: song.musicalKey!),
                        if (song.bpm != null)
                          _Fact(
                            label: 'Tempo',
                            value: '${song.bpm!.round()} bpm',
                          ),
                      ],
                    ),
                  ],

                  if (song.isAsking) ...<Widget>[
                    const SizedBox(height: 20),
                    _AskingFor(song: song),
                  ],

                  const SizedBox(height: 24),
                  _Heading(
                    'Listen',
                    note: _takes == null
                        ? null
                        : '${_takes!.length} '
                            '${_takes!.length == 1 ? 'part' : 'parts'}',
                  ),
                  const SizedBox(height: 9),
                  if (_takes == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    )
                  else if (_takes!.isEmpty)
                    const Text(
                      'Nothing has been shared on this one yet.',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 12.5, height: 1.45),
                    )
                  else
                    for (final take in _takes!)
                      _TakeRow(take: take),

                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      style: const TextStyle(
                          color: AppColors.orange, fontSize: 12.5),
                    ),
                  ],

                ],
              ),
      ),
      // Pinned rather than at the bottom of the list.
      //
      // This page exists to be answered, and the answer was under the takes —
      // off-screen on a small phone with large text, which meant the only
      // action on the page was one nobody would find. A list of parts is what
      // somebody reads; offering to play is what they came to do.
      bottomNavigationBar: song == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: () => unawaited(_offer()),
                      icon: const Icon(Icons.pan_tool_alt_outlined, size: 18),
                      label: const Text('Offer to play on this'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: AppColors.cyan,
                        foregroundColor: AppColors.ink,
                        textStyle: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: 7),
                    // The same sentence the ask sheet uses, because it is the
                    // same promise pointed the other way.
                    Text(
                      '${song.ownerName} hears about it. Nothing of theirs '
                      'opens up unless they say yes.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// What the song is asking for, which is the only reason most people tap.
class _AskingFor extends StatelessWidget {
  const _AskingFor({required this.song});

  final OpenMicSong song;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 14),
      decoration: BoxDecoration(
        color: AppColors.cyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            song.askingFor.isEmpty
                ? 'Asking for help'
                : 'Asking for ${song.askingFor.join(', ')}',
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (song.askNote.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '“${song.askNote.trim()}”',
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
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// One shared part.
///
/// Named by what it is rather than by who played it. A stranger deciding
/// whether a song needs bass wants to know a bass part is already there; whose
/// it is matters once they are in the room, not before.
class _TakeRow extends StatelessWidget {
  const _TakeRow({required this.take});

  final SharedLayer take;

  @override
  Widget build(BuildContext context) {
    final label = take.label.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: <Widget>[
              // Was a waveform icon: a row that looked exactly like a player
              // and did nothing when you pressed it.
              PlayButton(
                storagePath: take.storagePath,
                durationMs: take.durationMs,
                title: label.isEmpty ? take.part.name : label,
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  label.isEmpty ? take.part.name : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                _length(take.durationMs),
                style:
                    const TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _length(int? ms) {
    if (ms == null || ms <= 0) return '';
    final seconds = (ms / 1000).round();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
            ),
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
            ),
          ),
        ],
      ],
    );
  }
}
