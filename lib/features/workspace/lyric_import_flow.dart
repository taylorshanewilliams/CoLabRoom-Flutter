import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import 'lyric_import_service.dart';

enum _ImportSource { file, googleSheet, paste }

Future<List<ContributionDraft>?> showLyricImportFlow(BuildContext context) async {
  final source = await showModalBottomSheet<_ImportSource>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => const _ImportSourceSheet(),
  );
  if (source == null || !context.mounted) return null;

  final draft = switch (source) {
    _ImportSource.file => await _pickLyricFile(),
    _ImportSource.googleSheet => await _importGoogleSheet(context),
    _ImportSource.paste => await _pasteLyrics(context),
  };
  if (draft == null || !context.mounted) return null;
  return _reviewImport(context, draft);
}

Future<LyricImportDraft?> _pickLyricFile() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const <String>['pdf', 'xlsx', 'csv', 'txt', 'md'],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw const LyricImportException('ColabRoom could not read that file.');
  }
  return LyricImportService.fromFile(name: file.name, bytes: bytes);
}

Future<LyricImportDraft?> _importGoogleSheet(BuildContext context) async {
  final link = await showDialog<String>(
    context: context,
    builder: (_) => const _GoogleSheetDialog(),
  );
  if (link == null || link.trim().isEmpty) return null;

  final exportUri = _googleSheetExportUri(link.trim());
  final response = await http.get(exportUri);
  if (response.statusCode != 200) {
    throw const LyricImportException(
      'That Google Sheet could not be opened. Set its sharing to “Anyone with the link,” then try again.',
    );
  }
  final text = utf8.decode(response.bodyBytes, allowMalformed: true);
  if (text.trimLeft().startsWith('<!DOCTYPE') || text.trimLeft().startsWith('<html')) {
    throw const LyricImportException(
      'Google returned a sign-in page. Share the sheet with “Anyone with the link,” then try again.',
    );
  }
  return LyricImportService.fromCsv(sourceName: 'Google Sheet', csvText: text);
}

Uri _googleSheetExportUri(String source) {
  final uri = Uri.tryParse(source);
  final match = RegExp(r'/spreadsheets/d/([^/]+)').firstMatch(uri?.path ?? '');
  if (uri == null || !uri.host.endsWith('google.com') || match == null) {
    throw const LyricImportException('Paste a valid Google Sheets sharing link.');
  }
  var gid = uri.queryParameters['gid'];
  if (gid == null && uri.fragment.isNotEmpty) {
    try {
      gid = Uri.splitQueryString(uri.fragment)['gid'];
    } on FormatException {
      gid = null;
    }
  }
  return Uri.https(
    'docs.google.com',
    '/spreadsheets/d/${match.group(1)}/export',
    <String, String>{'format': 'csv', if (gid != null) 'gid': gid},
  );
}

Future<LyricImportDraft?> _pasteLyrics(BuildContext context) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => const _PasteLyricsDialog(),
  );
  if (text == null || text.trim().isEmpty) return null;
  return LyricImportService.fromText(sourceName: 'Pasted lyrics', text: text);
}

Future<List<ContributionDraft>?> _reviewImport(
  BuildContext context,
  LyricImportDraft draft,
) async {
  final controller = TextEditingController(text: draft.editableText);
  final reviewed = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ReviewImportDialog(
      sourceName: draft.sourceName,
      controller: controller,
    ),
  );
  controller.dispose();
  if (reviewed == null) return null;
  return LyricImportService.fromText(
    sourceName: draft.sourceName,
    text: reviewed,
  ).lines;
}

class _ImportSourceSheet extends StatelessWidget {
  const _ImportSourceSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Import lyrics', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 6),
            const Text(
              'ColabRoom will turn the source into editable lyric lines for you to review.',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            _ImportSourceTile(
              icon: Icons.description_outlined,
              title: 'Choose a file',
              subtitle: 'PDF, Excel, CSV, text, or Markdown',
              onTap: () => Navigator.pop(context, _ImportSource.file),
            ),
            _ImportSourceTile(
              icon: Icons.table_chart_outlined,
              title: 'Google Sheet link',
              subtitle: 'Import a sheet shared with anyone who has the link',
              onTap: () => Navigator.pop(context, _ImportSource.googleSheet),
            ),
            _ImportSourceTile(
              icon: Icons.content_paste_rounded,
              title: 'Paste lyrics',
              subtitle: 'Copy from Notes, Docs, email, or another app',
              onTap: () => Navigator.pop(context, _ImportSource.paste),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportSourceTile extends StatelessWidget {
  const _ImportSourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

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
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C2341),
                    borderRadius: BorderRadius.circular(13),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Color(0x213AD3FF), blurRadius: 18),
                    ],
                  ),
                  child: Icon(icon, color: AppColors.cyan, size: 21),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
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

class _GoogleSheetDialog extends StatefulWidget {
  const _GoogleSheetDialog();

  @override
  State<_GoogleSheetDialog> createState() => _GoogleSheetDialogState();
}

class _GoogleSheetDialogState extends State<_GoogleSheetDialog> {
  final TextEditingController _link = TextEditingController();

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import a Google Sheet'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Set the sheet to “Anyone with the link,” then paste its sharing link here.',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _link,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'https://docs.google.com/spreadsheets/…'),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _link.text),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _PasteLyricsDialog extends StatefulWidget {
  const _PasteLyricsDialog();

  @override
  State<_PasteLyricsDialog> createState() => _PasteLyricsDialogState();
}

class _PasteLyricsDialogState extends State<_PasteLyricsDialog> {
  final TextEditingController _lyrics = TextEditingController();

  @override
  void dispose() {
    _lyrics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste lyrics'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: TextField(
          controller: _lyrics,
          autofocus: true,
          minLines: 8,
          maxLines: 14,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Verse 1\nFirst lyric line…'),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _lyrics.text),
          child: const Text('Review'),
        ),
      ],
    );
  }
}

class _ReviewImportDialog extends StatefulWidget {
  const _ReviewImportDialog({
    required this.sourceName,
    required this.controller,
  });

  final String sourceName;
  final TextEditingController controller;

  @override
  State<_ReviewImportDialog> createState() => _ReviewImportDialogState();
}

class _ReviewImportDialogState extends State<_ReviewImportDialog> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(() {});

  int get _lineCount => widget.controller.text
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().isNotEmpty)
      .length;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(14),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: size.height - 28,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.auto_fix_high_rounded, color: AppColors.cyan),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text('Review imported lyrics', style: Theme.of(context).textTheme.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                '${widget.sourceName}  ·  $_lineCount lines',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              const Text(
                'One line becomes one ColabRoom bullet. Edit, reorder, or remove anything before importing.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(alignLabelWithHint: true),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _lineCount == 0
                        ? null
                        : () => Navigator.pop(context, widget.controller.text),
                    icon: const Icon(Icons.file_download_done_rounded, size: 18),
                    label: Text('Import $_lineCount'),
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
