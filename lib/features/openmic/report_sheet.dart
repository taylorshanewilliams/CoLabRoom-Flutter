import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';

/// Saying that something should not be here.
///
/// Deliberately short. Somebody filing a report is usually upset, sometimes
/// frightened, and always in the middle of something else — a form with six
/// required fields is a form that turns "this is abusive" into "never mind".
/// A reason, an optional sentence, done.
///
/// The reasons are a fixed list rather than free text alone, because a queue
/// of a hundred unlabelled paragraphs cannot be triaged and a queue that
/// cannot be triaged is one nobody reads. `copyright` is on the list on
/// purpose: it is the first step of a takedown and it needs somewhere to
/// arrive other than an inbox.
Future<bool> showReportSheet(
  BuildContext context, {
  required MusicRepository repository,
  required String kind,
  required String about,
  String? profileId,
  String? projectId,
  String? layerId,
  String? linkId,
  String? roomId,
}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _ReportSheet(
        repository: repository,
        kind: kind,
        about: about,
        profileId: profileId,
        projectId: projectId,
        layerId: layerId,
        linkId: linkId,
        roomId: roomId,
      ),
    ),
  );
  return sent ?? false;
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.repository,
    required this.kind,
    required this.about,
    this.profileId,
    this.projectId,
    this.layerId,
    this.linkId,
    this.roomId,
  });

  final MusicRepository repository;
  final String kind;
  final String about;
  final String? profileId;
  final String? projectId;
  final String? layerId;
  final String? linkId;
  final String? roomId;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final TextEditingController _detail = TextEditingController();
  ReportReason? _reason;
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.repository.reportContent(
        kind: widget.kind,
        reason: reason.id,
        detail: _detail.text.trim(),
        profileId: widget.profileId,
        projectId: widget.projectId,
        layerId: widget.layerId,
        linkId: widget.linkId,
        roomId: widget.roomId,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'report_content',
          route: 'Report',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Report ${widget.about}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              // Said up front, because the two questions somebody has before
              // reporting are "will they find out" and "will anything
              // happen". Both are answered here rather than after.
              const Text(
                'They are not told, and they never see this. It goes to a '
                'queue a person reads.',
                style: TextStyle(
                    color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 18),
              for (final reason in ReportReason.values)
                InkWell(
                  onTap: () => setState(() => _reason = reason),
                  borderRadius: BorderRadius.circular(9),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _reason == reason
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 19,
                          color: _reason == reason
                              ? AppColors.cyan
                              : AppColors.muted,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            reason.label,
                            style: const TextStyle(
                              color: AppColors.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: _detail,
                maxLines: 3,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Anything else (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  style: const TextStyle(
                      color: AppColors.orange, fontSize: 12.5, height: 1.4),
                ),
              ],
              const SizedBox(height: 10),
              FilledButton(
                onPressed: (_reason == null || _sending)
                    ? null
                    : () => unawaited(_send()),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: AppColors.orange,
                  foregroundColor: AppColors.ink,
                ),
                child: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.ink),
                      )
                    : const Text('Send the report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
