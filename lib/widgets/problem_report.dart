import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/beta_config.dart';
import '../app/beta_scope.dart';
import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';
import '../services/current_route.dart';
import '../services/recent_trouble.dart';
import '../services/telemetry_health.dart';
import '../services/user_facing_error.dart';

/// Says that something failed, records it, and offers to hear about it.
///
/// Three things happen at once here because they belong together and were
/// previously done separately, badly, in about thirty places: the person is
/// told in a sentence they can read, the detail goes to `analysis_errors`
/// where it can be counted, and — because the moment somebody has just been
/// let down is the only moment they will ever describe what they were doing —
/// there is a way to say more, right there.
///
/// The Account screen has had a feedback form since the first build. It has
/// **never been used**: no rows, three weeks, four people, at least three real
/// problems that all reached Taylor by conversation instead. A form on one
/// screen is a form somebody has to go and find after the moment has passed,
/// which is the moment they decide a text message is easier.
void showProblem(
  BuildContext context,
  Object error, {
  required String service,
  String? stage,
  String? projectId,
  String? route,
}) {
  final described = reportAndDescribe(
    error,
    service: service,
    stage: stage,
    projectId: projectId,
    route: route,
  );
  final where = route ?? CurrentRoute.name;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(described),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Tell us',
        onPressed: () => unawaited(showProblemReport(
          context,
          route: where,
          // Carried into the report so nobody has to describe an error
          // message they have already been shown and dismissed.
          detail: error.toString(),
        )),
      ),
    ),
  );
}

/// The report sheet, openable from anywhere.
///
/// [detail] is the machine's half — the exception, already captured. The
/// person writes the half only they have: what they were trying to do.
///
/// Both halves default to the last failure this session, so the sheet arrives
/// already knowing what went wrong even when it is opened from somewhere with
/// no idea — the Account screen, a help page, a button two screens later.
Future<void> showProblemReport(
  BuildContext context, {
  String? route,
  String? detail,
}) {
  final about = detail ?? RecentTrouble.detail;
  final where = route ?? RecentTrouble.route;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      // The keyboard, which on a small phone takes more room than the sheet.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _ProblemReportSheet(route: where, detail: about),
    ),
  );
}

class _ProblemReportSheet extends StatefulWidget {
  const _ProblemReportSheet({this.route, this.detail});

  final String? route;
  final String? detail;

  /// The exception, plus — when the app has been unable to file its own
  /// reports this session — a line saying so.
  ///
  /// That line is the only way the fact ever escapes the device. If
  /// `analysis_errors` is refusing this account's rows, every automatic report
  /// it produced is already gone; feedback is a different table down a
  /// different path, and it is the one thing still getting out. So the health
  /// of the reporter travels with the one message a person sends by hand.
  ///
  /// Shown in the sheet like everything else. A report that quietly carries
  /// something the sender was not shown is not a report they agreed to, and
  /// that applies to a line about the app as much as to a stack trace.
  String? get _machineHalf {
    final parts = <String>[
      if (detail != null) detail!,
      if (TelemetryHealth.summary != null) TelemetryHealth.summary!,
    ];
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  @override
  State<_ProblemReportSheet> createState() => _ProblemReportSheetState();
}

class _ProblemReportSheetState extends State<_ProblemReportSheet> {
  final TextEditingController _message = TextEditingController();
  // Bug first, because this sheet is reached most often from something having
  // just gone wrong. It is a choice rather than a constant: the old form
  // filed everything as 'general', so nothing in the table could ever be
  // sorted into what is broken and what is merely wanted.
  String _category = 'bug';
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);

    final machine = widget._machineHalf;
    final controller = BetaScope.of(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.submitFeedback(FeedbackDraft(
        category: _category,
        // The exception rides along under what the person wrote, rather than
        // in a separate field they cannot see. A report that quietly carries
        // something the sender was not shown is not a report they agreed to.
        message: machine == null
            ? text
            : '$text\n\n— what the app said —\n$machine',
        // The screen they were on, not the screen the form lives on. The old
        // form hardcoded 'account' and would have mislabelled every report it
        // ever received.
        route: widget.route ?? CurrentRoute.name ?? 'unknown',
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
        appVersion: BetaConfig.appVersion,
      ));
      if (mounted) Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Sent. Thank you — that genuinely helps.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      // Reported but not offered a "Tell us" of its own, which would be a
      // loop somebody could not get out of.
      messenger.showSnackBar(SnackBar(
        content: Text(reportAndDescribe(
          error,
          service: 'app',
          stage: 'feedback',
          route: widget.route,
        )),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'What happened?',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (widget.route != null || CurrentRoute.name != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'On ${widget.route ?? CurrentRoute.name}',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'bug', label: Text('Broken')),
                ButtonSegment<String>(value: 'idea', label: Text('Idea')),
                ButtonSegment<String>(value: 'general', label: Text('Other')),
              ],
              selected: <String>{_category},
              onSelectionChanged: (selection) =>
                  setState(() => _category = selection.first),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _message,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'What were you trying to do?',
                border: OutlineInputBorder(),
              ),
            ),
            if (widget._machineHalf != null) ...<Widget>[
              const SizedBox(height: 10),
              // Shown, not hidden. Somebody sending a report is entitled to
              // see everything it contains before it leaves their phone.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.raised,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget._machineHalf!,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Sent with your message, so nobody has to reproduce it.',
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _sending ? null : () => unawaited(_send()),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: Text(_sending ? 'Sending…' : 'Send'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A sentence about something that failed, with a way to say more.
///
/// Twelve screens showed an error as a coloured `Text` and nothing else. Each
/// one is a moment where somebody has just been let down and is thinking about
/// what they were doing — which is the only moment they will ever describe it,
/// and the moment they otherwise decide a text message is easier.
///
/// Deliberately quiet. The sentence stays the size and colour the screen chose
/// for it, and the offer sits underneath in small type. Somebody who does not
/// want to file a report should barely notice this is here.
class ProblemNote extends StatelessWidget {
  const ProblemNote(
    this.message, {
    this.color = AppColors.orange,
    this.fontSize = 12.5,
    this.height = 1.4,
    this.textAlign,
    this.route,
    super.key,
  });

  final String message;
  final Color color;
  final double fontSize;
  final double height;
  final TextAlign? textAlign;

  /// Where this happened, when the screen knows better than [CurrentRoute].
  final String? route;

  @override
  Widget build(BuildContext context) {
    final centred = textAlign == TextAlign.center;
    return Column(
      crossAxisAlignment:
          centred ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          message,
          textAlign: textAlign,
          style: TextStyle(color: color, fontSize: fontSize, height: height),
        ),
        // The exception is already held by RecentTrouble, so this carries no
        // arguments: whatever just failed is what the sheet will attach.
        TextButton(
          onPressed: () => unawaited(showProblemReport(context, route: route)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: AppColors.cyan,
          ),
          child: const Text(
            'Tell us what you were doing',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
