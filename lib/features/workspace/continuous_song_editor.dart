import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// What an intentionally-blank line is actually stored as: contributions'
/// body has a non-empty check constraint, so a genuinely empty line (e.g. a
/// paragraph break the user typed) is persisted as a zero-width space
/// rather than ''.
const String blankStoredLine = '\u200B';

String displayContributionBody(String body) => body == blankStoredLine ? '' : body;

/// How a visual line is persisted.
///
/// The repository trims before it checks for emptiness, so any line made only
/// of whitespace — a stray space, a tab, a `\r` from a CRLF paste, the
/// non-breaking spaces a website puts between verses — arrives at the check
/// as '' and is rejected. `isEmpty` alone does not catch those: the string
/// has characters in it, they just do not survive the trim.
///
/// Such a line is a blank line as far as the writer is concerned, so it is
/// stored as one. The alternative is a save that can never succeed, retried
/// forever, over a space nobody can see.
String storedLineFor(String line) =>
    line.trim().isEmpty ? blankStoredLine : line;

class ContinuousSongEditorController {
  ContinuousSongEditorController()
      : text = _LyricsTextController(),
        focusNode = FocusNode();

  final _LyricsTextController text;
  final FocusNode focusNode;
  String? _projectId;
  String _lastHydratedText = '';

  void syncProject(SongProject project, {bool force = false}) {
    final next = project.contributions
        .map((line) => displayContributionBody(line.body))
        .join('\n');
    if (!force && focusNode.hasFocus && _projectId == project.id) return;
    if (!force && _projectId == project.id && text.text != _lastHydratedText) return;
    _projectId = project.id;
    _lastHydratedText = next;
    if (text.text == next) return;
    text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  void markSaved() {
    _lastHydratedText = text.text;
  }

  void insertDictation(String words) {
    final clean = words.trim();
    if (clean.isEmpty) return;
    final value = text.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length).toInt();
    final end = selection.end.clamp(0, value.text.length).toInt();
    final replacement = value.text.replaceRange(start, end, clean);
    text.value = TextEditingValue(
      text: replacement,
      selection: TextSelection.collapsed(offset: start + clean.length),
    );
    focusNode.requestFocus();
  }

  void dispose() {
    text.dispose();
    focusNode.dispose();
  }
}

class _LyricsTextController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final pieces = <InlineSpan>[];
    final lines = text.split('\n');
    for (var index = 0; index < lines.length; index += 1) {
      final line = lines[index];
      final section = RegExp(r'^\s*\[[^\]]+\]\s*$').hasMatch(line) ||
          RegExp(
            r'^\s*(verse|chorus|bridge|pre[- ]?chorus|intro|outro|solo)\b',
            caseSensitive: false,
          ).hasMatch(line);
      pieces.add(TextSpan(
        text: line,
        style: section
            ? base.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.text.withValues(alpha: 0.88),
                letterSpacing: 0.15,
              )
            : base,
      ));
      if (index != lines.length - 1) pieces.add(const TextSpan(text: '\n'));
    }
    return TextSpan(style: base, children: pieces);
  }
}

class ContinuousSongEditor extends StatefulWidget {
  const ContinuousSongEditor({
    required this.project,
    required this.controller,
    required this.authorColor,
    required this.onSaveDocument,
    required this.onVoiceBullet,
    required this.recordingContributionId,
    required this.savingContributionId,
    required this.loadingVoiceContributionId,
    required this.playingContributionId,
    this.scrollController,
    super.key,
  });

  final SongProject project;
  final ContinuousSongEditorController controller;
  final Color authorColor;
  final Future<void> Function(List<String> lines) onSaveDocument;
  final ValueChanged<Contribution> onVoiceBullet;
  final String? recordingContributionId;
  final String? savingContributionId;
  final String? loadingVoiceContributionId;
  final String? playingContributionId;

  /// Optional externally-owned controller (e.g. so a parent can drive
  /// scroll-to-bottom). When omitted, the editor manages its own.
  final ScrollController? scrollController;

  @override
  State<ContinuousSongEditor> createState() => _ContinuousSongEditorState();
}

class _ContinuousSongEditorState extends State<ContinuousSongEditor> {
  late final ScrollController _scroll = widget.scrollController ?? ScrollController();
  Timer? _saveDebounce;
  bool _dirty = false;
  bool _saving = false;
  bool _saveFailed = false;

  /// Consecutive failed save attempts, and the ceiling past which retrying
  /// stops. A save that fails because the network dropped succeeds on the
  /// next attempt; a save that fails because the document itself is
  /// unacceptable fails identically every time, and retrying it on a 700ms
  /// timer is an infinite loop that reports itself to the writer as ordinary
  /// progress. Backing off and then stopping turns that into something a
  /// person can see and act on.
  int _consecutiveFailures = 0;
  static const int _maxSaveAttempts = 5;
  bool _internalSync = false;
  Future<void>? _activeSave;

  @override
  void initState() {
    super.initState();
    widget.controller.syncProject(widget.project, force: true);
    widget.controller.text.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ContinuousSongEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.text.removeListener(_changed);
      widget.controller.text.addListener(_changed);
    }
    if (!_dirty && !_saving) {
      _internalSync = true;
      widget.controller.syncProject(widget.project);
      _internalSync = false;
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    widget.controller.text.removeListener(_changed);
    if (_dirty) unawaited(_flush());
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  /// Retrying has stopped. Distinct from [_saveFailed], which is the ordinary
  /// "that attempt missed, another is coming" state.
  bool get _saveStalled => _saveFailed && _consecutiveFailures >= _maxSaveAttempts;

  /// How long to wait before attempt n+1. Doubling from the debounce interval
  /// so a transient outage is not hammered, capped so a save that recovers
  /// does not sit idle for a minute afterwards.
  Duration _retryDelay() {
    if (_consecutiveFailures <= 0) return const Duration(milliseconds: 700);
    final ms = 700 * (1 << (_consecutiveFailures - 1));
    return Duration(milliseconds: ms > 8000 ? 8000 : ms);
  }

  void _changed() {
    if (_internalSync) return;
    _dirty = true;
    _saveFailed = false;
    // An edit is the writer's answer to a stalled save — possibly deleting
    // the very thing that could not be stored — so it earns a fresh budget.
    _consecutiveFailures = 0;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () => unawaited(_flush()));
    if (mounted) setState(() {});
  }

  Future<bool> _flush() async {
    _saveDebounce?.cancel();
    final active = _activeSave;
    if (active != null) {
      await active;
      if (_dirty && !_saveStalled) return _flush();
      return !_saveFailed;
    }
    if (!_dirty) return !_saveFailed;

    final lines = widget.controller.text.text.split('\n');
    _dirty = false;
    final completer = Completer<void>();
    _activeSave = completer.future;
    if (mounted) {
      setState(() {
        _saving = true;
        _saveFailed = false;
      });
    }
    var success = false;
    try {
      await widget.onSaveDocument(lines);
      widget.controller.markSaved();
      _consecutiveFailures = 0;
      success = true;
    } catch (_) {
      _dirty = true;
      _saveFailed = true;
      _consecutiveFailures += 1;
    } finally {
      _activeSave = null;
      if (!completer.isCompleted) completer.complete();
      if (mounted) setState(() => _saving = false);
      // Not rescheduled once the budget is spent. The work is not lost — the
      // text is still on screen and still dirty — but the chip stops claiming
      // a retry is coming when the same attempt has already failed five times
      // and would fail the same way a sixth.
      if (_dirty && !_saveStalled) {
        _saveDebounce = Timer(_retryDelay(), () => unawaited(_flush()));
      }
    }
    return success;
  }

  Future<void> _voiceTap(int index) async {
    final saved = await _flush();
    if (!saved || !mounted) return;

    // Let the controller reload land in this widget before mapping a visual line
    // to a contribution id. This prevents a voice note attaching to the line that
    // occupied this index before an insert/delete completed.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final project = widget.project;
    if (index < 0 || index >= project.contributions.length) return;
    widget.onVoiceBullet(project.contributions[index]);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact = media.orientation == Orientation.landscape;
    final fontSize = compact ? 10.9 : 12.15;
    final lineHeight = compact ? 1.18 : 1.22;
    final style = TextStyle(
      color: AppColors.text,
      fontSize: fontSize,
      height: lineHeight,
      fontWeight: FontWeight.w400,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final railWidth = compact ? 24.0 : 28.0;
        final textWidth = math.max(80.0, constraints.maxWidth - railWidth - 14).toDouble();
        final metrics = _LineMetrics.measure(
          text: widget.controller.text.text,
          width: textWidth,
          style: style,
          direction: Directionality.of(context),
        );
        final minHeight = math.max(constraints.maxHeight, metrics.totalHeight + 28).toDouble();
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: SingleChildScrollView(
                controller: _scroll,
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(compact ? 8 : 10, 5, compact ? 8 : 10, 86),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: railWidth,
                        height: math.max(minHeight, metrics.totalHeight + 16).toDouble(),
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTapUp: (details) {
                            final index = metrics.indexForY(details.localPosition.dy - 4);
                            if (index < 0) return;
                            unawaited(_voiceTap(index));
                          },
                          child: CustomPaint(
                            painter: _BulletRailPainter(
                              metrics: metrics,
                              project: widget.project,
                              fallbackColor: widget.authorColor,
                              recordingContributionId: widget.recordingContributionId,
                              savingContributionId: widget.savingContributionId,
                              loadingVoiceContributionId: widget.loadingVoiceContributionId,
                              playingContributionId: widget.playingContributionId,
                              topInset: 4,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          key: const Key('continuous_song_document'),
                          controller: widget.controller.text,
                          focusNode: widget.controller.focusNode,
                          maxLines: null,
                          minLines: compact ? 10 : 18,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          textCapitalization: TextCapitalization.sentences,
                          cursorColor: AppColors.cyan,
                          selectionControls: materialTextSelectionControls,
                          style: style,
                          decoration: const InputDecoration(
                            filled: false,
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.fromLTRB(0, 4, 4, 16),
                            hintText: 'Tap anywhere and start writing…',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_saving || _dirty || _saveFailed)
              Positioned(
                top: 8,
                right: 12,
                child: AnimatedOpacity(
                  opacity: 0.86,
                  duration: const Duration(milliseconds: 150),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_saving)
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      else
                        Icon(
                          _saveFailed ? Icons.error_outline_rounded : Icons.circle,
                          size: _saveFailed ? 13 : 7,
                          color: _saveFailed ? const Color(0xFFFF718B) : AppColors.muted,
                        ),
                      const SizedBox(width: 5),
                      Text(
                        _saving
                            ? 'Saving'
                            : _saveFailed
                                ? (_saveStalled ? 'Not saved' : 'Save retrying')
                                : 'Editing',
                        style: TextStyle(
                          color: _saveFailed ? const Color(0xFFFF9AA9) : AppColors.muted,
                          fontSize: 9.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LineMetrics {
  const _LineMetrics(this.centers, this.heights, this.totalHeight);

  final List<double> centers;
  final List<double> heights;
  final double totalHeight;

  static _LineMetrics measure({
    required String text,
    required double width,
    required TextStyle style,
    required TextDirection direction,
  }) {
    final lines = text.split('\n');
    final centers = <double>[];
    final heights = <double>[];
    var y = 4.0;
    final minimum = (style.fontSize ?? 12) * (style.height ?? 1.2);
    for (final line in lines) {
      final painter = TextPainter(
        text: TextSpan(text: line.isEmpty ? ' ' : line, style: style),
        textDirection: direction,
        maxLines: null,
      )..layout(maxWidth: width);
      final height = math.max(minimum, painter.height).toDouble();
      centers.add(y + minimum * 0.52);
      heights.add(height);
      y += height;
    }
    return _LineMetrics(centers, heights, y + 12);
  }

  int indexForY(double y) {
    if (centers.isEmpty) return -1;
    var top = 0.0;
    for (var index = 0; index < heights.length; index += 1) {
      final bottom = top + heights[index];
      if (y >= top && y <= bottom) return index;
      top = bottom;
    }
    return heights.length - 1;
  }
}

class _BulletRailPainter extends CustomPainter {
  const _BulletRailPainter({
    required this.metrics,
    required this.project,
    required this.fallbackColor,
    required this.recordingContributionId,
    required this.savingContributionId,
    required this.loadingVoiceContributionId,
    required this.playingContributionId,
    required this.topInset,
  });

  final _LineMetrics metrics;
  final SongProject project;
  final Color fallbackColor;
  final String? recordingContributionId;
  final String? savingContributionId;
  final String? loadingVoiceContributionId;
  final String? playingContributionId;
  final double topInset;

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < metrics.centers.length; index += 1) {
      final contribution = index < project.contributions.length ? project.contributions[index] : null;
      final color = contribution == null ? fallbackColor : Color(contribution.colorValue);
      final center = Offset(size.width * 0.48, topInset + metrics.centers[index]);
      final recording = contribution?.id == recordingContributionId;
      final busy = contribution?.id == savingContributionId || contribution?.id == loadingVoiceContributionId;
      final playing = contribution?.id == playingContributionId;
      final hasNote = contribution?.voiceNote != null;
      final active = recording || busy || playing || hasNote;
      final activeColor = recording ? const Color(0xFFFF718B) : AppColors.cyan;
      if (active) {
        canvas.drawCircle(
          center,
          7,
          Paint()
            ..color = activeColor.withValues(alpha: 0.13)
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          center,
          7,
          Paint()
            ..color = activeColor.withValues(alpha: 0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      canvas.drawCircle(
        center,
        recording ? 3.2 : 2.8,
        Paint()..color = recording ? const Color(0xFFFF718B) : color,
      );
      if (playing) {
        canvas.drawCircle(
          center,
          1.1,
          Paint()..color = Colors.white,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BulletRailPainter oldDelegate) => true;
}
