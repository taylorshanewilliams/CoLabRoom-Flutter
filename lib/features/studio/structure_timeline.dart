import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';

/// The shape of the song: which parts it's built from and the order they
/// come in.
///
/// Reads as a form ("Intro Verse Chorus Verse Chorus Bridge Chorus") rather
/// than a list of boundaries, because that is how a musician describes a song
/// to another musician. Repeats share a colour and a name, so the pattern is
/// visible before a single word is read.
///
/// The names are a trained model's read, not a measurement, and the note
/// under the timeline says so rather than letting confident typography imply
/// otherwise. Analyses from before that model shipped carry letters here
/// instead and render the same way.
class StructureTimeline extends StatelessWidget {
  const StructureTimeline({required this.sections, this.onRename, super.key});

  final List<StructureSection> sections;

  /// Called with the model's label for the part and the name the band chose,
  /// or null to go back to the model's word. Omitted where renaming has
  /// nowhere to be saved, in which case the legend is just a legend.
  final void Function(String label, String? name)? onRename;

  static const _palette = <Color>[
    AppColors.cyan,
    AppColors.gold,
    AppColors.green,
    Color(0xFFB993FF),
    Color(0xFFFF7A7A),
    Color(0xFF7C8CFF),
  ];

  Color _colorFor(StructureSection section) =>
      _palette[section.groupIndex % _palette.length];

  @override
  Widget build(BuildContext context) {
    if (sections.isEmpty) {
      return Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: const Text(
          'Structure not detected for this recording',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      );
    }

    // One entry per distinct part, in order of first appearance, with how
    // many times it comes round.
    final playCounts = <int, int>{};
    final firstSeen = <int, StructureSection>{};
    for (final section in sections) {
      playCounts.update(section.groupIndex, (value) => value + 1, ifAbsent: () => 1);
      firstSeen.putIfAbsent(section.groupIndex, () => section);
    }
    final parts = firstSeen.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 40,
            child: Row(
              children: <Widget>[
                for (var i = 0; i < sections.length; i += 1) ...<Widget>[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: math.max(1, sections[i].durationMs),
                    child: Container(
                      color: _colorFor(sections[i]).withValues(alpha: 0.3),
                      alignment: Alignment.center,
                      // FittedBox rather than a fixed size: a short part still
                      // shows its letter instead of a clipped fragment, which
                      // is what made narrow blocks read as noise.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Text(
                            sections[i].shortLabel,
                            style: TextStyle(
                              color: _colorFor(sections[i]),
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // The form, spelled out. This is the line a musician would actually
        // say out loud about the song.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            const Text(
              'Form',
              style: TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w800),
            ),
            for (final section in sections)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _colorFor(section).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  section.displayLabel,
                  style: TextStyle(
                    color: _colorFor(section),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        // The legend doubles as where you rename a part. Renaming from here
        // rather than from a block on the timeline is deliberate: one row is
        // one *part*, and the name belongs to the part, not to the third
        // minute of the recording.
        for (final entry in parts)
          InkWell(
            onTap: onRename == null
                ? null
                : () => _promptForName(context, entry.value),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: _palette[entry.key % _palette.length],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      // Just the name. It used to read "Part A", which needed
                      // the word "Part" to make a bare letter mean anything;
                      // "Part Chorus" is not something anyone says.
                      entry.value.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (entry.value.isRenamed) ...<Widget>[
                    const SizedBox(width: 5),
                    // What the model called it, kept visible. A part renamed
                    // to "the big one" is easier to trust when you can still
                    // see it was the chorus.
                    Text(
                      entry.value.label,
                      style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_duration(entry.value.durationMs)} · first at ${_clock(entry.value.startMs)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                    ),
                  ),
                  Text(
                    playCounts[entry.key] == 1
                        ? 'once'
                        : '${playCounts[entry.key]}×',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                  if (onRename != null) ...<Widget>[
                    const SizedBox(width: 6),
                    const Icon(Icons.edit_rounded, size: 13, color: AppColors.muted),
                  ],
                ],
              ),
            ),
          ),
        // Said plainly, once, under the thing it's about. The names are a
        // model's read of a song's shape and they will sometimes be wrong —
        // typography this confident owes the reader that much.
        const SizedBox(height: 2),
        const Text(
          'Section names come from a model trained on thousands of annotated '
          'songs. It reads the shape well and the names less so — treat them '
          'as a starting point.',
          style: TextStyle(color: AppColors.muted, fontSize: 10.5, height: 1.4),
        ),
      ],
    );
  }

  Future<void> _promptForName(BuildContext context, StructureSection section) async {
    final rename = onRename;
    if (rename == null) return;
    final controller = TextEditingController(text: section.customLabel ?? '');
    final chosen = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Rename ${section.label}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Every ${section.label.toLowerCase()} in this song gets this name.',
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Your name for it',
                hintText: section.label,
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
        actions: <Widget>[
          // Only offered once there's something to undo, so the common case
          // is a two-button dialog rather than a three-button one.
          if (section.isRenamed)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, ''),
              child: Text('Use “${section.label}”'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (chosen == null) return;
    rename(section.label, chosen.trim().isEmpty ? null : chosen.trim());
  }

  String _clock(int ms) {
    final totalSeconds = ms ~/ 1000;
    return '${totalSeconds ~/ 60}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
  }

  String _duration(int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }
}
