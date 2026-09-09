import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/provenance_export.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/problem_report.dart';

/// Everything that has happened to this song, in the order it happened.
///
/// The answer to a fear every songwriter has and almost nobody can act on:
/// somebody shows a half-finished song to a collaborator, and later the song
/// is somebody else's. That argument is rarely lost because the truth is
/// unknowable — it is lost because nobody kept a record anybody believes.
///
/// CoLabRoom has kept one accidentally since its first migration: every lyric
/// line carries an author and a revision history, every take carries who
/// recorded it, and all of it is stamped by the server rather than by a phone.
/// This screen is that record, and the export button is the point of it — a
/// history you can only read inside the app helps nobody in an argument. What
/// ends an argument is a dated document you can send.
class SongHistoryScreen extends StatefulWidget {
  const SongHistoryScreen({
    required this.projectId,
    required this.songTitle,
    required this.repository,
    super.key,
  });

  final String projectId;
  final String songTitle;
  final MusicRepository repository;

  @override
  State<SongHistoryScreen> createState() => _SongHistoryScreenState();
}

class _SongHistoryScreenState extends State<SongHistoryScreen> {
  List<ProvenanceEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final events = await widget.repository.loadProvenance(widget.projectId);
      if (mounted) setState(() => _events = events);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'provenance',
          route: 'Song history',
          projectId: widget.projectId,
        );
        _events = const <ProvenanceEvent>[];
      });
    }
  }

  Future<void> _export() async {
    final events = _events;
    if (events == null || events.isEmpty) return;
    try {
      await ProvenanceExport.print(
        songTitle: widget.songTitle,
        events: events,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(
          error,
          service: 'app',
          stage: 'provenance_export',
          route: 'Song history',
        )),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('History', style: TextStyle(fontSize: 17)),
            Text(
              widget.songTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 11),
            ),
          ],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              onPressed: events == null || events.isEmpty
                  ? null
                  : () => unawaited(_export()),
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: const Text(
                'Export',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.cyan,
                disabledForegroundColor: AppColors.line,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: events == null
            ? const Center(child: CircularProgressIndicator(color: AppColors.gold))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: <Widget>[
                  if (_error != null) ...<Widget>[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.raised,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.orange.withValues(alpha: 0.4)),
                      ),
                      child: ProblemNote(_error!,
                          color: AppColors.text, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Said before the list rather than after it, because it
                  // changes how the list should be read. A record that
                  // oversells itself is worse than none: somebody who thinks
                  // this settles ownership will stop doing the things that
                  // actually would.
                  const Text(
                    'Everything that has happened to this song, as it happened, '
                    'stamped by the server rather than by a phone.',
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'This is a record, not a registration. It does not prove '
                    'who owns anything — it shows what happened here and when.',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (events.isEmpty)
                    const Text(
                      'Nothing has happened to this song yet.',
                      style: TextStyle(color: AppColors.muted, fontSize: 13),
                    )
                  else
                    for (var i = 0; i < events.length; i += 1)
                      _EventRow(
                        event: events[i],
                        first: i == 0,
                        last: i == events.length - 1,
                      ),
                ],
              ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.first,
    required this.last,
  });

  final ProvenanceEvent event;
  final bool first;
  final bool last;

  static const Map<String, IconData> _icons = <String, IconData>{
    'song created': Icons.auto_awesome_rounded,
    'recording uploaded': Icons.graphic_eq_rounded,
    'lyric written': Icons.edit_note_rounded,
    'lyric edited': Icons.history_edu_rounded,
    'take recorded': Icons.mic_rounded,
    'asked for': Icons.campaign_outlined,
  };

  String get _stamp {
    final at = event.at;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)}  '
        '${two(at.hour)}:${two(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The thread down the left. It is what makes a list of rows read as
          // one continuous account rather than as separate facts.
          SizedBox(
            width: 28,
            child: Column(
              children: <Widget>[
                Container(
                  width: 2,
                  height: 6,
                  color: first ? Colors.transparent : AppColors.line,
                ),
                Icon(
                  _icons[event.event] ?? Icons.circle,
                  size: 15,
                  color: AppColors.cyan,
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: last ? Colors.transparent : AppColors.line,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16, left: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _stamp,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 10.5,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${event.whoName} — ${event.event}',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (event.detail.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      event.detail,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
