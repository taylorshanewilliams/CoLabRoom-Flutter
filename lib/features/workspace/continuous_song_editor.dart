import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import 'line_reconciliation.dart';

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
///
/// The result is trimmed because the repository trims before it writes, so an
/// untrimmed line is never what ends up in the row. Returning it unchanged
/// made the editor compare "Hello " against the stored "Hello", conclude the
/// line had changed, and rewrite it on every single save for as long as the
/// trailing space existed.
String storedLineFor(String line) {
  final trimmed = line.trim();
  return trimmed.isEmpty ? blankStoredLine : trimmed;
}

/// Why a save failed, and whether another attempt could possibly do better.
///
/// The editor cannot tell those apart on its own — it only sees that the save
/// threw — and treating them alike is what made this unreadable. A dropped
/// connection succeeds as soon as the radio is back. A row the server refuses
/// is refused identically every time, so retrying it five times only delays
/// telling the writer the one thing they need to hear.
class SongSaveFailure implements Exception {
  const SongSaveFailure(this.message, {required this.permanent});

  /// Written for the person who is trying to save, not for a log.
  final String message;

  /// True when the next attempt would fail in exactly the same way.
  final bool permanent;

  @override
  String toString() => message;
}

class ContinuousSongEditorController {
  ContinuousSongEditorController()
      : text = _LyricsTextController(),
        focusNode = FocusNode();

  final _LyricsTextController text;
  final FocusNode focusNode;
  String? _projectId;
  String _lastHydratedText = '';

  /// The lines, in order, that the text on screen was built from: which
  /// contribution each one is and the words it held.
  ///
  /// Two things read this. The save path diffs the text against it to decide
  /// which contribution each line on screen is (see line_reconciliation.dart),
  /// and it checks the order against the server's, because the picture can go
  /// stale: [syncProject] deliberately refuses to hydrate while somebody is
  /// typing — nobody wants text replaced mid-sentence — so a bandmate's new
  /// line never reaches it. Without a record of what this editor actually
  /// saw, that stale picture gets written over the fresh one, and from the
  /// save path's side it is indistinguishable from an edit.
  ///
  /// The words matter as well as the ids. A bandmate can rewrite a line in
  /// place without changing any id; comparing the text with the words this
  /// editor was shown, rather than with the server's, leaves their rewrite
  /// alone unless this writer changed that line too.
  List<SeenLine> _seen = const <SeenLine>[];

  /// What the editor believes the server's line order is. Empty before the
  /// first hydrate, which callers must read as "unknown" rather than
  /// "the song has no lines".
  List<String> get viewOfServer =>
      List<String>.unmodifiable(_seen.map((line) => line.contributionId));

  /// The lines behind [viewOfServer], with the words, in stored form, that
  /// this editor holds for each.
  List<SeenLine> get seenLines => List<SeenLine>.unmodifiable(_seen);

  void syncProject(SongProject project, {bool force = false}) {
    final next = project.contributions
        .map((line) => displayContributionBody(line.body))
        .join('\n');
    if (!force && focusNode.hasFocus && _projectId == project.id) return;
    if (!force && _projectId == project.id && text.text != _lastHydratedText) return;
    _projectId = project.id;
    _lastHydratedText = next;
    _seen = List<SeenLine>.unmodifiable(project.contributions.map(
      (line) => SeenLine(
        contributionId: line.id,
        body: storedLineFor(displayContributionBody(line.body)),
      ),
    ));
    if (text.text == next) return;
    text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  void markSaved() {
    _lastHydratedText = text.text;
  }

  /// Records what the server holds of this editor's document straight after
  /// a save, whether it landed whole or only in part.
  ///
  /// A save creates, moves and deletes rows, so the lines the editor hydrated
  /// with are stale the instant one succeeds — and comparing against them
  /// would then refuse the *next* save over changes this very editor made.
  /// Kept separate from [syncProject] because that one also replaces the
  /// text, which is exactly what must not happen to somebody still typing.
  ///
  /// Only lines this editor wrote or was shown belong here. A line a
  /// bandmate added during the save is still not on this screen, and
  /// recording it as seen would let the next save delete it.
  void noteServerView(Iterable<SeenLine> lines) {
    _seen = List<SeenLine>.unmodifiable(lines);
  }

  /// What a save of [lines] would do, against what this editor was shown.
  LineReconciliation reconcile(List<String> lines) =>
      reconcileLines(_seen, lines.map(storedLineFor).toList(growable: false));

  /// The contribution each line of the text on screen is, or null for words
  /// that are not saved yet.
  ///
  /// The rail beside the words used to take the contribution at the same
  /// index, which is the positional assumption the save path had: type a new
  /// first line and every dot below it showed the colour and the voice note
  /// of the line above until the save landed. The diff answers it properly.
  List<Contribution?> ownersIn(SongProject project) {
    final byId = <String, Contribution>{
      for (final line in project.contributions) line.id: line,
    };
    return reconcile(text.text.split('\n'))
        .lines
        .map((line) => line.contributionId == null ? null : byId[line.contributionId])
        .toList(growable: false);
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

  /// The reason the last attempt failed, kept so the chip can say something
  /// truer than "Save failed". Discarding this — which is what `catch (_)`
  /// did — meant the one fact that explains the failure was thrown away at
  /// the moment it was learned, leaving nobody, writer or developer, able to
  /// find out why a song would not save.
  String? _failureMessage;
  bool _failurePermanent = false;
  bool _internalSync = false;
  Future<void>? _activeSave;

  /// The words as they were when the listener last ran.
  ///
  /// A TextEditingController tells its listeners about the cursor as well as
  /// the text, so a tap into the words used to count as an edit. On 17
  /// September 2026 one tap into a song with no written lines saved a blank
  /// line into it, on a song four people share. Only a change to the words
  /// is an edit.
  String _seenText = '';

  @override
  void initState() {
    super.initState();
    widget.controller.syncProject(widget.project, force: true);
    _seenText = widget.controller.text.text;
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
  bool get _saveStalled =>
      _saveFailed && (_failurePermanent || _consecutiveFailures >= _maxSaveAttempts);

  /// How long to wait before attempt n+1. Doubling from the debounce interval
  /// so a transient outage is not hammered, capped so a save that recovers
  /// does not sit idle for a minute afterwards.
  Duration _retryDelay() {
    if (_consecutiveFailures <= 0) return const Duration(milliseconds: 700);
    final ms = 700 * (1 << (_consecutiveFailures - 1));
    return Duration(milliseconds: ms > 8000 ? 8000 : ms);
  }

  void _changed() {
    final words = widget.controller.text.text;
    if (_internalSync || words == _seenText) {
      _seenText = words;
      return;
    }
    _seenText = words;
    _dirty = true;
    _saveFailed = false;
    // An edit is the writer's answer to a stalled save — possibly deleting
    // the very thing that could not be stored — so it earns a fresh budget.
    _consecutiveFailures = 0;
    _failureMessage = null;
    _failurePermanent = false;
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
    // Nothing written into a song that has nothing written: typed and then
    // deleted again. Saving it would store one blank line.
    if (widget.project.contributions.isEmpty && lines.every((line) => line.trim().isEmpty)) {
      _dirty = false;
      widget.controller.markSaved();
      return true;
    }
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
    } catch (error) {
      _dirty = true;
      _saveFailed = true;
      _consecutiveFailures += 1;
      _failureMessage =
          error is SongSaveFailure ? error.message : 'Could not save: $error';
      // A permanent refusal skips the budget entirely. Five identical
      // rejections spread over eight seconds tell the writer nothing that the
      // first one did not.
      _failurePermanent = error is SongSaveFailure && error.permanent;
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

  /// Puts the reason in front of the writer. The chip has room for two words
  /// and the reason is a sentence, so the sentence lives one tap away rather
  /// than nowhere.
  void _explainFailure() {
    final message = _failureMessage;
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
      ));
  }

  /// What a screen reader says about one bullet on the rail.
  ///
  /// Mirrors the states _BulletRailPainter draws, because a label that
  /// disagrees with the dot is worse than no label — someone acting on it
  /// records over a take they were told was empty.
  String _voiceRailLabel(int index, List<Contribution?> owners, List<String> words) {
    final contribution = index < owners.length ? owners[index] : null;
    // The line's own words, so the rail is navigable rather than a column of
    // identical "line 7"s. Truncated: a screen reader reads the whole label
    // before the action at the end of it.
    //
    // The words on screen, not the saved row's. A new line anywhere in the
    // song has no row until its save lands, and read from the row it was
    // announced as "empty line" with its words right there; a blank line's
    // row holds the invisible stored-blank marker, which was read out as if
    // it were words (review, 17 September 2026).
    final body = index < words.length ? words[index].trim() : '';
    final excerpt = body.isEmpty
        ? 'empty line'
        : (body.length > 40 ? '${body.substring(0, 40)}…' : body);
    final where = 'Line ${index + 1}, $excerpt';
    if (contribution == null) return '$where. Voice note unavailable';
    if (contribution.id == widget.recordingContributionId) {
      return '$where. Recording a voice note. Double tap to stop';
    }
    if (contribution.id == widget.savingContributionId) {
      return '$where. Saving voice note';
    }
    if (contribution.id == widget.loadingVoiceContributionId) {
      return '$where. Loading voice note';
    }
    if (contribution.id == widget.playingContributionId) {
      return '$where. Playing voice note. Double tap for options';
    }
    if (contribution.voiceNote != null) {
      return '$where. Has a voice note. Double tap for options';
    }
    return '$where. Double tap to record a voice note';
  }

  Future<void> _voiceTap(int index) async {
    final saved = await _flush();
    if (!saved || !mounted) return;

    // Let the controller reload land in this widget before mapping a visual line
    // to a contribution id. This prevents a voice note attaching to the line that
    // occupied this index before an insert/delete completed.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    // Through the diff, not `contributions[index]`: somebody else's line can
    // be in the song and not on this screen, and words typed since the save
    // are not a line anybody can record against yet.
    final owners = widget.controller.ownersIn(widget.project);
    if (index < 0 || index >= owners.length) return;
    final owner = owners[index];
    if (owner == null) return;
    widget.onVoiceBullet(owner);
  }

  /// The smallest a line's voice-note target may be, either way: WCAG 2.2
  /// SC 2.5.8, the floor the render harness fails a control under.
  static const double _minimumTarget = 24;

  /// One line's labelled, tappable place on the rail.
  ///
  /// A line of lyrics is 13 px tall in landscape and 15 in portrait, and the
  /// target used to be exactly the line: 24x13, under the 24x24 floor (audit
  /// H4, 17 September 2026). The dots cannot be spaced further apart without
  /// pulling them away from their words, so instead each target is at least
  /// 24 px tall, centred on its line, and overlaps its neighbours. Nothing
  /// drawn changes.
  ///
  /// Overlapping means the box a finger lands in does not decide the line.
  /// Where the finger is does: the tap is resolved through the same line
  /// metrics the rest of the rail uses, so a tap just above a line's middle
  /// still reaches that line and not the neighbour whose box is on top.
  Widget _railTarget(
    int index,
    _LineMetrics metrics,
    double railWidth,
    List<Contribution?> owners,
    List<String> words,
  ) {
    final lineHeight = metrics.heights[index];
    final height = math.max(_minimumTarget, lineHeight).toDouble();
    final middle = 4 + metrics.topFor(index) + lineHeight / 2;
    // Never above the rail, where the Stack would clip the target back
    // under the floor for the first line.
    final top = math.max(0.0, middle - height / 2).toDouble();
    return Positioned(
      top: top,
      left: 0,
      width: railWidth,
      height: height,
      child: Semantics(
        button: true,
        label: _voiceRailLabel(index, owners, words),
        onTap: () => unawaited(_voiceTap(index)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The Semantics above already offers this line's tap, with its
          // own index; a second, position-based one would have no position.
          excludeFromSemantics: true,
          onTapUp: (details) {
            final line = metrics.indexForY(top + details.localPosition.dy - 4);
            if (line >= 0) unawaited(_voiceTap(line));
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
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
        final owners = widget.controller.ownersIn(widget.project);
        final words = widget.controller.text.text.split('\n');
        // The scroll view pads its content by 5 above and 86 below (room for
        // the dictation button). Filling the whole viewport *and* padding it
        // left 91 px to scroll on every song, and the workspace scrolls to
        // the end: a short song opened with its first lines, the hint and
        // the voice-note dots all above the top edge -- a black page where
        // the words should be, on phones and on the web.
        const verticalPadding = 5.0 + 86.0;
        final fill = constraints.hasBoundedHeight ? constraints.maxHeight - verticalPadding : 0.0;
        final minHeight = math.max(fill, metrics.totalHeight + 28).toDouble();
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
                          // The painted rail with one real, labelled button
                          // per line laid over it.
                          //
                          // A CustomPaint has no semantics at all, so tapping
                          // a dot to add a voice note was invisible to
                          // VoiceOver and TalkBack: the whole feature simply
                          // did not exist for anyone using one. The tap
                          // handler above stays as it is, both because it
                          // still catches the empty rail below the last line
                          // — where indexForY deliberately clamps to that
                          // line — and because the regions below only need to
                          // add meaning, not replace behaviour.
                          child: Stack(
                            children: <Widget>[
                              // The painting itself is declared decoration:
                              // every dot on it already has a named, tappable
                              // region laid over it below, and labelling the
                              // rail as well would put a second announcement
                              // in front of every line.
                              Positioned.fill(
                                child: ExcludeSemantics(
                                  child: CustomPaint(
                                    painter: _BulletRailPainter(
                                      metrics: metrics,
                                      owners: owners,
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
                              for (var index = 0; index < metrics.heights.length; index += 1)
                                _railTarget(index, metrics, railWidth, owners, words),
                            ],
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
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _saveStalled && _failureMessage != null ? _explainFailure : null,
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
                                  ? (_saveStalled
                                      ? (_failureMessage != null ? 'Not saved — why?' : 'Not saved')
                                      : 'Save retrying')
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

  /// Where line [index] begins, in the same coordinate space [indexForY]
  /// reads. The painter only ever needed centres; a tappable, labelled region
  /// per line needs the top and the height too.
  double topFor(int index) {
    var top = 0.0;
    for (var i = 0; i < index && i < heights.length; i += 1) {
      top += heights[i];
    }
    return top;
  }

  int indexForY(double y) {
    if (centers.isEmpty) return -1;
    // Above the first line is the first line. It fell through the loop and
    // clamped to the last one, so a tap on the top few pixels of the rail —
    // which a target taller than its line now reaches — recorded against the
    // end of the song.
    if (y < 0) return 0;
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
    required this.owners,
    required this.fallbackColor,
    required this.recordingContributionId,
    required this.savingContributionId,
    required this.loadingVoiceContributionId,
    required this.playingContributionId,
    required this.topInset,
  });

  final _LineMetrics metrics;

  /// The contribution behind each line on screen, null for unsaved words,
  /// which are drawn in [fallbackColor] because they will be the writer's.
  final List<Contribution?> owners;
  final Color fallbackColor;
  final String? recordingContributionId;
  final String? savingContributionId;
  final String? loadingVoiceContributionId;
  final String? playingContributionId;
  final double topInset;

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < metrics.centers.length; index += 1) {
      final contribution = index < owners.length ? owners[index] : null;
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
