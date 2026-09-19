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
import 'package:colabroom/features/workspace/sung_and_written_sheet.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/chord_repeats.dart';
import 'package:colabroom/services/horn_reading.dart';
import 'package:colabroom/services/number_reading.dart';
import 'package:colabroom/services/rehearsal_letters.dart';
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
    this.onSetKey,
    this.onSetBarOne,
    this.onUseSung,
    this.analysisService,
    super.key,
  });

  final SongProject project;
  final SongAnalysisBundle bundle;
  final VoidCallback? onReviewLyrics;
  final VoidCallback? onOpenLive;
  final ValueChanged<SongAnalysisBundle>? onAnalysisChanged;

  /// Takes what was sung into one written line, from the sung-and-written
  /// sheet. Null for somebody the room only lets look, which leaves that
  /// sheet something to read (Every Musician, Same Song, 17 September 2026,
  /// slice 37).
  final UseSungLine? onUseSung;

  /// Where corrections are written. Null for the real one; a test hands in
  /// one that remembers instead.
  final SongAnalysisService? analysisService;

  /// Says what key the band is really in, or hands the song back to the
  /// detected key with a null.
  ///
  /// Null on a panel with nowhere to write it, and for somebody the room only
  /// lets look, which leaves the key sheet a reference. The write lives with
  /// the caller because it goes through the repository and has to refresh
  /// the song afterwards, and so does the question of who may make it; a
  /// refusal is thrown back here and said on the key sheet, where the person
  /// tapped.
  final Future<void> Function(String? key)? onSetKey;

  /// Says which downbeat of the analysis is bar 1, or hands the song back to
  /// the detected bars with a null.
  ///
  /// The other shared fact, written the same way and by the same two people
  /// (0161). Null on a panel with nowhere to write it, and for somebody the
  /// room only lets look — long-pressing a bar of the chart then does nothing
  /// at all, rather than offering a change the room will refuse.
  final Future<void> Function(int? downbeat)? onSetBarOne;

  @override
  State<SongSheetPanel> createState() => _SongSheetPanelState();
}

class _SongSheetPanelState extends State<SongSheetPanel> {
  late final SongAnalysisService _service =
      widget.analysisService ?? SongAnalysisService();

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

  /// Which fret this person has the capo on, kept on this device (see
  /// SongCapoStore). It moves the chords and not the singing.
  int _capo = 0;
  bool _capoTouched = false;

  /// Letters, numbers or numerals, and which note a minor song is counted
  /// from (see SongNumbersStore and MinorNumbersStore).
  NumberReading _numbers = NumberReading.letters;
  bool _numbersTouched = false;
  double _fontScale = 1;
  bool _showChords = true;
  bool _editingChords = false;
  bool _savingChord = false;

  /// The correction just made, and where else the passage it fixed comes
  /// round — held while the one line asking about it is on screen.
  ///
  /// It is an offer attached to the action, not a banner: it appears in the
  /// editing box the moment a chord is saved, and anything that moves on from
  /// that correction — another edit, a nudge, Done, the chart, a bundle from
  /// outside — takes it away without applying it. Declining is the default in
  /// every direction (Every Musician, Same Song, 17 September 2026).
  ChordRepeatOffer? _repeatOffer;

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
          // Where the band counts from, so the margin agrees with the part
          // somebody is holding (0161).
          barOne: widget.project.barOne,
        ),
      );

  @override
  void initState() {
    super.initState();
    _bundle = widget.bundle;
    unawaited(_loadTranspose());
    unawaited(_loadReading());
    unawaited(_loadCapo());
    unawaited(_loadNumbers());
  }

  @override
  void didUpdateWidget(covariant SongSheetPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent hands every correction straight back (onAnalysisChanged,
    // its setState, this bundle), so a bundle the panel is already holding
    // is not news. It used to be compared with the last widget's bundle
    // alone, which read that echo as a change and would have taken the
    // repeat offer away in the same frame it was made. A host that does not
    // echo rebuilds for its own reasons with the bundle it always had, and
    // that is not news either: it must not put a correction back the way it
    // was. Only a bundle the parent changed and the panel has not seen — a
    // re-analysis, a sync from elsewhere — resets what was built from the
    // old one, and the offer goes with it: the correction it asked about may
    // not be there any more.
    if (!identical(widget.bundle, oldWidget.bundle) &&
        !identical(widget.bundle, _bundle)) {
      _bundle = widget.bundle;
      _chartRows = null;
      _lines = null;
      _repeatOffer = null;
    }
    // Where bar 1 is decides every number on the chart and in the sheet's
    // gutter, and both are worked out once per bundle — so a song that has
    // just been told where it starts has to have them worked out again.
    if (oldWidget.project.barOne != widget.project.barOne) {
      _chartRows = null;
      _lines = null;
    }
    if (oldWidget.project.id != widget.project.id) {
      _transpose = 0;
      _transposeTouched = false;
      _reading = HornReading.concert;
      _readingTouched = false;
      _capo = 0;
      _capoTouched = false;
      _numbers = NumberReading.letters;
      _numbersTouched = false;
      unawaited(_loadTranspose());
      unawaited(_loadReading());
      unawaited(_loadCapo());
      unawaited(_loadNumbers());
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

  Future<void> _loadCapo() async {
    final projectId = widget.project.id;
    final kept = await SongCapoStore.load(projectId);
    if (!mounted || _capoTouched || widget.project.id != projectId) return;
    if (kept != _capo) setState(() => _capo = kept);
  }

  Future<void> _loadNumbers() async {
    final projectId = widget.project.id;
    final style = await SongNumbersStore.load(projectId);
    final minor = await MinorNumbersStore.load();
    if (!mounted || _numbersTouched || widget.project.id != projectId) return;
    final kept = NumberReading(style: style, minor: minor);
    if (kept != _numbers) setState(() => _numbers = kept);
  }

  void _chooseReading(HornReading reading) {
    setState(() {
      _readingTouched = true;
      _reading = reading;
    });
    unawaited(SongReadingStore.save(widget.project.id, reading));
  }

  void _chooseCapo(int capo) {
    setState(() {
      _capoTouched = true;
      _capo = capo;
    });
    unawaited(SongCapoStore.save(widget.project.id, capo));
  }

  void _chooseNumbers(NumberReading numbers) {
    setState(() {
      _numbersTouched = true;
      _numbers = numbers;
    });
    unawaited(SongNumbersStore.save(widget.project.id, numbers.style));
    // The convention is not per song -- somebody who reads 6- reads 6-
    // everywhere -- so it is saved once and read back on every song.
    unawaited(MinorNumbersStore.save(numbers.minor));
  }

  /// Where the 1 is, said to the room.
  ///
  /// The only thing on this panel that is not personal, so it is the only one
  /// that can be refused: somebody who can only look cannot move everybody
  /// else's numbers. A refusal is a sentence, not a silence — and it is
  /// handed back to the key sheet to say, because that is where the person
  /// tapped and a snackbar here would sit underneath it (review, 17
  /// September 2026).
  Future<String?> _sayTheKey(String? key) async {
    final write = widget.onSetKey;
    if (write == null) return null;
    try {
      await write(key);
      return null;
    } catch (error) {
      return reportAndDescribe(
        error,
        service: 'app',
        stage: 'set_song_key',
        route: 'Song sheet',
        projectId: widget.project.id,
      );
    }
  }

  /// Where bar 1 is, said by holding down a bar of the chart (0161).
  ///
  /// The same shape as the key above and for the same reason: this is the
  /// other thing on this panel that belongs to the room rather than to the
  /// phone, so it is the other one that can come back refused — offline, on a
  /// build older than the migration, or after being made a viewer somewhere
  /// else. The refusal is a sentence here rather than a sentence handed back,
  /// because the long press closes its own sheet before the write starts and
  /// there is nothing left to say it on (review, 18 September 2026).
  Future<void> _sayBarOne(int? downbeat) async {
    final write = widget.onSetBarOne;
    if (write == null) return;
    try {
      await write(downbeat);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(
          error,
          service: 'app',
          stage: 'set_bar_one',
          route: 'Song sheet',
          projectId: widget.project.id,
        )),
      ));
    }
  }

  /// Whether there are two sets of words to put side by side: lines somebody
  /// typed, and a transcript with a time on every word. With either missing
  /// the song offers nothing — the writing space already says where the
  /// words are when the page is empty and the sheet has them.
  bool get _hasSungAndWritten =>
      visibleMusicianLyrics(widget.project).isNotEmpty &&
      (_bundle.reference?.transcriptWords.isNotEmpty ?? false);

  void _openSungAndWritten() {
    unawaited(showSungAndWritten(
      context,
      project: widget.project,
      bundle: _bundle,
      onUseSung: widget.onUseSung,
    ));
  }

  /// The song's own key: what the band said it is in, or failing that what
  /// the analysis found, or null when neither exists.
  ///
  /// Everything on this page reads the key through here, so the sheet, the
  /// chart, the badge and both exports cannot end up half in one key and
  /// half in the other (Every Musician, Same Song, 17 September 2026).
  String? get _songKey =>
      widget.project.songKey(_bundle.reference?.musicalKey);

  /// Whether the key above is the band's answer rather than the analysis's.
  bool get _keyOverridden =>
      (widget.project.keyOverride ?? '').trim().isNotEmpty;

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
      numbers: _shownNumbers,
      onNumbers: _chooseNumbers,
      capo: _shownCapo,
      onCapo: _chooseCapo,
      songKey: key,
      overridden: _keyOverridden,
      onKey: widget.onSetKey == null ? null : _sayTheKey,
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

  /// The capo and the number reading, set aside while chords are being
  /// corrected for the same reason: a chord typed into the editor is saved as
  /// written, and it has to be read against what is stored rather than
  /// against a shape four frets down or a number.
  int get _shownCapo => _editingChords ? 0 : _capo;

  NumberReading get _shownNumbers =>
      _editingChords ? NumberReading.letters : _numbers;

  void _toggleChordEditing() {
    setState(() {
      _editingChords = !_editingChords;
      _showChords = true;
      _repeatOffer = null;
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

  /// The page: the sheet's lines with the recording's section names folded
  /// in, each heading carrying its rehearsal letter, so the page carries the
  /// shape of the song and not just its lines.
  ///
  /// The screen reads this and so do both exports. It used to be the exports
  /// alone, which meant the printed page had the shape of the song on it and
  /// the screen somebody printed it from did not — and there was nowhere on
  /// the sheet for a letter to sit beside (Every Musician, Same Song, 17
  /// September 2026). Every line that is not a heading is the same object
  /// either way, so a chord tapped on screen is still the chord the editor
  /// is handed.
  List<MusicianSheetLine> _sheetPage() => ChordSheetExport.withSectionNames(
        _sheetLines(),
        _bundle.reference?.structureSections ?? const <StructureSection>[],
      );

  /// The song's whole form on one line, for the top of the chart and the top
  /// of the printed page. Empty when the recording has no sections.
  String _arrangement() => arrangementCode(rehearsalLetters(
        _bundle.reference?.structureSections ?? const <StructureSection>[],
      ));

  /// Both exports carry this person's own key and deliberately not their
  /// reading.
  ///
  /// A printed chart and a ChordPro file leave the device and get read by
  /// other people, and both of them name the key at the top — a part written
  /// for B♭ and labelled "Key of A" would put the whole band a tone out. A
  /// reading is the one thing here that is personal to this device (Every
  /// Musician, Same Song, 17 September 2026), so what is exported is the
  /// song as the band plays it.
  Future<void> _printChart() async {
    try {
      await ChordSheetExport.printChart(
        project: widget.project,
        lines: _sheetPage(),
        transpose: _shownTranspose,
        musicalKey: _songKey,
        bpm: _bundle.reference?.bpm,
        arrangement: _arrangement(),
      );
    } catch (error) {
      _saySomethingWentWrong(error);
    }
  }

  Future<void> _sendChordPro() async {
    try {
      await ChordSheetExport.shareChordPro(
        project: widget.project,
        lines: _sheetPage(),
        transpose: _shownTranspose,
        musicalKey: _songKey,
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
      _repeatOffer = null;
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
    // A new correction is a new question; the last one's offer is over.
    if (_repeatOffer != null) setState(() => _repeatOffer = null);
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
      ChordRepeatOffer? offer;
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

        final savedEnd = math.max(startMs + 120, endMs).toInt();
        // What read at that moment before the correction: the detected chord
        // being replaced, or the one still ringing under a word that had
        // none. A repeat is only the same passage if it reads the same there.
        final before = existing?.chord ??
            chordSoundingAt(_bundle.chordCues, startMs)?.chord;
        updated = await _service.saveManualChordCue(
          projectId: widget.project.id,
          cueId: existing?.id,
          originalStartMs: existing?.startMs,
          originalChord: existing?.chord,
          chord: result.chord,
          startMs: startMs,
          endMs: savedEnd,
        );
        // The correction is saved where it was made. Where else the passage
        // comes round is a question, asked below, and until it is answered
        // nothing else has changed.
        offer = findChordRepeats(
          bundle: updated,
          chord: result.chord,
          originalChord: before,
          startMs: startMs,
          endMs: savedEnd,
          originalStartMs: existing?.startMs,
        );
      }
      if (!mounted) return;
      setState(() {
        _bundle = updated;
        _repeatOffer = offer;
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

  /// Yes: the same correction in every repeat the offer found.
  ///
  /// Every repeat's bars change, so the cached grid goes the way it does for
  /// a single correction (it is empty by now in practice, because the
  /// correction that raised the offer emptied it and the chart view takes
  /// the offer away, but the rule is stated here so it does not depend on
  /// that), and the sheet's lines with it, which are on screen under the
  /// question and would otherwise keep showing one Am; the chart and the
  /// sheet are both rebuilt from the bundle that comes back, and Perform
  /// gets that bundle through onAnalysisChanged and builds its own lines
  /// from it when it opens, so all three read the same chord in the same
  /// bars.
  Future<void> _applyToRepeats() async {
    final offer = _repeatOffer;
    if (offer == null || _savingChord) return;
    setState(() => _savingChord = true);
    try {
      final updated = await _service.applyChordToRepeats(
        projectId: widget.project.id,
        chord: offer.chord,
        targets: offer.targets,
      );
      if (!mounted) return;
      setState(() {
        _bundle = updated;
        _repeatOffer = null;
        _chartRows = null;
        _lines = null;
      });
      widget.onAnalysisChanged?.call(updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Could not change the other parts: $error'),
          ),
        );
    } finally {
      if (mounted) setState(() => _savingChord = false);
    }
  }

  /// No: the one place already changed is the only place that changes.
  void _declineRepeats() => setState(() => _repeatOffer = null);

  @override
  Widget build(BuildContext context) {
    final transpose = _shownTranspose;
    final sheetLines = _sheetPage();
    final reading = _shownReading;
    final numbers = _shownNumbers;
    // A capo is a guitar answer about the key the band is in, so it is only
    // ever in play in concert pitch -- see the capo rows in the key sheet.
    final capo = reading == HornReading.concert ? _shownCapo : 0;
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
    final readingLine = reading != HornReading.concert
        ? _view == SongSheetView.chart && songKey != null
            ? keyAsRead(songKey, transpose: transpose, reading: reading)
            : 'For ${reading.label}'
        // The capo needs saying on the chart for the same reason: the chords
        // in the bars came down four frets and the chart has no badge to say
        // so. On the sheet the badge already says it.
        : capo > 0 && _view == SongSheetView.chart && songKey != null
            ? capoLine(songKey, capo: capo, transpose: transpose)
            : null;
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
                                _repeatOffer = null;
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
                  child: _savingChord
                      ? const Text(
                          'Saving chord correction…',
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 10.5,
                            height: 1.35,
                          ),
                        )
                      : _repeatOffer != null
                          ? _RepeatOfferLine(
                              question: _repeatOffer!.question,
                              onEverywhere: _applyToRepeats,
                              onHereOnly: _declineRepeats,
                            )
                          : const Text(
                              'Tap a chord to correct or remove it. Tap any lyric word to add a chord or move one there.',
                              style: TextStyle(
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
            // person's key, their instrument's transposition on top, and
            // their capo taken back off again. No words on a chart, so
            // nothing here is sung and the capo needs no exception.
            transpose: transpose + reading.semitones - capo,
            numbers: numbers,
            fontScale: _fontScale,
            // The shape of the song, at the top of the page.
            arrangement: _arrangement(),
            // The song, so a tapped chord can say where it sits in it rather
            // than only what it is.
            musicalKey: songKey,
            // And the other half of the chart's own facts: whether bar 1 has
            // been moved, and whether this person may move it (0161).
            barOneSaid: widget.project.barOneDownbeat != null,
            onSayBarOne: _editingChords || widget.onSetBarOne == null
                ? null
                : _sayBarOne,
          )
        else
          Focus(
            focusNode: _sheetFocus,
            onKeyEvent: _onKey,
            child: MusicianSongSheet(
            title: widget.project.title,
            lines: sheetLines,
            musicalKey: songKey,
            transpose: transpose,
            reading: reading,
            onReading: _editingChords ? null : _chooseReading,
            numbers: numbers,
            onNumbers: _editingChords ? null : _chooseNumbers,
            capo: capo,
            onCapo: _editingChords ? null : _chooseCapo,
            keyOverridden: _keyOverridden,
            onKey: _editingChords || widget.onSetKey == null
                ? null
                : _sayTheKey,
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
        // What the recording says beside what is on the page, line by line.
        // Its own row, in the same voice as the exports above it: it is not
        // a way of reading the sheet, so it is not a segment, and it is not
        // a correction, so it is not in the editing box.
        if (_hasSungAndWritten) ...<Widget>[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('sung_and_written'),
            onPressed: _openSungAndWritten,
            icon: const Icon(Icons.hearing_rounded, size: 17),
            label: const Text(
              'Sung and written',
              style: TextStyle(fontSize: 12),
            ),
          ),
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

/// The one line that asks: "Also in the other two choruses?", a yes, and a
/// no that says what it does.
///
/// In the editing box in place of its instruction, because the correction
/// was made from there and this is the last step of it — not a snackbar
/// sliding up over the words, and not a second sheet to dismiss. Both
/// answers are the same size and the same weight: neither is the one you
/// are supposed to press.
class _RepeatOfferLine extends StatelessWidget {
  const _RepeatOfferLine({
    required this.question,
    required this.onEverywhere,
    required this.onHereOnly,
  });

  final String question;
  final VoidCallback onEverywhere;
  final VoidCallback onHereOnly;

  @override
  Widget build(BuildContext context) {
    final compact = TextButton.styleFrom(
      foregroundColor: AppColors.gold,
      minimumSize: const Size(0, 30),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    // Size and weight on the labels, where they merge into the theme's
    // style, and never on the button (see button_labels_keep_their_font).
    const label = TextStyle(fontSize: 11, fontWeight: FontWeight.w800);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            question,
            key: const Key('repeat_correction_question'),
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 10.5,
              height: 1.35,
            ),
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          key: const Key('repeat_correction_here_only'),
          style: compact,
          onPressed: onHereOnly,
          child: const Text('Just here', style: label),
        ),
        TextButton(
          key: const Key('repeat_correction_everywhere'),
          style: compact,
          onPressed: onEverywhere,
          child: const Text('Yes', style: label),
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
