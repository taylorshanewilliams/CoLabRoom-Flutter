import 'dart:async';
import 'dart:math' as math;

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/features/workspace/chord_editor_sheet.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/musician_song_sheet.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter/material.dart';

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
  int _transpose = 0;
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
  }

  @override
  void didUpdateWidget(covariant SongSheetPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bundle, widget.bundle)) {
      _bundle = widget.bundle;
      _chartRows = null;
    }
  }

  void _toggleChordEditing() {
    setState(() {
      _editingChords = !_editingChords;
      _showChords = true;
      if (_editingChords) _transpose = 0;
    });
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
        // with the cues it was built from.
        _chartRows = null;
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
    final transposeLabel = _transpose == 0
        ? 'Original key'
        : _transpose > 0
            ? '+$_transpose semitones'
            : '$_transpose semitones';
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
                    onPressed: _editingChords
                        ? null
                        : () => setState(() {
                              _transpose =
                                  (_transpose - 1).clamp(-11, 11).toInt();
                            }),
                    icon: const Icon(Icons.remove_rounded, size: 18),
                  ),
                  Expanded(
                    child: Text(
                      transposeLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Transpose up',
                    onPressed: _editingChords
                        ? null
                        : () => setState(() {
                              _transpose =
                                  (_transpose + 1).clamp(-11, 11).toInt();
                            }),
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
            transpose: _transpose,
            fontScale: _fontScale,
          )
        else
          MusicianSongSheet(
            title: widget.project.title,
            lines: buildMusicianSheetLines(widget.project, _bundle, ignoreWorkspaceLyrics: true),
            musicalKey: _bundle.reference?.musicalKey,
            transpose: _transpose,
            fontScale: _fontScale,
            showChords: _showChords,
            editableChords: _editingChords && !_savingChord,
            onEditChord: (line, chord, wordIndex) {
              unawaited(_editChord(line, chord, wordIndex));
            },
            onAddChord: (line, wordIndex) {
              unawaited(_addChord(line, wordIndex));
            },
          ),
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
