import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChordEditResult {
  const ChordEditResult({
    required this.chord,
    required this.wordIndex,
    this.delete = false,
  });

  final String chord;
  final int wordIndex;
  final bool delete;
}

class ChordEditorSheet extends StatefulWidget {
  const ChordEditorSheet({
    required this.line,
    required this.initialWordIndex,
    this.existing,
    super.key,
  });

  final MusicianSheetLine line;
  final ChordCue? existing;
  final int initialWordIndex;

  @override
  State<ChordEditorSheet> createState() => _ChordEditorSheetState();
}

class _ChordEditorSheetState extends State<ChordEditorSheet> {
  static const List<String> _roots = <String>[
    'C',
    'C#',
    'Db',
    'D',
    'Eb',
    'E',
    'F',
    'F#',
    'Gb',
    'G',
    'Ab',
    'A',
    'Bb',
    'B',
  ];
  static const List<(String, String)> _qualities = <(String, String)>[
    ('Major', ''),
    ('Minor', 'm'),
    ('7', '7'),
    ('m7', 'm7'),
    ('maj7', 'maj7'),
    ('sus2', 'sus2'),
    ('sus4', 'sus4'),
    ('add9', 'add9'),
  ];

  late final TextEditingController _controller;
  late int _wordIndex;

  List<String> get _words => widget.line.body
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.existing?.chord ?? '');
    _controller.addListener(_refresh);
    final maxIndex = _words.isEmpty ? 0 : _words.length - 1;
    _wordIndex = widget.initialWordIndex.clamp(0, maxIndex).toInt();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _chooseRoot(String root) {
    final current = _controller.text.trim();
    final match = RegExp(r'^[A-G](?:#|b)?(.*)$').firstMatch(current);
    final quality = match?.group(1) ?? '';
    _controller.value = TextEditingValue(
      text: '$root$quality',
      selection: TextSelection.collapsed(offset: root.length + quality.length),
    );
  }

  void _chooseQuality(String quality) {
    final current = _controller.text.trim();
    final root =
        RegExp(r'^([A-G](?:#|b)?)').firstMatch(current)?.group(1) ?? 'C';
    _controller.value = TextEditingValue(
      text: '$root$quality',
      selection:
          TextSelection.collapsed(offset: root.length + quality.length),
    );
  }

  void _save() {
    final chord = _controller.text.trim();
    if (chord.isEmpty) return;
    Navigator.pop(
      context,
      ChordEditResult(chord: chord, wordIndex: _wordIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    final words = _words;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 0, 18, 18 + bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.existing == null ? 'Add chord' : 'Correct chord',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  if (widget.existing != null)
                    TextButton.icon(
                      onPressed: () => Navigator.pop(
                        context,
                        ChordEditResult(
                          chord: widget.existing!.chord,
                          wordIndex: _wordIndex,
                          delete: true,
                        ),
                      ),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Color(0xFFFF8295),
                        size: 18,
                      ),
                      label: const Text(
                        'Remove',
                        style: TextStyle(color: Color(0xFFFF9AAA)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Correct the chord, then choose the lyric word where it begins.',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('manual_chord_name'),
                controller: _controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(24),
                ],
                decoration: const InputDecoration(
                  labelText: 'Chord',
                  hintText: 'G, Em, Cadd9, D/F#…',
                  prefixIcon: Icon(Icons.music_note_rounded),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 14),
              const Text(
                'ROOT',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _roots
                    .map(
                      (root) => ActionChip(
                        label: Text(root),
                        onPressed: () => _chooseRoot(root),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 14),
              const Text(
                'QUALITY',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _qualities
                    .map(
                      (quality) => ActionChip(
                        label: Text(quality.$1),
                        onPressed: () => _chooseQuality(quality.$2),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 18),
              const Text(
                'PLACE ABOVE WORD',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              if (words.isEmpty)
                const Text(
                  'This line has no lyric words.',
                  style: TextStyle(color: AppColors.muted),
                )
              else
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: <Widget>[
                    for (var index = 0; index < words.length; index += 1)
                      ChoiceChip(
                        key: Key('chord_word_$index'),
                        selected: _wordIndex == index,
                        label: Text(words[index]),
                        onSelected: (_) => setState(() => _wordIndex = index),
                      ),
                  ],
                ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('save_manual_chord'),
                      onPressed:
                          _controller.text.trim().isEmpty ? null : _save,
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Save chord'),
                    ),
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
