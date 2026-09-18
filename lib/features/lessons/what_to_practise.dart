import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/practice_mark.dart';
import '../../domain/song_analysis_models.dart';
import '../../domain/song_brief.dart';
import '../workspace/practice_marks.dart';
import '../workspace/practice_rules.dart';
import 'leaving_practice.dart' show PracticeTarget, practiceTargets;

/// What to practise, and where it is (migration 0150).
///
/// Every Musician, Same Song, 17 September 2026, slice 20: the brief that
/// rides with a song a teacher sends. Slice 19 put the song in the student's
/// lesson room; this says what to do with it. A passage, a speed, a few
/// things the teacher will be listening for, and when by, in their own
/// words. It lands on the student's Home as the practice card they already
/// know, and Practise opens the song already looping that passage at that
/// speed.
///
/// What it never is. There is no score here, no field for a number, no tick
/// and no tally, and none is coming: once a number exists somebody will ask
/// to see it. When it is due is a phrase, never a date, so nothing counts
/// down and nothing is ever late. Nobody is pushed or reminded. And the
/// teacher is never shown whether the card was opened: what reaches them is
/// what the student chooses to send.
///
/// Kept out of the screens so the words and the rules can be read in a test,
/// the same reason leaving_practice and sending_a_song are their own files.

/// What the row, the sheet and the card are all called.
const String whatToPractiseLabel = 'What to practise';

/// The passage, the speed and when by, in one line: "Bars 1–16 at ¾ · before
/// Thursday". The words for when are the teacher's own and are said as they
/// typed them.
String briefSaid({required PracticePart part, String? dueWords}) {
  final due = (dueWords ?? '').trim();
  return <String>[practiceSaid(part), if (due.isNotEmpty) due].join(' · ');
}

/// The same line for a brief that has been sent.
String songBriefSaid(SongBrief brief) =>
    briefSaid(part: brief.part, dueWords: brief.dueWords);

/// And for one a teacher has filled in and not sent yet.
String briefToSendSaid(BriefToSend brief) => briefSaid(
      part: PracticePart(
        label: brief.passage,
        rate: brief.rate,
        seconds: 0,
        startMs: brief.startMs,
        endMs: brief.endMs,
      ),
      dueWords: brief.dueWords,
    );

/// What sits above the song's name: whose words these are. The student
/// reads the teacher's name, as a lesson's card says it; the teacher reads
/// that it is their own.
String briefFrom(SongBrief brief, {required String me}) =>
    brief.teacherId == me ? 'What you asked for' : 'From ${brief.teacherName}';

/// The briefs asked of this person, which are the ones Home makes cards of.
/// A teacher gets no card for what they asked of somebody else: it is not
/// theirs to practise.
List<SongBrief> briefsAskedOf(String me, Iterable<SongBrief> briefs) => <SongBrief>[
      if (me.isNotEmpty)
        for (final brief in briefs)
          if (brief.studentId == me) brief,
    ];

/// What there is to point at inside a song that is about to be sent.
///
/// The passage and the speed mean something only where the student's
/// Perform will have the recording to move against. That takes two things:
/// a sheet on the teacher's song (songHasASheet in leaving_practice, the
/// question Perform itself asks), and a recording that travels with the
/// copy, which is a song marked ours or public domain (0142, 0149). Without
/// both, the copy opens whole at its own speed whatever the card said, so
/// the sheet offers the whole song and says why, once.
@immutable
class SongToPointAt {
  const SongToPointAt({
    this.sections = const <StructureSection>[],
    this.downbeatsMs = const <int>[],
    this.endMs,
  }) : wholeOnly = null;

  const SongToPointAt.wholeOnly(String why)
      : sections = const <StructureSection>[],
        downbeatsMs = const <int>[],
        endMs = null,
        wholeOnly = why;

  final List<StructureSection> sections;

  /// The first beat of each bar, which is all a run of bars is built on.
  /// Empty for a recording with no confident grid, and then no bars are
  /// offered (see barLoop).
  final List<int> downbeatsMs;

  /// Where the recording stops, for the last bar.
  final int? endMs;

  /// Why only the whole song is on offer, or null when parts are.
  final String? wholeOnly;
}

const String _noSheetYet =
    'This song has no sheet yet, so the whole of it is all there is to point '
    'at, and it opens at its own speed.';
const String _recordingStays =
    'The recording stays here, so the whole of it is all there is to point '
    'at, and it opens at its own speed.';

/// What a teacher can point at on this song, given whether it has a sheet
/// and whose song it is.
SongToPointAt whereToPoint({
  required bool sheet,
  required SongOrigin? origin,
  required ReferenceTrack? recording,
}) {
  if (!sheet || recording == null) return const SongToPointAt.wholeOnly(_noSheetYet);
  if (origin != SongOrigin.ours && origin != SongOrigin.publicDomain) {
    return const SongToPointAt.wholeOnly(_recordingStays);
  }
  final duration = recording.durationMs;
  return SongToPointAt(
    sections: recording.structureSections,
    downbeatsMs: recording.downbeatsMs,
    endMs: duration != null && duration > 0 ? duration : null,
  );
}

/// What came back from the sheet: a brief, or the decision to send the song
/// without one. Closing the sheet returns no result at all, which changes
/// nothing.
@immutable
class BriefChoice {
  const BriefChoice(this.brief);

  final BriefToSend? brief;
}

/// Asks the teacher what to practise.
Future<BriefChoice?> showBriefSheet(
  BuildContext context, {
  required SongToPointAt song,
  BriefToSend? initial,
}) {
  return showModalBottomSheet<BriefChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.raised,
    // The sheet's own context, not the song's: the keyboard comes up under
    // this builder (see showLeavePractice).
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: BriefSheet(song: song, initial: initial),
    ),
  );
}

/// The sheet itself, public so a test can put it on screen without a route.
class BriefSheet extends StatefulWidget {
  const BriefSheet({required this.song, this.initial, super.key});

  final SongToPointAt song;

  /// What was filled in last time, when the teacher comes back to change it
  /// before sending.
  final BriefToSend? initial;

  @override
  State<BriefSheet> createState() => _BriefSheetState();
}

class _BriefSheetState extends State<BriefSheet> {
  final TextEditingController _phrase = TextEditingController();
  final TextEditingController _due = TextEditingController();
  final List<String> _phrases = <String>[];

  late final List<PracticeTarget> _targets = practiceTargets(widget.song.sections);

  /// Which of [_targets] is chosen, or null when it is a run of bars.
  int? _target = 0;
  int _firstBar = 1;
  int _lastBar = 1;
  double _rate = practiceRates.last;

  int get _barCount => widget.song.downbeatsMs.length;

  /// Bars are offered only where there is a grid to count them on, and a
  /// slider needs two ends to be a slider.
  bool get _offersBars => _barCount >= 2;

  @override
  void initState() {
    super.initState();
    // Four bars is the phrase a teacher hands out when they hand out bars.
    _lastBar = _barCount < 4 ? (_barCount < 1 ? 1 : _barCount) : 4;
    final initial = widget.initial;
    if (initial == null) return;
    _phrases.addAll(initial.listeningFor.take(briefPhrasesKept));
    _due.text = initial.dueWords ?? '';
    if (widget.song.wholeOnly != null) return;
    if (practiceRates.contains(initial.rate)) _rate = initial.rate;
    final chosen = loopFor(
      initial.startMs,
      initial.endMs,
      sections: widget.song.sections,
      downbeatsMs: widget.song.downbeatsMs,
    );
    if (chosen == null) return;
    if (chosen.isBars && _offersBars) {
      _target = null;
      _firstBar = chosen.firstBar!;
      _lastBar = chosen.lastBar!;
      return;
    }
    final at = _targets.indexWhere(
        (target) => target.startMs == chosen.startMs && target.endMs == chosen.endMs);
    if (at >= 0) _target = at;
  }

  @override
  void dispose() {
    _phrase.dispose();
    _due.dispose();
    super.dispose();
  }

  /// The two ends, kept inside the song and in order. One end moving stops
  /// where the other one is rather than dragging it along, as the bars sheet
  /// in Perform does it.
  void _moveBars({int? first, int? last}) {
    var start = (first ?? _firstBar).clamp(1, _barCount).toInt();
    var end = (last ?? _lastBar).clamp(1, _barCount).toInt();
    if (first != null && last == null) {
      if (start > _lastBar) start = _lastBar;
    } else if (last != null && first == null) {
      if (end < _firstBar) end = _firstBar;
    } else if (end < start) {
      final held = start;
      start = end;
      end = held;
    }
    setState(() {
      _firstBar = start;
      _lastBar = end;
    });
  }

  void _addPhrase() {
    final words = _phrase.text.trim();
    if (words.isEmpty || _phrases.length >= briefPhrasesKept) return;
    setState(() {
      _phrases.add(words);
      _phrase.clear();
    });
  }

  void _done() {
    // Words still sitting in the box were meant: a teacher who typed a
    // phrase and went straight to Done did not decide against it.
    final waiting = _phrase.text.trim();
    final phrases = <String>[
      ..._phrases,
      if (waiting.isNotEmpty && _phrases.length < briefPhrasesKept) waiting,
    ];
    final whole = widget.song.wholeOnly != null;
    final target = whole ? _targets.first : (_target == null ? null : _targets[_target!]);
    final bars = target == null
        ? barLoop(
            firstBar: _firstBar,
            lastBar: _lastBar,
            downbeatsMs: widget.song.downbeatsMs,
            songEndMs: widget.song.endMs,
          )
        : null;
    final due = _due.text.trim();
    Navigator.pop(
      context,
      BriefChoice(BriefToSend(
        passage: bars?.label ?? target?.label ?? _targets.first.label,
        startMs: bars?.startMs ?? target?.startMs,
        endMs: bars?.endMs ?? target?.endMs,
        // No sheet to slow down against, so no speed other than the song's.
        rate: whole ? 1 : _rate,
        listeningFor: phrases,
        dueWords: due.isEmpty ? null : due,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final whyWhole = widget.song.wholeOnly;
    final targets = whyWhole == null ? _targets : _targets.take(1).toList(growable: false);
    final full = _phrases.length >= briefPhrasesKept;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.86,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                whatToPractiseLabel,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              // What it is, said once: the card Home already has, not a
              // message and not a deadline.
              const Text(
                'It waits on their Home with the song, ready to play.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 16),
              const _Label('Which part'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (var index = 0; index < targets.length; index += 1)
                    ChoiceChip(
                      key: Key('brief_part_$index'),
                      label: Text(targets[index].label),
                      selected: whyWhole != null || index == _target,
                      onSelected: (_) => setState(() => _target = index),
                    ),
                  if (whyWhole == null && _offersBars)
                    ChoiceChip(
                      key: const Key('brief_part_bars'),
                      label: const Text('Bars'),
                      selected: _target == null,
                      onSelected: (_) => setState(() => _target = null),
                    ),
                ],
              ),
              if (whyWhole != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  whyWhole,
                  key: const Key('brief_whole_only'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
              if (whyWhole == null && _target == null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  barsLabel(_firstBar, _lastBar),
                  key: const Key('brief_bars_label'),
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                RangeSlider(
                  key: const Key('brief_bars_range'),
                  values: RangeValues(_firstBar.toDouble(), _lastBar.toDouble()),
                  min: 1,
                  max: _barCount.toDouble(),
                  divisions: _barCount - 1,
                  activeColor: AppColors.gold,
                  inactiveColor: AppColors.line,
                  onChanged: (values) => _moveBars(
                    first: values.start.round(),
                    last: values.end.round(),
                  ),
                ),
                // The slider crosses the whole song, so on a long one a bar
                // is a couple of pixels wide. These land on the bar meant.
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: <Widget>[
                    _BarEnd(
                      name: 'First',
                      bar: _firstBar,
                      earlier: _firstBar > 1 ? () => _moveBars(first: _firstBar - 1) : null,
                      later: _firstBar < _lastBar ? () => _moveBars(first: _firstBar + 1) : null,
                      keyPrefix: 'brief_bar_first',
                    ),
                    _BarEnd(
                      name: 'Last',
                      bar: _lastBar,
                      earlier: _lastBar > _firstBar ? () => _moveBars(last: _lastBar - 1) : null,
                      later: _lastBar < _barCount ? () => _moveBars(last: _lastBar + 1) : null,
                      keyPrefix: 'brief_bar_last',
                    ),
                  ],
                ),
              ],
              if (whyWhole == null) ...<Widget>[
                const SizedBox(height: 18),
                const _Label('How fast'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final rate in practiceRates)
                      ChoiceChip(
                        key: Key('brief_rate_${rateLabel(rate)}'),
                        label: Text(rateLabel(rate)),
                        selected: rate == _rate,
                        onSelected: (_) => setState(() => _rate = rate),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              const _Label('Listening for', note: 'optional'),
              const SizedBox(height: 4),
              // Said before they record, so it is something to aim at rather
              // than something to be measured against afterwards.
              const Text(
                'A few words each. They read these before they record.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < _phrases.length; index += 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.hearing_rounded, size: 15, color: AppColors.gold),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _phrases[index],
                          key: Key('brief_phrase_$index'),
                          style: const TextStyle(color: AppColors.text, fontSize: 13.5, height: 1.3),
                        ),
                      ),
                      IconButton(
                        key: Key('brief_phrase_remove_$index'),
                        onPressed: () => setState(() => _phrases.removeAt(index)),
                        tooltip: 'Take it off',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              if (full)
                const Text(
                  'That is as many as a brief holds.',
                  key: Key('brief_phrases_full'),
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
                )
              else
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const Key('brief_phrase'),
                        controller: _phrase,
                        // Limited without a counter: a "12/80" under the box
                        // is a number nobody asked for.
                        inputFormatters: <TextInputFormatter>[
                          LengthLimitingTextInputFormatter(briefPhraseLength),
                        ],
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _addPhrase(),
                        decoration: const InputDecoration(
                          hintText: 'The breath before “credimi”',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      key: const Key('brief_phrase_add'),
                      onPressed: _addPhrase,
                      tooltip: 'Add',
                      icon: const Icon(Icons.add_rounded, color: AppColors.gold),
                    ),
                  ],
                ),
              const SizedBox(height: 18),
              const _Label('When by', note: 'optional, in your words'),
              const SizedBox(height: 8),
              // Words, never a date picker: nothing is counted down to and
              // nothing is sent when it passes.
              TextField(
                key: const Key('brief_due'),
                controller: _due,
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(briefDueLength),
                ],
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Before Thursday',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                key: const Key('brief_done'),
                onPressed: _done,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text('Done'),
              ),
              if (widget.initial != null)
                Center(
                  child: TextButton(
                    key: const Key('brief_clear'),
                    onPressed: () => Navigator.pop(context, const BriefChoice(null)),
                    child: const Text('Send the song without it'),
                  ),
                ),
              const SizedBox(height: 8),
              // The half of it a teacher would otherwise go looking for.
              const Text(
                'You will not see whether they opened it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One end of a run of bars, a bar at a time.
class _BarEnd extends StatelessWidget {
  const _BarEnd({
    required this.name,
    required this.bar,
    required this.earlier,
    required this.later,
    required this.keyPrefix,
  });

  final String name;
  final int bar;
  final VoidCallback? earlier;
  final VoidCallback? later;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(name, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
        IconButton(
          key: Key('${keyPrefix}_earlier'),
          onPressed: earlier,
          tooltip: 'Earlier',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_rounded, size: 18),
        ),
        Text(
          '$bar',
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        IconButton(
          key: Key('${keyPrefix}_later'),
          onPressed: later,
          tooltip: 'Later',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_rounded, size: 18),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          text,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 6),
          Text(
            note!,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

/// The brief, on the song it rides with: one line under the toolbar, for the
/// two people it is between.
///
/// The card on Home has room for the passage, the speed and when by, and no
/// room for what the teacher is listening for, which is the part a student
/// wants in front of them before they record. So the song itself carries the
/// whole of it, one tap away, and the teacher sees on their copy exactly
/// what the student sees on theirs -- and nothing about whether they looked.
class BriefOnTheSong extends StatelessWidget {
  const BriefOnTheSong({
    required this.brief,
    required this.me,
    required this.onOpen,
    super.key,
  });

  final SongBrief brief;
  final String me;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Material(
        color: AppColors.gold.withValues(alpha: 0.10),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.42)),
        ),
        child: InkWell(
          key: const Key('song_brief'),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: <Widget>[
                const Icon(Icons.repeat_rounded, size: 18, color: AppColors.gold),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        briefFrom(brief, me: me),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.gold,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        songBriefSaid(brief),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The whole brief, read. True when the person asked to practise it.
Future<bool> showBriefReading(
  BuildContext context, {
  required SongBrief brief,
  required String me,
}) async {
  final practise = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.raised,
    builder: (_) => BriefReading(brief: brief, me: me),
  );
  return practise ?? false;
}

/// The sheet itself, public so a test can put it on screen without a route.
class BriefReading extends StatelessWidget {
  const BriefReading({required this.brief, required this.me, super.key});

  final SongBrief brief;
  final String me;

  @override
  Widget build(BuildContext context) {
    final mine = brief.teacherId == me;
    final due = (brief.dueWords ?? '').trim();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                briefFrom(brief, me: me),
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                practiceSaid(brief.part),
                key: const Key('brief_reading_passage'),
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (due.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  due,
                  key: const Key('brief_reading_due'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 13.5),
                ),
              ],
              if (brief.listeningFor.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                const _Label('Listening for'),
                const SizedBox(height: 6),
                for (final phrase in brief.listeningFor)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(Icons.hearing_rounded, size: 15, color: AppColors.gold),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            phrase,
                            style: const TextStyle(
                                color: AppColors.text, fontSize: 14, height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 14),
              if (mine)
                // Where a teacher would look for a "seen". There is not one.
                const Text(
                  'You will not see whether they opened it.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
                )
              else
                FilledButton(
                  key: const Key('brief_reading_practise'),
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: const Text('Practise'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
