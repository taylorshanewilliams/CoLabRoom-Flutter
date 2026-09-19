import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../services/brought_chart.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/note_that_fits.dart';
import 'brought_chart_view.dart';

/// Bringing a chart you already have.
///
/// Taylor, 19 September 2026, on practising any song you want: this is the
/// step. Paste it or open the file, look at what was understood, keep it.
///
/// **Nothing here goes and gets a chart.** There is no scraper in this app,
/// no URL box and no search: tabs and lyrics of commercial songs are licensed
/// content, and the sites that hold them have no API and terms that forbid
/// it. What this does is what OnSong and SongbookPro do — take a chart a
/// person already has into their own private song.
///
/// The clipboard is read on the Paste tap and at no other moment. Nothing in
/// this app looks at what somebody copied unless they asked it to.

enum _ChartSource { paste, file }

/// Paste or open a chart, look at it, and keep it on [projectId].
///
/// Returns the chart that was kept, or null when nobody kept one — cancelled,
/// empty, or refused by the room.
Future<BroughtChart?> showBringAChartFlow(
  BuildContext context, {
  required String projectId,
  required String songTitle,
  required MusicRepository repository,
  bool replacing = false,
}) async {
  final chart = await readAChart(
    context,
    songTitle: songTitle,
    replacing: replacing,
  );
  if (chart == null || !context.mounted) return null;
  try {
    await repository.bringChart(projectId, chart.chordPro);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showNote(
        reportAndDescribe(error, service: 'app', route: 'Bring a chart'),
      );
    }
    return null;
  }
  return chart;
}

/// The chart, read and looked at, without keeping it anywhere.
///
/// Split out from [showBringAChartFlow] because a song being made from a
/// chart has nowhere to keep one until it exists: the chart is read first and
/// the song is made afterwards, so that cancelling at the preview leaves no
/// empty song behind.
Future<BroughtChart?> readAChart(
  BuildContext context, {
  required String songTitle,
  bool replacing = false,
}) async {
  final source = await showModalBottomSheet<_ChartSource>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _WhereIsItSheet(replacing: replacing),
  );
  if (source == null || !context.mounted) return null;

  // A statement switch rather than an expression, for the reason the lyric
  // import flow gives: in the expression form the analyzer reads the first
  // arm's await as an async gap before the other arm's use of `context`,
  // which cannot happen because exactly one arm runs.
  final String? text;
  switch (source) {
    case _ChartSource.paste:
      text = await _pasteAChart(context);
    case _ChartSource.file:
      text = await _openAChartFile(context);
  }
  if (text == null || !context.mounted) return null;

  if (text.length > chartBodyLimit) {
    ScaffoldMessenger.of(context)
        .showNote('That is too long to keep as one chart.');
    return null;
  }

  final chart = readChart(text);
  final kept = await showDialog<bool>(
    context: context,
    builder: (_) => _WhatWasUnderstood(chart: chart, songTitle: songTitle),
  );
  return kept == true ? chart : null;
}

/// The clipboard, read now because somebody just asked for it.
Future<String?> _pasteAChart(BuildContext context) async {
  String? copied;
  try {
    copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {
    // A platform that will not hand the clipboard over leaves the box empty,
    // which is exactly what an empty clipboard leaves it. Either way there is
    // a field to paste or type into.
    copied = null;
  }
  if (!context.mounted) return null;
  final typed = await showDialog<String>(
    context: context,
    builder: (_) => _PasteChartDialog(startingWith: copied ?? ''),
  );
  if (typed == null || typed.trim().isEmpty) return null;
  return typed;
}

/// What a chart is saved as. ChordPro's own three, OnSong's, and the plain
/// text file somebody typed a chart into.
const List<String> _chartExtensions = <String>[
  'cho', 'chopro', 'crd', 'pro', 'txt',
];

/// Whether the system picker can be asked for those extensions by name.
///
/// On Android it cannot, and asking is worse than not asking: the plugin
/// turns each extension into a MIME type through `MimeTypeMap` and silently
/// drops the ones it has never heard of (android_file_picker 1.1.1,
/// `FileUtils.getMimeTypes`), falling back to `*/*` only when *none* of them
/// resolve. `txt` resolves, so the filter that reaches the picker is
/// `[text/plain]` alone and the .cho somebody exported from OnSong is greyed
/// out in front of them — the one file they came to open (review, 19
/// September 2026). So Android is shown everything and the name is checked
/// here instead. Every other platform filters properly and keeps doing it.
bool get _pickerCanFilter =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.android;

Future<String?> _openAChartFile(BuildContext context) async {
  try {
    final file = await FilePicker.pickFile(
      type: _pickerCanFilter ? FileType.custom : FileType.any,
      allowedExtensions: _pickerCanFilter ? _chartExtensions : null,
    );
    if (file == null) return null;
    if (!_pickerCanFilter &&
        !_chartExtensions.contains(file.extension?.toLowerCase())) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showNote(
          'That is not a chart file. Open a .cho, .chopro, .crd, .pro or .txt.',
        );
      }
      return null;
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showNote('There was nothing in that file.');
      }
      return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showNote(
        reportAndDescribe(error, service: 'app', route: 'Bring a chart'),
      );
    }
    return null;
  }
}

/// Where the chart is coming from.
class _WhereIsItSheet extends StatelessWidget {
  const _WhereIsItSheet({required this.replacing});

  final bool replacing;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              replacing ? 'Replace the chart' : 'Bring a chart',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'A chart you already have. Chords over the words, ChordPro, or '
              'the chords written in brackets.',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            _SourceTile(
              tileKey: const Key('bring_a_chart_paste'),
              icon: Icons.content_paste_rounded,
              title: 'Paste it',
              subtitle: 'From Notes, a document, an email',
              onTap: () => Navigator.pop(context, _ChartSource.paste),
            ),
            _SourceTile(
              tileKey: const Key('bring_a_chart_file'),
              icon: Icons.description_outlined,
              title: 'Open a file',
              subtitle: '.cho, .chopro, .crd, .pro or .txt',
              onTap: () => Navigator.pop(context, _ChartSource.file),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: tileKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Icon(icon, color: AppColors.cyan, size: 21),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The chart, in a box, before anything is done with it.
///
/// Opened with whatever was on the clipboard already in it, because the tap
/// that got here said Paste. Editable, because a chart copied out of a
/// browser often brings a line of something else with it.
class _PasteChartDialog extends StatefulWidget {
  const _PasteChartDialog({required this.startingWith});

  final String startingWith;

  @override
  State<_PasteChartDialog> createState() => _PasteChartDialogState();
}

class _PasteChartDialogState extends State<_PasteChartDialog> {
  late final TextEditingController _chart =
      TextEditingController(text: widget.startingWith);

  @override
  void dispose() {
    _chart.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('The chart'),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 620, maxHeight: size.height * 0.5),
        // Named, for the reason the lyric editor is: with no label and no
        // hint a screen reader reads a wall of chords as the value of
        // something it cannot name (#403's report, 18 September 2026).
        child: Semantics(
          label: 'Chart',
          child: TextField(
            key: const Key('bring_a_chart_field'),
            controller: _chart,
            autofocus: widget.startingWith.isEmpty,
            minLines: 8,
            maxLines: null,
            // A chart is not prose: nothing here should be capitalised or
            // spell-corrected on its way in.
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: '[Verse 1]\nC          G\nWords go here',
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _chart,
          builder: (context, _) => FilledButton(
            key: const Key('bring_a_chart_read'),
            onPressed: _chart.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, _chart.text),
            child: const Text('Read it'),
          ),
        ),
      ],
    );
  }
}

/// What was understood, drawn the way it will be drawn on the song.
///
/// The preview is the page itself rather than a report about it. There is no
/// count of what was recognised and no warning about what was not: a chord
/// that was understood is drawn over its word, and a line that was not is
/// still there, in front of somebody who can see for themselves whether it
/// came out right.
class _WhatWasUnderstood extends StatelessWidget {
  const _WhatWasUnderstood({required this.chart, required this.songTitle});

  final BroughtChart chart;
  final String songTitle;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final nothing = chart.isEmpty;
    return Dialog(
      key: const Key('bring_a_chart_preview'),
      insetPadding: const EdgeInsets.all(14),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: 720, maxHeight: size.height - 28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('This is what it says',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: nothing
                      ? const Text(
                          'There were no words and no chords in that.',
                          style: TextStyle(color: AppColors.muted),
                        )
                      : BroughtChartView(
                          chart: chart,
                          title: songTitle,
                          transpose: 0,
                          fontScale: 1,
                          musicalKey: chartKey(chart),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('bring_a_chart_keep'),
                    onPressed:
                        nothing ? null : () => Navigator.pop(context, true),
                    child: const Text('Keep'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
