import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/set_aside.dart';

import '../../services/what_works_here.dart';

import '../../app/colabroom_theme.dart';
import '../../services/horn_reading.dart';
import '../../services/music_reference.dart';
import '../../services/number_reading.dart';
import 'guitar_chord_diagram.dart';
import 'musician_sheet_logic.dart' show keyAsPlayed;

/// The reference sheets, opened from the thing they describe.
///
/// The Toolbox asked you to leave the song, pick an instrument, pick a sheet,
/// and then transpose its example into your own key. These open on the chord
/// or the key you just tapped, already in that key, and close again.

/// The chord, and — when the caller knows them — the song it is in.
///
/// [keyLabel] and [used] are what turn a reference into an answer. Without
/// them this sheet can say what a C chord is; with them it can say that it is
/// the IV here, and which chords of this key the song has not reached for
/// yet. [roles] is what the person plays, and only changes the order.
Future<void> showChordReference(
  BuildContext context,
  String chordLabel, {
  String? keyLabel,
  List<String> used = const <String>[],
  Set<String> roles = const <String>{},
}) {
  final reference = chordReference(chordLabel);
  if (reference == null) return Future<void>.value();
  // The hint has done its whole job the moment somebody taps a chord, so it
  // retires itself here rather than waiting to be dismissed. A hint that
  // keeps explaining something you have already done is the same nag as a
  // card that will not close.
  unawaited(SetAside.add(SetAside.hint, 'tap_a_chord'));
  final help = whatWorksHere(
    chordLabel: chordLabel,
    keyLabel: keyLabel,
    used: used,
    roles: roles,
  );
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _ChordReferenceSheet(reference: reference, help: help),
  );
}

/// Says where the 1 is for the whole room, or hands the song back to the
/// detected key with a null.
///
/// Completes with null once it has landed, or with the sentence to show when
/// it did not. The sheet is where somebody tapped, so the sheet is where a
/// refusal is said: a snackbar would land on the page underneath, hidden by
/// the sheet it was about (review, 17 September 2026).
typedef SayTheKey = Future<String?> Function(String? key);

/// The key, and — when the caller can remember them — the readings this
/// person has chosen for it.
///
/// [keyLabel] is the concert key as this person plays it. The callbacks are
/// what make the sheet a picker rather than a chart: the key badge is where
/// somebody already goes to ask about the key, so it is where the answers to
/// "which key is this for me", "where do I put the capo" and "where is the 1"
/// all belong, small rows rather than a banner on the sheet (Every Musician,
/// Same Song, 17 September 2026).
///
/// [songKey] is the song's own key before this person moved it, which is the
/// only one "Set the key" can be about — that one is a shared fact and the
/// rest of this sheet is personal.
Future<void> showKeyReference(
  BuildContext context,
  String keyLabel, {
  HornReading reading = HornReading.concert,
  ValueChanged<HornReading>? onReading,
  NumberReading numbers = NumberReading.letters,
  ValueChanged<NumberReading>? onNumbers,
  int capo = 0,
  ValueChanged<int>? onCapo,
  String? songKey,
  bool overridden = false,
  SayTheKey? onKey,
}) {
  if (keyReference(keyLabel) == null) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _KeyReferenceSheet(
      concertKey: keyLabel,
      reading: reading,
      onReading: onReading,
      numbers: numbers,
      onNumbers: onNumbers,
      capo: capo,
      onCapo: onCapo,
      songKey: songKey,
      overridden: overridden,
      onKey: onKey,
    ),
  );
}

/// The same choice, from somewhere with no key badge to hang it on.
///
/// The chart has no badge, and a song whose analysis never found a key has
/// none on the sheet either — so on those the reading could be neither chosen
/// nor cleared, which is the one control a horn player actually came for
/// (review, 17 September 2026). With a key it opens the key sheet the badge
/// opens, so there is one answer and not two; without one it opens the row on
/// its own, because the chords still move even when nothing can be said about
/// the key they are in.
Future<void> showReadingChoice(
  BuildContext context, {
  String? keyLabel,
  required HornReading reading,
  required ValueChanged<HornReading> onReading,
  NumberReading numbers = NumberReading.letters,
  ValueChanged<NumberReading>? onNumbers,
  int capo = 0,
  ValueChanged<int>? onCapo,
  String? songKey,
  bool overridden = false,
  SayTheKey? onKey,
}) {
  final key = keyLabel;
  if (key != null && keyReference(key) != null) {
    return showKeyReference(
      context,
      key,
      reading: reading,
      onReading: onReading,
      numbers: numbers,
      onNumbers: onNumbers,
      capo: capo,
      onCapo: onCapo,
      songKey: songKey,
      overridden: overridden,
      onKey: onKey,
    );
  }
  // Numbers, a capo and "where is the 1" are all counted from a key, so on a
  // song that has none there is nothing for them to say. The instrument row
  // still works: the chords move whether or not anything can be said about
  // the key they are in.
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _ReadingChoiceSheet(
      reading: reading,
      onReading: onReading,
    ),
  );
}

/// The Read as row alone, for a song with no key to describe.
class _ReadingChoiceSheet extends StatefulWidget {
  const _ReadingChoiceSheet({required this.reading, required this.onReading});

  final HornReading reading;
  final ValueChanged<HornReading> onReading;

  @override
  State<_ReadingChoiceSheet> createState() => _ReadingChoiceSheetState();
}

class _ReadingChoiceSheetState extends State<_ReadingChoiceSheet> {
  late HornReading _reading = widget.reading;

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      key: const Key('reading_choice_sheet'),
      title: 'Read as',
      // No key was found for this song, so there is no second key to name —
      // only what the chords in front of you are written for.
      subtitle: _reading == HornReading.concert
          ? 'Chords as the band plays them'
          : 'Chords written for ${_reading.label}',
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final reading in HornReading.values)
              _PickerChip(
                label: reading.label,
                itemKey: Key('read_as_${reading.name}'),
                selected: reading == _reading,
                onTap: () {
                  if (reading == _reading) return;
                  setState(() => _reading = reading);
                  widget.onReading(reading);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _ChordReferenceSheet extends StatelessWidget {
  const _ChordReferenceSheet({required this.reference, this.help});

  final ChordReference reference;

  /// What would work here, when the caller knew enough about the song to ask.
  final WhatWorksHere? help;

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      key: const Key('chord_reference_sheet'),
      title: reference.display,
      // Where it sits in this song, said in the subtitle rather than buried
      // in a section. "The IV of G major" is the orientation somebody who is
      // stuck actually needs, and it is the one thing the old sheet could
      // never say -- it was handed a chord with no song attached.
      subtitle: <String>[
        if (reference.recognised) reference.qualityName
        else 'No shape stored for this one',
        if (help?.degree != null) 'the ${help!.degree} here',
      ].join('  ·  '),
      children: <Widget>[
        // First, above the shapes. Somebody who opened this because they are
        // stuck wants an answer, not a diagram they already understand.
        if (help != null && help!.suggestions.isNotEmpty) ...<Widget>[
          for (final suggestion in help!.suggestions)
            _Section(
              heading: suggestion.heading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    suggestion.detail,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 12.5, height: 1.45),
                  ),
                  if (suggestion.chords.isNotEmpty ||
                      suggestion.notes.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        // Chords stay tappable, so one answer leads to the
                        // next: "try the vi" is worth more when the vi opens
                        // its own shapes.
                        for (final chord in suggestion.chords)
                          _ChordChip(chord: chord, degree: ''),
                        for (final note in suggestion.notes)
                          _NoteChip(note: note, caption: ''),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          const Divider(height: 26, color: AppColors.line),
        ],
        if (!reference.recognised)
          const _Note(
            'This is an unusual chord and guessing at its shape would be '
            'worse than saying nothing. The root note is still the one to '
            'play if you are finding your way in.',
          )
        else ...<Widget>[
          if (reference.shapes.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final shape in reference.shapes)
                  Expanded(
                    child: _ShapeView(
                      shape: shape,
                      // "G major", not "G" — a screen reader spells a bare
                      // chord symbol out letter by letter, and `Gm7` comes
                      // out as noise. The sheet already knows the long form.
                      spokenName: '${reference.root} '
                          '${reference.qualityName.toLowerCase()}',
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 14),
          _Section(
            heading: 'Notes in it',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final tone in reference.tones)
                  _NoteChip(note: tone.note, caption: tone.degree),
              ],
            ),
          ),
          if (reference.bassNote != null)
            _Note(
              'Written over ${reference.bassNote} — that note is the bass '
              'player’s, not the guitar’s.',
            ),
          const SizedBox(height: 14),
          // The other half of the question. A shape says where to put the
          // hand; this says what to reach for between the changes.
          _Section(
            heading: 'Notes that work over it',
            child: Text(
              reference.pentatonic.join('   '),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _Section(
            heading: 'If you are playing bass',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (label, notes) in reference.bassMoves)
                  _Row(label: label, value: notes),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The twelve, written the way a chart writes them: the flat side of the
/// circle in flats, because a song is far more often in E♭ than in D♯.
///
/// Stored with ASCII accidentals, which is what every key parser here reads,
/// and drawn with printed ones.
const List<String> _theTwelve = <String>[
  'C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B',
];

String _printedKey(String stored) =>
    stored.replaceAll('#', '♯').replaceAll('b', '♭');

class _KeyReferenceSheet extends StatefulWidget {
  const _KeyReferenceSheet({
    required this.concertKey,
    required this.reading,
    this.onReading,
    this.numbers = NumberReading.letters,
    this.onNumbers,
    this.capo = 0,
    this.onCapo,
    this.songKey,
    this.overridden = false,
    this.onKey,
  });

  /// The key everybody else in the room is in, as this person has moved it.
  final String concertKey;
  final HornReading reading;
  final ValueChanged<HornReading>? onReading;

  final NumberReading numbers;
  final ValueChanged<NumberReading>? onNumbers;

  final int capo;
  final ValueChanged<int>? onCapo;

  /// The song's own key, before this person moved anything — the only key
  /// "Set the key" can be about, because that one is the room's and the rest
  /// of this sheet is this device's.
  final String? songKey;
  final bool overridden;

  /// Null for somebody who can only look, which leaves "Where the 1 is" off
  /// the sheet altogether: offering a choice the room will refuse is a
  /// question with a wrong answer built in (review, 17 September 2026).
  final SayTheKey? onKey;

  @override
  State<_KeyReferenceSheet> createState() => _KeyReferenceSheetState();
}

class _KeyReferenceSheetState extends State<_KeyReferenceSheet> {
  late HornReading _reading = widget.reading;
  late NumberReading _numbers = widget.numbers;
  late int _capo = widget.capo;
  late String? _songKey = widget.songKey;
  late bool _overridden = widget.overridden;

  /// True while a key is on its way to the room. One write at a time, so two
  /// quick taps cannot land in the wrong order and leave the room in the key
  /// that was tapped first.
  bool _saying = false;

  /// Why the last key did not land, said under the chords that were tapped.
  String? _refused;

  /// A capo is a guitar answer about the key the band is in. Worked out from
  /// a written key it names frets that put the guitar a tone away from
  /// everybody else, so it is only ever in play in concert pitch — the same
  /// rule the capo chart itself has followed since the horn reading landed.
  int get _capoOffset => _reading == HornReading.concert ? _capo : 0;

  /// How far this person has moved the song, read off the two keys the sheet
  /// was opened with, so a key set from here lands where their own key puts
  /// it rather than back in the song's.
  late final int _moved = _semitonesBetween(widget.songKey, widget.concertKey);

  /// The band's key as this person has moved it — the one the sheet was
  /// opened on, until somebody says where the 1 really is from here.
  String get _concertKey {
    final said = _songKey;
    if (said == null || said == widget.songKey) return widget.concertKey;
    return keyAsPlayed(said, _moved);
  }

  /// The key as this person's instrument and capo write it, which is what the
  /// scale and the chords below are all about: a sax player asking what is in
  /// this key wants their own seven notes, not the band's, and a guitarist
  /// with a capo on 4 wants the shapes under their hand.
  String get _written =>
      keyAsPlayed(_concertKey, _reading.semitones - _capoOffset);

  void _choose(HornReading reading) {
    if (reading == _reading) return;
    setState(() => _reading = reading);
    widget.onReading?.call(reading);
  }

  void _chooseNumbers(NumberReading numbers) {
    if (numbers == _numbers) return;
    setState(() => _numbers = numbers);
    widget.onNumbers?.call(numbers);
  }

  void _chooseCapo(int capo) {
    if (capo == _capo) return;
    setState(() => _capo = capo);
    widget.onCapo?.call(capo);
  }

  /// Says where the 1 is. The sheet redraws in the new key straight away, so
  /// the tap feels like it did something, and goes back to the key the room
  /// actually has if the room says no — a sheet showing a key that was never
  /// saved would send somebody away believing the band is in it.
  Future<void> _sayTheKey(String key) async {
    final say = widget.onKey;
    if (say == null || _saying) return;
    if (key == _songKey && _overridden) return;
    final (keyBefore, overriddenBefore) = (_songKey, _overridden);
    setState(() {
      _saying = true;
      _refused = null;
      _songKey = key;
      _overridden = true;
    });
    final refused = await say(key);
    if (!mounted) return;
    setState(() {
      _saying = false;
      _refused = refused;
      if (refused != null) {
        _songKey = keyBefore;
        _overridden = overriddenBefore;
      }
    });
  }

  /// Hands the song back to the analysis. The sheet closes once that has
  /// landed rather than redrawing, because the key it would redraw in is the
  /// detected one and this sheet was never told what that is — the page
  /// behind it was, and redraws itself. If it does not land, the sheet stays
  /// open and says why.
  Future<void> _useTheDetectedKey() async {
    final say = widget.onKey;
    if (say == null || _saying) return;
    setState(() {
      _saying = true;
      _refused = null;
    });
    final refused = await say(null);
    if (!mounted) return;
    if (refused == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saying = false;
      _refused = refused;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Transposing a real key always lands on a real key, so this cannot be
    // null once showKeyReference has checked the one it was handed.
    final reference = keyReference(_written)!;
    // The band's key, never dropped from a transposed or capo'd part: it is
    // what this player has to say out loud to everybody else.
    final concert = keyReference(_concertKey)?.display ?? _concertKey;
    // The capo chart is about the key that is sounding, not the shapes, so it
    // is worked out from the concert key however this sheet is being read.
    final capoRows =
        keyReference(_concertKey)?.capo ?? const <(int, String)>[];
    return _SheetFrame(
      key: const Key('key_reference_sheet'),
      title: reference.display,
      subtitle: <String>[
        'Relative ${reference.relative}',
        if (_capoOffset > 0) 'capo $_capo',
        // The band's key, whichever of the two moved this sheet off it.
        if (_reading != HornReading.concert)
          'concert $concert'
        else if (_capoOffset > 0)
          'sounds in $concert',
      ].join(' · '),
      children: <Widget>[
        if (widget.onNumbers != null) ...<Widget>[
          _Section(
            heading: 'Read as',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final style in NumberStyle.values)
                  _PickerChip(
                    label: style.label,
                    itemKey: Key('read_numbers_${style.name}'),
                    selected: style == _numbers.style,
                    onTap: () => _chooseNumbers(_numbers.withStyle(style)),
                  ),
              ],
            ),
          ),
          // Only on a minor song, and only once somebody is reading Nashville
          // numbers: it is the one moment the two conventions say different
          // things, and asking before then would be a settings screen. Roman
          // numerals have no such choice — a minor key is i VI III VII in
          // every theory class — so the chips, in Nashville's own spelling,
          // are not offered there.
          if (_numbers.style == NumberStyle.nashville &&
              reference.minor) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final convention in MinorNumbers.values)
                  _PickerChip(
                    label: convention.label,
                    itemKey: Key('minor_numbers_${convention.name}'),
                    selected: convention == _numbers.minor,
                    onTap: () =>
                        _chooseNumbers(_numbers.withMinor(convention)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
        ],
        if (widget.onReading != null) ...<Widget>[
          _Section(
            heading: 'Written for',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final reading in HornReading.values)
                  _PickerChip(
                    label: reading.label,
                    itemKey: Key('read_as_${reading.name}'),
                    selected: reading == _reading,
                    onTap: () => _choose(reading),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        _Section(
          heading: 'The scale',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (var i = 0; i < reference.scale.length; i += 1)
                _NoteChip(note: reference.scale[i], caption: '${i + 1}'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Section(
          heading: 'Pentatonic — the five that are hard to play wrong',
          child: Text(
            reference.pentatonic.join('   '),
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(height: 14),
        // The chords of the key are the ones the song is most likely made
        // of, so they are the fastest route back to a shape.
        _Section(
          heading: 'Chords in this key — tap one for its shape',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (var i = 0; i < reference.diatonic.length; i += 1)
                _ChordChip(
                  chord: reference.diatonic[i],
                  degree: reference.degrees[i],
                ),
            ],
          ),
        ),
        // Only in concert pitch. A capo is a guitar answer about the key the
        // band is in; worked out from a written key it names frets that put
        // the guitar a tone away from everybody else, and it means nothing at
        // all to the instrument the reading was chosen for. The scale, the
        // pentatonic and the chords above are right in the written key and
        // stay (review, 17 September 2026).
        if (_reading == HornReading.concert) ...<Widget>[
          const SizedBox(height: 14),
          if (capoRows.isEmpty && _capo == 0)
            const _Note(
              'This key already sits under open chords — no capo needed.',
            )
          else
            _Section(
              heading: 'With a capo',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // The rows were a chart you did the work off. Tapping one
                  // does the work: the chords on the page become the shapes
                  // under your hand and the badge says what it still sounds
                  // like (Every Musician, Same Song, 17 September 2026).
                  for (final (fret, shapeKey) in capoRows)
                    _CapoRow(
                      label: 'Capo $fret',
                      value: 'play the $shapeKey shapes',
                      selected: fret == _capo,
                      onTap: widget.onCapo == null
                          ? null
                          : () => _chooseCapo(fret),
                    ),
                  if (widget.onCapo != null && _capo > 0)
                    _CapoRow(
                      label: 'No capo',
                      value: 'play the $concert chords',
                      selected: false,
                      onTap: () => _chooseCapo(0),
                    ),
                ],
              ),
            ),
        ],
        // Last, because it is the only thing on this sheet that changes what
        // everybody else sees, and because most songs never need it.
        if (widget.onKey != null) ...<Widget>[
          const SizedBox(height: 18),
          const Divider(height: 1, color: AppColors.line),
          const SizedBox(height: 14),
          _Section(
            heading: 'Where the 1 is',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'The scale, the chords and the numbers are all counted '
                  'from this. Say where it really is if the recording was '
                  'heard in the wrong key. Everybody in the room sees it.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final root in _theTwelve)
                      _PickerChip(
                        label: _printedKey(root),
                        itemKey: Key('the_one_is_$root'),
                        selected: _sameRoot(root),
                        onTap: () =>
                            unawaited(_sayTheKey(_keyOf(root, _minorNow))),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final minor in <bool>[false, true])
                      _PickerChip(
                        label: minor ? 'Minor' : 'Major',
                        itemKey:
                            Key('the_one_is_${minor ? 'minor' : 'major'}'),
                        selected: minor == _minorNow,
                        onTap: () => unawaited(
                            _sayTheKey(_keyOf(_rootNow ?? 'C', minor))),
                      ),
                  ],
                ),
                // Here and not in a snackbar: one raised on the page would
                // sit underneath this sheet, which is how a refusal went
                // unseen before (review, 17 September 2026).
                if (_refused != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _refused!,
                      key: const Key('the_one_refused'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
                if (_overridden) ...<Widget>[
                  const SizedBox(height: 6),
                  TextButton(
                    key: const Key('use_the_detected_key'),
                    onPressed: _saying
                        ? null
                        : () => unawaited(_useTheDetectedKey()),
                    child: const Text('Use the detected key'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The root of the key the song is in now, as the chips spell it.
  String? get _rootNow {
    final said = _songKey?.trim();
    if (said == null || said.isEmpty) return null;
    final root = RegExp(r'^([A-G][#b]?)').firstMatch(said)?.group(1);
    if (root == null) return null;
    // Matched by pitch, not by text: the analyser names every key with
    // sharps, so an A♯ major song has to light up the B♭ chip rather than
    // none of them.
    for (final candidate in _theTwelve) {
      if (samePitch(candidate, root)) return candidate;
    }
    return null;
  }

  bool _sameRoot(String root) => _rootNow == root;

  /// A key written the way the analyser writes one, which is the shape 0144
  /// accepts and every key parser here reads.
  static String _keyOf(String root, bool minor) =>
      '$root ${minor ? 'minor' : 'major'}';

  /// Semitones from [from]'s root up to [to]'s, 0 to 11, or 0 when either is
  /// not a key this can read.
  static int _semitonesBetween(String? from, String to) {
    final a = from == null
        ? null
        : RegExp(r'^([A-G][#b]?)').firstMatch(from.trim())?.group(1);
    final b = RegExp(r'^([A-G][#b]?)').firstMatch(to.trim())?.group(1);
    final pa = a == null ? null : pitchOf(a);
    final pb = b == null ? null : pitchOf(b);
    if (pa == null || pb == null) return 0;
    return ((pb - pa) % 12 + 12) % 12;
  }

  bool get _minorNow {
    final rest = _songKey?.trim().toLowerCase() ?? '';
    return rest.contains('min') || rest.endsWith(' m') || rest.contains('aeolian');
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.subtitle,
    required this.children,
    super.key,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _ShapeView extends StatelessWidget {
  const _ShapeView({required this.shape, required this.spokenName});

  final ChordShape shape;

  /// What the chord is called out loud. See the call site.
  final String spokenName;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        GuitarChordDiagram(
          chord: ChordDiagramData(
            name: shape.name,
            frets: shape.frets,
            baseFret: shape.baseFret,
            spokenName: spokenName,
          ),
          size: 112,
        ),
        const SizedBox(height: 4),
        if (shape.hint != null)
          Text(
            shape.hint!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 11,
              height: 1.3,
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.heading, required this.child});

  final String heading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          heading.toUpperCase(),
          style: const TextStyle(
            color: AppColors.gold,
            fontSize: 9.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _NoteChip extends StatelessWidget {
  const _NoteChip({required this.note, required this.caption});

  final String note;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            note,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            caption,
            style: const TextStyle(color: AppColors.muted, fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}

/// One way to read the song, or one note to read it from.
///
/// Listed flat and in a fixed order, the way the plan asks readings to be
/// listed: languages for the same song, never a ladder from easy to advanced.
/// Nothing here says what anybody plays.
class _PickerChip extends StatelessWidget {
  const _PickerChip({
    required this.label,
    required this.itemKey,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Key itemKey;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.gold.withValues(alpha: 0.16)
                : AppColors.raised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? AppColors.gold.withValues(alpha: 0.55)
                  : AppColors.line,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.gold : AppColors.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

/// A capo row you can press, which is the difference between a chart and a
/// setting. The selected one is marked the way a chosen chip is, so the sheet
/// says where the capo is as well as where it could go.
class _CapoRow extends StatelessWidget {
  const _CapoRow({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      key: Key('set_${label.toLowerCase().replaceAll(' ', '_')}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: selected ? AppColors.gold.withValues(alpha: 0.14) : null,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected
              ? AppColors.gold.withValues(alpha: 0.5)
              : Colors.transparent,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.gold : AppColors.muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: selected ? AppColors.gold : AppColors.text,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: row,
      ),
    );
  }
}

class _ChordChip extends StatelessWidget {
  const _ChordChip({required this.chord, required this.degree});

  final String chord;
  final String degree;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // Replaces this sheet rather than stacking a second one on top of it,
      // so backing out of a chord returns to the song and not to the key.
      // The navigator's own context outlives this route — the chip's does
      // not, and opening the next sheet from a dead context does nothing.
      onTap: () {
        final navigator = Navigator.of(context);
        final host = navigator.context;
        navigator.pop();
        showChordReference(host, chord);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.raised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.cyan.withValues(alpha: 0.35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              chord,
              style: const TextStyle(
                color: AppColors.cyan,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              degree,
              style: const TextStyle(color: AppColors.muted, fontSize: 9.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 12.5,
          height: 1.45,
        ),
      ),
    );
  }
}
