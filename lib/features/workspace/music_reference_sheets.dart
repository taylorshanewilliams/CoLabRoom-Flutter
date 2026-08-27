import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/music_reference.dart';
import '../toolbox/guitar_chord_diagram.dart';
import '../toolbox/toolbox_models.dart' show ChordDiagramData;

/// The reference sheets, opened from the thing they describe.
///
/// The Toolbox asked you to leave the song, pick an instrument, pick a sheet,
/// and then transpose its example into your own key. These open on the chord
/// or the key you just tapped, already in that key, and close again.

Future<void> showChordReference(BuildContext context, String chordLabel) {
  final reference = chordReference(chordLabel);
  if (reference == null) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _ChordReferenceSheet(reference: reference),
  );
}

Future<void> showKeyReference(BuildContext context, String keyLabel) {
  final reference = keyReference(keyLabel);
  if (reference == null) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _KeyReferenceSheet(reference: reference),
  );
}

class _ChordReferenceSheet extends StatelessWidget {
  const _ChordReferenceSheet({required this.reference});

  final ChordReference reference;

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      key: const Key('chord_reference_sheet'),
      title: reference.display,
      subtitle: reference.recognised
          ? reference.qualityName
          : 'No shape stored for this one',
      children: <Widget>[
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
                  Expanded(child: _ShapeView(shape: shape)),
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

class _KeyReferenceSheet extends StatelessWidget {
  const _KeyReferenceSheet({required this.reference});

  final KeyReference reference;

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      key: const Key('key_reference_sheet'),
      title: reference.display,
      subtitle: 'Relative ${reference.relative}',
      children: <Widget>[
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
  const _ShapeView({required this.shape});

  final ChordShape shape;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        GuitarChordDiagram(
          chord: ChordDiagramData(
            name: shape.name,
            frets: shape.frets,
            baseFret: shape.baseFret,
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
