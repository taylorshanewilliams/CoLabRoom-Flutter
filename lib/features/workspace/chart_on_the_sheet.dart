import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/brought_chart.dart';
import '../../services/horn_reading.dart';
import '../../services/number_reading.dart';
import '../../services/user_facing_error.dart';
import 'bring_a_chart_flow.dart';
import 'brought_chart_view.dart';
import 'music_reference_sheets.dart';
import 'musician_sheet_logic.dart'
    show capoLine, chordAsPlayed, keyAsPlayed, keyAsRead;
import 'song_reading_store.dart';
import 'song_transpose_store.dart';

/// The chart, where the chart goes.
///
/// A song with no recording had nowhere at all to hold a chord: chords in
/// this app are timed against an analysis, so a song nobody has recorded had
/// no chords and no way to get any (Taylor, 19 September 2026). This is that
/// place, and it is on the song's own sheet rather than behind a menu — the
/// empty state is the door.
///
/// It is always here. A song with a chart shows it and offers to replace it;
/// a song without one says what would be here and how to put it there. A door
/// that only exists once something already exists is a door nobody finds.
class ChartOnTheSheet extends StatefulWidget {
  const ChartOnTheSheet({
    required this.project,
    required this.canEdit,
    this.onSetKey,
    super.key,
  });

  final SongProject project;

  /// Whether this person may bring or replace the chart: the room's owner or
  /// an editor, the same two 0168 lets through. Somebody who can only look
  /// reads the chart and is not offered a control the room would refuse.
  final bool canEdit;

  /// Says what key the song is in (0144), for the owner and editors and
  /// nobody else — null for somebody who may only read.
  ///
  /// A song with no recording has no key badge and no song sheet, so without
  /// this the key of a chart that does not state one could never be said at
  /// all — and the capo and the numbers, both counted from a key, would be
  /// unreachable on exactly the songs this feature exists for (review, 19
  /// September 2026).
  final Future<void> Function(String? key)? onSetKey;

  @override
  State<ChartOnTheSheet> createState() => _ChartOnTheSheetState();
}

class _ChartOnTheSheetState extends State<ChartOnTheSheet> {
  SongChart? _kept;
  BroughtChart? _read;
  bool _loading = true;

  /// Whether the room was asked and could not answer.
  ///
  /// It matters because bringing a chart writes over whatever is there and
  /// there is no history to get the old one back from. A select that timed
  /// out on a train looks exactly like a song with no chart, so somebody
  /// would paste a rough version over the careful one the owner typed out
  /// last week (review, 19 September 2026). After a failure the offer is to
  /// look again, not to replace something nobody has seen.
  bool _failed = false;

  /// The look that is going on now, so that bringing a chart can wait for it
  /// rather than race it. Tapping the moment the page appears must not decide
  /// "there is nothing here" from a question that has not come back yet.
  Future<void>? _looking;

  /// The readings, kept on this device and never shared with the room — the
  /// same four the song sheet keeps, read from the same stores, so a person
  /// who moved this song down two on the sheet finds their chart down two.
  int _transpose = 0;
  bool _transposeTouched = false;
  HornReading _reading = HornReading.concert;
  bool _readingTouched = false;
  int _capo = 0;
  bool _capoTouched = false;
  NumberReading _numbers = NumberReading.letters;
  bool _numbersTouched = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadTranspose());
    unawaited(_loadReading());
    unawaited(_loadCapo());
    unawaited(_loadNumbers());
    // In hand before anybody taps a chord: the sheet a tap opens is built in
    // the same frame as the tap.
    unawaited(SimplerShapesStore.warm());
    unawaited(ShapeReadingStore.warm());
    unawaited(LeftHandedStore.warm());
    // Warmed so that [SongTransposeStore.held] answers for this song and not
    // only for songs somebody has already changed in this session — see
    // [_readingChangedElsewhere], which has to read it without waiting.
    unawaited(SongTransposeStore.warm());
    unawaited(SongReadingStore.warm());
    ShapeReadingStore.changes.addListener(_shapesChanged);
    // A song that has a recording as well as a chart draws two pages on one
    // screen, each with its own controls — and both read this person's one
    // kept key. Without these the chart would go on saying "Original key"
    // after the sheet above it had been taken down two, which is the same
    // song printed two ways on one screen.
    SongTransposeStore.changes.addListener(_readingChangedElsewhere);
    SongReadingStore.changes.addListener(_readingChangedElsewhere);
  }

  @override
  void dispose() {
    ShapeReadingStore.changes.removeListener(_shapesChanged);
    SongTransposeStore.changes.removeListener(_readingChangedElsewhere);
    SongReadingStore.changes.removeListener(_readingChangedElsewhere);
    super.dispose();
  }

  void _shapesChanged() {
    if (mounted) setState(() {});
  }

  /// Something changed how this song is read, here or on the sheet above.
  ///
  /// Taken from the store's own held value rather than re-read from the disk.
  /// Both stores tick *before* they write, on purpose — so that the screen
  /// agrees with the choice even when the disk refuses it — and a disk read
  /// started here would race that write and put the old answer back.
  ///
  /// The capo and the numbers are read again the slow way, which is safe
  /// because neither of them ticks: whatever is on the disk for them was
  /// written before this tick, not during it.
  void _readingChangedElsewhere() {
    if (!mounted) return;
    final transpose = SongTransposeStore.held(widget.project.id);
    final reading = SongReadingStore.held(widget.project.id);
    if (transpose != _transpose || reading != _reading) {
      setState(() {
        _transpose = transpose;
        _reading = reading;
      });
    }
    _capoTouched = false;
    _numbersTouched = false;
    unawaited(_loadCapo());
    unawaited(_loadNumbers());
  }

  /// Asks the room whether this song has a chart, and remembers the asking.
  Future<void> _load() {
    final work = _lookForIt();
    _looking = work;
    return work;
  }

  Future<void> _lookForIt() async {
    final repository = BetaScope.of(context, listen: false).repository;
    if (mounted && !_loading) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final kept = await repository.broughtChart(widget.project.id);
      if (!mounted) return;
      setState(() {
        _kept = kept;
        _read = kept == null ? null : readChart(kept.body);
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      // Nothing about this song stops working because one extra row did not
      // arrive, and a page full of error is worse than a page with a door —
      // but the door that would be here writes over whatever it could not
      // see, so what is offered after a failure is looking again.
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _loadTranspose() async {
    final kept = await SongTransposeStore.load(widget.project.id);
    if (!mounted || _transposeTouched) return;
    if (kept != _transpose) setState(() => _transpose = kept);
  }

  Future<void> _loadReading() async {
    final kept = await SongReadingStore.load(widget.project.id);
    if (!mounted || _readingTouched) return;
    if (kept != _reading) setState(() => _reading = kept);
  }

  Future<void> _loadCapo() async {
    final kept = await SongCapoStore.load(widget.project.id);
    if (!mounted || _capoTouched) return;
    if (kept != _capo) setState(() => _capo = kept);
  }

  Future<void> _loadNumbers() async {
    final style = await SongNumbersStore.load(widget.project.id);
    final minor = await MinorNumbersStore.load();
    if (!mounted || _numbersTouched) return;
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
    unawaited(MinorNumbersStore.save(numbers.minor));
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

  /// A capo says nothing to a pianist or a bass player, so the chords go back
  /// to concert pitch when the shapes being read are not a fretting hand's.
  int get _capoHere =>
      _reading == HornReading.concert && ShapeReadingStore.held.takesACapo
          ? _capo
          : 0;

  /// The key this chart is read in.
  ///
  /// What the chart says about itself first, because that is the page in
  /// front of the person; the band's key (0144) behind it, because a room
  /// that has said what key the song is in has said it about the song and not
  /// only about its recording. Read through [SongProject.songKey] rather than
  /// off `keyOverride`, so nothing here counts numbers from a key the rest of
  /// the app is not using (review, 19 September 2026).
  String? get _key {
    final chart = _read;
    return (chart == null ? null : chartKey(chart)) ??
        widget.project.songKey(null);
  }

  /// Says the key for the whole room, and hands a refusal back to be said on
  /// the sheet the person tapped in rather than underneath it.
  Future<String?> _sayTheKey(String? key) async {
    final write = widget.onSetKey;
    if (write == null) return null;
    try {
      await write(key);
      if (mounted) setState(() {});
      return null;
    } catch (error) {
      return reportAndDescribe(
        error,
        service: 'app',
        stage: 'set_song_key',
        route: 'Bring a chart',
        projectId: widget.project.id,
      );
    }
  }

  Future<void> _bring() async {
    // Never over a chart nobody has seen. The look that is going on now
    // answers first, so a tap the moment the page appears cannot decide there
    // is nothing here from a question that has not come back (review, 19
    // September 2026).
    await _looking;
    if (!mounted) return;
    if (_failed) {
      unawaited(_load());
      return;
    }
    final scope = BetaScope.of(context, listen: false);
    final chart = await showBringAChartFlow(
      context,
      projectId: widget.project.id,
      songTitle: widget.project.title,
      repository: scope.repository,
      replacing: _kept != null,
    );
    if (chart == null || !mounted) return;
    setState(() {
      _read = chart;
      _kept = SongChart(
        projectId: widget.project.id,
        body: chart.chordPro,
        broughtAt: DateTime.now(),
        broughtBy: scope.repository.currentUserId,
      );
    });
    // Back from the database rather than trusted from here, so what is on
    // screen is what the room will see. A failure leaves what was just kept
    // on screen, which is the same chart.
    unawaited(_load());
  }

  void _openReadingChoice() {
    final key = _key;
    unawaited(showReadingChoice(
      context,
      keyLabel: key == null ? null : keyAsPlayed(key, _transpose),
      reading: _reading,
      onReading: _chooseReading,
      numbers: _numbers,
      onNumbers: _chooseNumbers,
      // The capo somebody has kept, not the one the page is drawn with: a
      // pianist reading the same song still has a capo on their guitar, and
      // the picker has to open on the fret they chose. The page is what
      // leaves it out of the arithmetic — see [_capoHere].
      capo: _capo,
      onCapo: _chooseCapo,
      chords: <String>[
        for (final chord in _read?.chordsUsed ?? const <String>[])
          chordAsPlayed(chord, transpose: _transpose, key: key),
      ],
      songKey: key,
      overridden: widget.project.keyOverride != null,
      onKey: widget.onSetKey == null ? null : _sayTheKey,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final chart = _read;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (chart == null)
          _NoChartYet(
            loading: _loading,
            failed: _failed,
            canEdit: widget.canEdit,
            // After a failure the only honest offer is to ask the room again.
            onBring: _failed
                ? () => unawaited(_load())
                : widget.canEdit
                    ? () => unawaited(_bring())
                    : null,
          )
        else ...<Widget>[
          _HowYouReadIt(
            transpose: _transpose,
            reading: _reading,
            capo: _capoHere,
            musicalKey: _key,
            onShift: _shiftTranspose,
            onOpen: _openReadingChoice,
          ),
          const SizedBox(height: 10),
          BroughtChartView(
            chart: chart,
            title: widget.project.title,
            transpose: _transpose,
            capo: _capoHere,
            reading: _reading,
            numbers: _numbers,
            fontScale: 1,
            musicalKey: _key,
            language: widget.project.language,
          ),
          if (widget.canEdit) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('replace_the_chart'),
                onPressed: () => unawaited(_bring()),
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('Replace the chart'),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// The place the chart goes, before there is one.
///
/// Not a banner and not an advert: it is where the chart is drawn, saying
/// what would be drawn there. Somebody who can only look is told the same
/// thing without being offered a button the room would refuse.
class _NoChartYet extends StatelessWidget {
  const _NoChartYet({
    required this.loading,
    required this.failed,
    required this.canEdit,
    required this.onBring,
  });

  final bool loading;

  /// The room was asked and did not answer, so whether there is a chart here
  /// is not known — and offering to bring one would offer to write over it.
  final bool failed;
  final bool canEdit;
  final VoidCallback? onBring;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.03),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.24)),
      ),
      child: InkWell(
        key: const Key('bring_a_chart_door'),
        onTap: onBring,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.menu_book_rounded,
                  color: AppColors.cyan, size: 22),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      failed
                          ? 'Could not look for the chart'
                          : canEdit
                              ? 'Bring a chart'
                              : 'No chart yet',
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      failed
                          ? 'Tap to look again.'
                          : loading
                              ? 'Looking for one…'
                              : canEdit
                                  ? 'Paste or open a chart you already have, '
                                      'and read it here in your own key.'
                                  : 'When somebody in this room brings one, '
                                      'it will be here.',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How this person is reading the chart, and the two buttons that change it.
///
/// The same control the song sheet has, in the same words, because it does
/// the same thing: a chart with no recording behind it still has to come down
/// two for a singer and up three for a trumpet.
class _HowYouReadIt extends StatelessWidget {
  const _HowYouReadIt({
    required this.transpose,
    required this.reading,
    required this.capo,
    required this.musicalKey,
    required this.onShift,
    required this.onOpen,
  });

  final int transpose;
  final HornReading reading;
  final int capo;
  final String? musicalKey;
  final ValueChanged<int> onShift;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final base = transpose == 0
        ? 'Original key'
        : transpose > 0
            ? '+$transpose semitones'
            : '$transpose semitones';
    // The chart has no key badge, so the part somebody is reading for and the
    // capo they are on are named here or nowhere.
    final under = reading != HornReading.concert
        ? musicalKey != null
            ? keyAsRead(musicalKey!, transpose: transpose, reading: reading)
            : 'For ${reading.label}'
        : capo > 0 && musicalKey != null
            ? capoLine(musicalKey!, capo: capo, transpose: transpose)
            : capo > 0
                ? 'Capo $capo'
                : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Transpose down',
            onPressed: () => onShift(-1),
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          Expanded(
            child: Semantics(
              button: true,
              child: InkWell(
                key: const Key('chart_read_as'),
                borderRadius: BorderRadius.circular(8),
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        base,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationStyle: TextDecorationStyle.dotted,
                          decorationColor: AppColors.muted,
                        ),
                      ),
                      if (under != null)
                        Text(
                          under,
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
            onPressed: () => onShift(1),
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
