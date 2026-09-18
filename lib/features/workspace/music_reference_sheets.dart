import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/set_aside.dart';

import '../../services/what_works_here.dart';

import '../../app/colabroom_theme.dart';
import '../../services/horn_reading.dart';
import '../../services/music_reference.dart';
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

/// The key, and — when the caller can remember it — which instrument this
/// person reads it for.
///
/// [keyLabel] is the concert key as this person plays it. [onReading] is what
/// makes the sheet a picker rather than a chart: the key badge is where
/// somebody already goes to ask about the key, so it is where the answer to
/// "which key is this for me" belongs, one small row rather than a banner on
/// the sheet (Every Musician, Same Song, 17 September 2026).
Future<void> showKeyReference(
  BuildContext context,
  String keyLabel, {
  HornReading reading = HornReading.concert,
  ValueChanged<HornReading>? onReading,
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
}) {
  final key = keyLabel;
  if (key != null && keyReference(key) != null) {
    return showKeyReference(context, key, reading: reading,
        onReading: onReading);
  }
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
              _ReadingChip(
                reading: reading,
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

class _KeyReferenceSheet extends StatefulWidget {
  const _KeyReferenceSheet({
    required this.concertKey,
    required this.reading,
    this.onReading,
  });

  /// The key everybody else in the room is in.
  final String concertKey;
  final HornReading reading;
  final ValueChanged<HornReading>? onReading;

  @override
  State<_KeyReferenceSheet> createState() => _KeyReferenceSheetState();
}

class _KeyReferenceSheetState extends State<_KeyReferenceSheet> {
  late HornReading _reading = widget.reading;

  /// The key as this person's instrument writes it, which is what the scale,
  /// the chords and the capo rows below are all about: a sax player asking
  /// what is in this key wants their own seven notes, not the band's.
  String get _written => keyAsPlayed(widget.concertKey, _reading.semitones);

  void _choose(HornReading reading) {
    if (reading == _reading) return;
    setState(() => _reading = reading);
    widget.onReading?.call(reading);
  }

  @override
  Widget build(BuildContext context) {
    // Transposing a real key always lands on a real key, so this cannot be
    // null once showKeyReference has checked the one it was handed.
    final reference = keyReference(_written)!;
    // The band's key, never dropped from a transposed part: it is what this
    // player has to say out loud to everybody else.
    final concert =
        keyReference(widget.concertKey)?.display ?? widget.concertKey;
    return _SheetFrame(
      key: const Key('key_reference_sheet'),
      title: reference.display,
      subtitle: _reading == HornReading.concert
          ? 'Relative ${reference.relative}'
          : 'Relative ${reference.relative} · concert $concert',
      children: <Widget>[
        if (widget.onReading != null) ...<Widget>[
          _Section(
            heading: 'Read as',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final reading in HornReading.values)
                  _ReadingChip(
                    reading: reading,
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
          if (reference.capo.isEmpty)
            const _Note(
              'This key already sits under open chords — no capo needed.',
            )
          else
            _Section(
              heading: 'With a capo',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final (fret, shapeKey) in reference.capo)
                    _Row(
                      label: 'Capo $fret',
                      value: 'play the $shapeKey shapes',
                    ),
                ],
              ),
            ),
        ],
      ],
    );
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

/// One instrument to read the song for.
///
/// Listed flat and in a fixed order, the way the plan asks readings to be
/// listed: four languages for the same song, never a ladder from easy to
/// advanced. Nothing here says what anybody plays.
class _ReadingChip extends StatelessWidget {
  const _ReadingChip({
    required this.reading,
    required this.selected,
    required this.onTap,
  });

  final HornReading reading;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        key: Key('read_as_${reading.name}'),
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
            reading.label,
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
