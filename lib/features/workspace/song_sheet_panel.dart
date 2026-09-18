import 'dart:async';
import 'dart:math' as math;

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/features/workspace/chord_editor_sheet.dart';
import 'package:colabroom/features/workspace/chord_sheet_export.dart';
import 'package:colabroom/features/workspace/music_reference_sheets.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/musician_song_sheet.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_transpose_store.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/horn_reading.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Two ways of reading the same song. The sheet is what you sing from; the
/// chart is what you play from.
enum SongSheetView { sheet, chart }

class SongSheetPanel extends StatefulWidget {
  const SongSheetPanel({
    required this.project,
    required this.bundle,
    required this.onReviewLyrics,
    required this.onOpenLive,
    this.onAnalysisChanged,
    super.key,
  });

  final SongProject project;
  final SongAnalysisBundle bundle;
  final VoidCallback? onReviewLyrics;
  final VoidCallback? onOpenLive;
  final ValueChanged<SongAnalysisBundle>? onAnalysisChanged;

  @override
  State<SongSheetPanel> createState() => _SongSheetPanelState();
}

class _SongSheetPanelState extends State<SongSheetPanel> {
  final SongAnalysisService _service = SongAnalysisService();

  late SongAnalysisBundle _bundle;
  SongSheetView _view = SongSheetView.sheet;

  /// The key this person plays the song in, kept on this device (see
  /// SongTransposeStore).
  int _transpose = 0;

  /// Whether a transpose button was pressed before the kept key arrived, so
  /// a slow read cannot undo the press.
  bool _transposeTouched = false;

  /// The instrument this person reads the song for, kept on this device (see
  /// SongReadingStore). It stacks on [_transpose].
  HornReading _reading = HornReading.concert;
  bool _readingTouched = false;
  double _fontScale = 1;
  bool _showChords = true;
  bool _editingChords = false;
  bool _savingChord = false;

  /// The bar grid, worked out once per bundle rather than once per frame.
  ///
  /// It used to be built inline in [build], so every setState on this panel —
  /// font size, transpose, saving a chord, even switching back to the lyric
  /// sheet — re-walked every chord cue against every downbeat in the song
  /// before anything could be drawn. None of it depends on transpose or font
  /// scale, so caching costs one field and takes the work off the frame that
  /// switches to the chart.
  List<ChartRow>? _chartRows;

  /// The sheet's lines, worked out once per bundle for the same reason.
  ///
  /// Two things read these now — the sheet and the two exports — and both
  /// wanted them in [build], where a plain call re-walked the transcript and
  /// re-scanned every chord cue against every line on every frame, including
  /// the frames that draw the chart and never look at them.
  ///
  /// Safe to key on the bundle alone: with `ignoreWorkspaceLyrics` these come
  /// entirely from the recording, so the project the panel is holding does
  /// not enter into them.
  List<MusicianSheetLine>? _lines;

  List<ChartRow> get _chart => _chartRows ??= buildChartRows(
        buildChartBars(
          cues: _bundle.chordCues,
          beatsMs: _bundle.reference?.beatsMs ?? const <int>[],
          downbeatsMs: _bundle.reference?.downbeatsMs ?? const <int>[],
          sections:
              _bundle.reference?.structureSections ?? const <StructureSection>[],
        ),
      );

  @override
  void initState() {
    super.initState();
    _bundle = widget.bundle;
    unawaited(_loadTranspose());
    unawaited(_loadReading());
  }

  @override
  void didUpdateWidget(covariant SongSheetPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bundle, widget.bundle)) {
      _bundle = widget.bundle;
      _chartRows = null;
      _lines = null;
    }
    if (oldWidget.project.id != widget.project.id) {
      _transpose = 0;
      _transposeTouched = false;
      _reading = HornReading.concert;
      _readingTouched = false;
      unawaited(_loadTranspose());
      unawaited(_loadReading());
    }
  }

  Future<void> _loadTranspose() async {
    final projectId = widget.project.id;
    final kept = await SongTransposeStore.load(projectId);
    if (!mounted || _transposeTouched || widget.project.id != projectId) return;
    if (kept != _transpose) setState(() => _transpose = kept);
  }

  Future<void> _loadReading() async {
    final projectId = widget.project.id;
    final kept = await SongReadingStore.load(projectId);
    if (!mounted || _readingTouched || widget.project.id != projectId) return;
    if (kept != _reading) setState(() => _reading = kept);
  }

  void _chooseReading(HornReading reading) {
    setState(() {
      _readingTouched = true;
      _reading = reading;
    });
    unawaited(SongReadingStore.save(widget.project.id, reading));
  }

  /// The song's own key, or null when the analysis never found one.
  String? get _songKey {
    final key = _bundle.reference?.musicalKey;
    if (key == null || key.trim().isEmpty) return null;
    return key;
  }

  /// The second way into the Read as choice.
  ///
  /// The key badge is where it belongs and where it stays, but the badge is
  /// only on the lyric sheet and only on a song that has a key — so on the
  /// chart, and on a song whose analysis found no key, the choice could be
  /// neither made nor undone (review, 17 September 2026). The transpose label
  /// is the control that is always there and is already about what key this
  /// person reads in, so it opens the same sheet.
  void _openReadingChoice() {
    final key = _songKey;
    unawaited(showReadingChoice(
      context,
      keyLabel: key == null ? null : keyAsPlayed(key, _shownTranspose),
      reading: _shownReading,
      onReading: _chooseReading,
    ));
  }

  void _shiftTranspose(int delta) {
    final next = (_transpose + delta)
        .clamp(-SongTransposeStore.limit, SongTransposeStore.limit)
        .toInt();
    setState(() {
      _transposeTouched = true;
      _transpose = next;
    });
    unawaited(SongTransposeStore.save(widget.project.id, next));
  }

  /// The transpose the page is drawn with.
  ///
  /// Correcting chords shows them in the song's own key, because a chord
  /// typed into the editor is saved as written and has to be read against
  /// what is stored. It used to do that by setting the transpose back to
  /// zero, which was harmless while nothing remembered it. Now it is only
  /// set aside for the edit, and your key comes back with Done.
  int get _shownTranspose => _editingChords ? 0 : _transpose;

  /// The reading the page is drawn with, set aside while chords are being
  /// corrected for the same reason the transpose is: a chord typed into the
  /// editor is saved as written and has to be read against what is stored,
  /// not against what a trumpet would call it.
  HornReading get _shownReading =>
      _editingChords ? HornReading.concert : _reading;

  void _toggleChordEditing() {
    setState(() {
      _editingChords = !_editingChords;
      _showChords = true;
    });
  }

  @override
  void dispose() {
    _sheetFocus.dispose();
    super.dispose();
  }

  /// The chord the keyboard is holding, and where it sits.
  ///
  /// Correcting a sheet is aiming, and a fingertip is a blunt instrument —
  /// which is why the touch path is a modal with a chord picker in it. A
  /// keyboard is not blunt, and the correction people actually make most
  /// often is not "this is the wrong chord", it is "this chord is over the
  /// wrong word". That is one keystroke, and it should cost one keystroke.
  ///
  /// Up and down move the selection; left and right move the chord. Keeping
  /// those on separate axes is what stops the two from being the same
  /// gesture with a mode behind it.
  ChordCue? _selected;
  MusicianSheetLine? _selectedLine;
  int _selectedWord = 0;
  final FocusNode _sheetFocus = FocusNode(debugLabel: 'song sheet');

  /// The sheet's chords in reading order, from the bundle as it stands.
  List<({MusicianSheetLine line, ChordCue chord, int wordIndex})>
      _chordsInOrder() => chordsInReadingOrder(_sheetLines());

  List<MusicianSheetLine> _sheetLines() => _lines ??= buildMusicianSheetLines(
        widget.project,
        _bundle,
        ignoreWorkspaceLyrics: true,
      );

  /// What both exports are handed: the page as it is being read, with the
  /// recording's section names folded in so the chart carries the shape of
  /// the song and not just its lines.
  List<MusicianSheetLine> _linesToExport() => ChordSheetExport.withSectionNames(
        _sheetLines(),
        _bundle.reference?.structureSections ?? const <StructureSection>[],
      );

  Future<void> _printChart() async {
    try {
      await ChordSheetExport.printChart(
        project: widget.project,
        lines: _linesToExport(),
        transpose: _shownTranspose,
        musicalKey: _bundle.reference?.musicalKey,
        bpm: _bundle.reference?.bpm,
      );
    } catch (error) {
      _saySomethingWentWrong(error);
    }
  }

  Future<void> _sendChordPro() async {
    try {
      await ChordSheetExport.shareChordPro(
        project: widget.project,
        lines: _linesToExport(),
        transpose: _shownTranspose,
        musicalKey: _bundle.reference?.musicalKey,
        bpm: _bundle.reference?.bpm,
      );
    } catch (error) {
      _saySomethingWentWrong(error);
    }
  }

  void _saySomethingWentWrong(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(reportAndDescribe(
            error,
            service: 'app',
            stage: 'chart_export',
            route: 'Song sheet',
            projectId: widget.project.id,
          )),
        ),
      );
  }

  void _moveSelection(int delta) {
    final all = _chordsInOrder();
    if (all.isEmpty) return;
    final current = _selected;
    var next = 0;
    if (current != null) {
      final at =
          all.indexWhere((entry) => entry.chord.startMs == current.startMs);
      if (at >= 0) next = (at + delta).clamp(0, all.length - 1);
    } else if (delta < 0) {
      next = all.length - 1;
    }
    setState(() {
      _selectedLine = all[next].line;
      _selected = all[next].chord;
      _selectedWord = all[next].wordIndex;
    });
  }

  /// Move the held chord one word along, and save it there.
  ///
  /// The same call the modal makes, with the word index the arrow key asked
  /// for — so a nudge and a correction land in the database identically and
  /// there is only one way a chord can be wrong.
  Future<void> _nudgeSelected(int delta) async {
    final cue = _selected;
    final line = _selectedLine;
    if (cue == null || line == null || _savingChord) return;
    final words = line.body
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) return;
    final target = (_selectedWord + delta).clamp(0, words.length - 1);
    if (target == _selectedWord) return;

    final startMs = chordStartForWordIndex(
      wordIndex: target,
      wordCount: math.max(1, words.length).toInt(),
      lineStartMs: line.startMs,
      lineEndMs: line.endMs,
    );
    final length = math.max(300, cue.endMs - cue.startMs).toInt();
    setState(() {
      _savingChord = true;
      _selectedWord = target;
    });
    try {
      final updated = await _service.saveManualChordCue(
        projectId: widget.project.id,
        cueId: cue.id,
        originalStartMs: cue.startMs,
        originalChord: cue.chord,
        chord: cue.chord,
        startMs: startMs,
        endMs: startMs + length,
      );
      if (!mounted) return;
      setState(() {
        _bundle = updated;
        _chartRows = null;
        _lines = null;
      });
      widget.onAnalysisChanged?.call(updated);
      // The cue keeps its id through a save, so the selection can follow it
      // to where it landed rather than being dropped on every keystroke.
      final again = _chordsInOrder()
          .where((entry) => entry.chord.startMs == startMs)
          .toList(growable: false);
      if (again.isNotEmpty && mounted) {
        setState(() {
          _selectedLine = again.first.line;
          _selected = again.first.chord;
          _selectedWord = again.first.wordIndex;
        });
      }
    } catch (_) {
      // Leave the selection where it was; the sheet still shows the truth.
    } finally {
      if (mounted) setState(() => _savingChord = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_editingChords) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_nudgeSelected(1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_nudgeSelected(-1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _selected = null;
        _selectedLine = null;
      });
      return KeyEventResult.handled;
    }
    // Enter hands the held chord to the same editor a tap opens, because
    // changing which chord it is still wants the picker.
    if (key == LogicalKeyboardKey.enter && _selected != null) {
      unawaited(_editChord(_selectedLine!, _selected!, _selectedWord));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _editChord(
    MusicianSheetLine line,
    ChordCue chord,
    int wordIndex,
  ) {
    return _openChordEditor(
      line: line,
      existing: chord,
      wordIndex: wordIndex,
    );
  }

  Future<void> _addChord(MusicianSheetLine line, int wordIndex) {
    return _openChordEditor(line: line, wordIndex: wordIndex);
  }

  Future<void> _openChordEditor({
    required MusicianSheetLine line,
    required int wordIndex,
    ChordCue? existing,
  }) async {
    if (_savingChord || line.section || line.body.trim().isEmpty) return;
    final result = await showModalBottomSheet<ChordEditResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.deepNavy,
      builder: (_) => ChordEditorSheet(
        line: line,
        existing: existing,
        initialWordIndex: wordIndex,
      ),
    );
    if (result == null || !mounted) return;

    setState(() => _savingChord = true);
    try {
      SongAnalysisBundle updated;
      if (result.delete && existing != null) {
        updated = await _service.deleteChordCue(
          projectId: widget.project.id,
          cueId: existing.id,
          originalStartMs: existing.startMs,
          originalChord: existing.chord,
        );
      } else {
        final words = line.body
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty)
            .toList(growable: false);
        final startMs = chordStartForWordIndex(
          wordIndex: result.wordIndex,
          wordCount: math.max(1, words.length).toInt(),
          lineStartMs: line.startMs,
          lineEndMs: line.endMs,
        );
        final originalLength =
            existing == null ? 0 : existing.endMs - existing.startMs;
        final lineShare = words.isEmpty
            ? 650
            : math
                .max(
                  450,
                  (line.endMs - line.startMs) ~/
                      math.max(1, words.length),
                )
                .toInt();
        final duration = math.max(originalLength, lineShare).toInt();
        final referenceEnd = _bundle.reference?.durationMs ?? 0;
        final preferredEnd = startMs + math.max(300, duration).toInt();
        final endMs = referenceEnd > startMs
            ? math.min(referenceEnd, preferredEnd).toInt()
            : preferredEnd;

        updated = await _service.saveManualChordCue(
          projectId: widget.project.id,
          cueId: existing?.id,
          originalStartMs: existing?.startMs,
          originalChord: existing?.chord,
          chord: result.chord,
          startMs: startMs,
          endMs: math.max(startMs + 120, endMs).toInt(),
        );
      }
      if (!mounted) return;
      setState(() {
        _bundle = updated;
        // A corrected chord changes the bars too — the cached grid has to go
        // with the cues it was built from, and so do the sheet's lines.
        _chartRows = null;
        _lines = null;
      });
      widget.onAnalysisChanged?.call(updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not save that chord: $error')),
        );
    } finally {
      if (mounted) setState(() => _savingChord = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final transpose = _shownTranspose;
    final sheetLines = _sheetLines();
    final reading = _shownReading;
    final baseLabel = transpose == 0
        ? 'Original key'
        : transpose > 0
            ? '+$transpose semitones'
            : '$transpose semitones';
    // The chart has no key badge, so without this a horn reading chosen on
    // the sheet would move every chord on the chart with nothing on screen
    // saying why (interface direction: it hides brilliantly and announces
    // nothing). On the chart it names both keys, because the concert key is
    // what a horn player has to call the tune to everybody else and the
    // badge that usually says it is not there. On the sheet the badge says
    // both already, so this only names the part.
    final songKey = _songKey;
    final readingLine = reading == HornReading.concert
        ? null
        : _view == SongSheetView.chart && songKey != null
            ? keyAsRead(songKey, transpose: transpose, reading: reading)
            : 'For ${reading.label}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    tooltip: 'Transpose down',
                    onPressed:
                        _editingChords ? null : () => _shiftTranspose(-1),
                    icon: const Icon(Icons.remove_rounded, size: 18),
                  ),
                  Expanded(
                    // Underlined the way the key badge is, and for the same
                    // reason: a label reads as a label, and nobody taps one.
                    child: Semantics(
                      button: !_editingChords,
                      child: InkWell(
                        key: const Key('song_sheet_read_as'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: _editingChords ? null : _openReadingChoice,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                baseLabel,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.text,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  decoration: _editingChords
                                      ? null
                                      : TextDecoration.underline,
                                  decorationStyle: TextDecorationStyle.dotted,
                                  decorationColor: AppColors.muted,
                                ),
                              ),
                              if (readingLine != null)
                                Text(
                                  readingLine,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Transpose up',
                    onPressed:
                        _editingChords ? null : () => _shiftTranspose(1),
                    icon: const Icon(Icons.add_rounded, size: 18),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.tonalIcon(
                    key: const Key('toggle_chord_editing'),
                    onPressed: _savingChord ? null : _toggleChordEditing,
                    icon: Icon(
                      _editingChords
                          ? Icons.check_rounded
                          : Icons.edit_rounded,
                      size: 17,
                    ),
                    label: Text(
                      _editingChords ? 'Done' : 'Edit chords',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: <Widget>[
                  _ViewToggle(
                    view: _view,
                    // Editing chords is a lyric-sheet gesture — tap a word,
                    // tap a chord — so the chart used to refuse the switch
                    // while it was on. It refused it *silently*: the segment
                    // went grey and a tap did nothing, which is the same
                    // thing a frozen app does. Switching now just ends the
                    // edit, which is what somebody pressing Chart means.
                    // Only a save actually in flight still holds the control,
                    // and that one says why.
                    onChanged: _savingChord
                        ? null
                        : (next) => setState(() {
                              _view = next;
                              if (next == SongSheetView.chart) {
                                _editingChords = false;
                              }
                            }),
                  ),
                  if (_view == SongSheetView.sheet)
                    TextButton.icon(
                      onPressed: () => setState(
                        () => _showChords = !_showChords,
                      ),
                      icon: Icon(
                        _showChords
                            ? Icons.music_note_rounded
                            : Icons.music_off_rounded,
                        size: 17,
                        color:
                            _showChords ? AppColors.gold : AppColors.muted,
                      ),
                      label: Text(
                        _showChords ? 'Chords on' : 'Chords off',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Smaller text',
                    onPressed: () => setState(() {
                      _fontScale =
                          (_fontScale - 0.08).clamp(0.78, 1.34).toDouble();
                    }),
                    icon: const Icon(
                      Icons.text_decrease_rounded,
                      size: 18,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Larger text',
                    onPressed: () => setState(() {
                      _fontScale =
                          (_fontScale + 0.08).clamp(0.78, 1.34).toDouble();
                    }),
                    icon: const Icon(
                      Icons.text_increase_rounded,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_editingChords) ...<Widget>[
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.gold.withValues(alpha: 0.16),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(
                  Icons.touch_app_rounded,
                  color: AppColors.gold,
                  size: 17,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _savingChord
                        ? 'Saving chord correction…'
                        : 'Tap a chord to correct or remove it. Tap any lyric word to add a chord or move one there.',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 10.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else ...<Widget>[
          // A plain grey sentence here was missed entirely — the feature was
          // found by accident. It reads as an instruction now, in the same
          // shape as the editing banner it sits in place of, because the
          // thing it is describing is not guessable from a chord that looks
          // like every other chord ever printed on paper.
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.cyan.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cyan.withValues(alpha: 0.16)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(
                  Icons.touch_app_rounded,
                  color: AppColors.cyan,
                  size: 17,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _view == SongSheetView.chart
                        ? 'Tap any underlined chord for its shape, the notes '
                            'in it, and what works over it.'
                        : 'Tap any underlined chord for its shape, the notes '
                            'in it, and what works over it — or the key for '
                            'the scale and where to put a capo.',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 10.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        if (_view == SongSheetView.chart)
          ChordChartView(
            rows: _chart,
            // The chart is the same chords, so it reads the same way: the
            // person's key with their instrument's transposition on top.
            transpose: transpose + reading.semitones,
            fontScale: _fontScale,
            // The song, so a tapped chord can say where it sits in it rather
            // than only what it is.
            musicalKey: _bundle.reference?.musicalKey,
          )
        else
          Focus(
            focusNode: _sheetFocus,
            onKeyEvent: _onKey,
            child: MusicianSongSheet(
            title: widget.project.title,
            lines: sheetLines,
            musicalKey: _bundle.reference?.musicalKey,
            transpose: transpose,
            reading: reading,
            onReading: _editingChords ? null : _chooseReading,
            fontScale: _fontScale,
            showChords: _showChords,
            editableChords: _editingChords && !_savingChord,
            selectedChordStartMs:
                _editingChords ? _selected?.startMs : null,
            onEditChord: (line, chord, wordIndex) {
              unawaited(_editChord(line, chord, wordIndex));
            },
            onAddChord: (line, wordIndex) {
              unawaited(_addChord(line, wordIndex));
            },
          ),
          ),
        // Taking the page with you. On its own row and spelled out, rather
        // than behind an icon in the toolbar above: a fill-in player being
        // handed a chart is one of the few moments this app has where
        // somebody who does not use it gets something out of it, and it is
        // not a thing anybody thinks to go looking for a menu for.
        if (sheetLines.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('print_chord_chart'),
                  onPressed: () => unawaited(_printChart()),
                  icon: const Icon(Icons.print_rounded, size: 17),
                  // Not "Print chart". The segments above this call the bar
                  // grid the Chart, so a button under it saying chart would
                  // print the page somebody is not looking at and use the
                  // same word for two different pages. This one says what
                  // comes out of the printer.
                  label: const Text(
                    'Print chords and words',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              // A browser has no share sheet for a file — see
              // ChordSheetExport.shareChordPro. Off here with a sentence
              // rather than a button that throws and files a fault.
              if (!kIsWeb) ...<Widget>[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('send_as_chordpro'),
                    onPressed: () => unawaited(_sendChordPro()),
                    icon: const Icon(Icons.ios_share_rounded, size: 17),
                    label: const Text(
                      'Send as ChordPro',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (kIsWeb) ...<Widget>[
            const SizedBox(height: 7),
            const Text(
              key: Key('chordpro_web_note'),
              'Sending the song as a ChordPro file needs the app. You can '
              'still print from here.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                height: 1.35,
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            if (widget.onReviewLyrics != null)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onReviewLyrics,
                  icon: const Icon(Icons.edit_note_rounded),
                  label: const Text('Review lyrics'),
                ),
              ),
            if (widget.onReviewLyrics != null && widget.onOpenLive != null)
              const SizedBox(width: 10),
            if (widget.onOpenLive != null)
              Expanded(
                child: FilledButton.icon(
                  key: const Key('open_synced_live'),
                  onPressed: widget.onOpenLive,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.ink,
                  ),
                  icon: const Icon(Icons.present_to_all_rounded),
                  label: const Text('Synced Live'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Sheet or chart, as a pair of small segments rather than a Material
/// SegmentedButton — that control is built for full-width choices and would
/// dominate a row it's sharing with four other things.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});

  final SongSheetView view;
  final ValueChanged<SongSheetView>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _segment(SongSheetView.sheet, 'Sheet'),
          _segment(SongSheetView.chart, 'Chart'),
        ],
      ),
    );
  }

  Widget _segment(SongSheetView value, String label) {
    final selected = view == value;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onChanged == null || selected ? null : () => onChanged!(value),
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: onChanged == null
                  ? AppColors.muted
                  : selected
                      ? AppColors.gold
                      : AppColors.text,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}
