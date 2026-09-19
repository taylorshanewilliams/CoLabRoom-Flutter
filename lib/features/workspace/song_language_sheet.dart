import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/song_language.dart';

/// Says what the song is sung in for the whole room, or takes the answer
/// away again with a null.
///
/// Completes with null once it has landed, or with the sentence to show when
/// it did not — the same shape as [SayTheKey], and for the same reason: the
/// sheet is where somebody tapped, so the sheet is where a refusal is said.
typedef SayTheLanguage = Future<String?> Function(String? tag);

/// What language is this song sung in?
///
/// Every Musician, Same Song, 17 September 2026, world traditions item 3.
/// It is asked because the page cannot be laid out without the answer: which
/// way the lines run and what a chord sits over are decided by the language,
/// and neither can be worked out from the words themselves without guessing
/// at somebody. So it is asked, once, of the people who can answer for the
/// song — and a song nobody answers for is laid out exactly as before.
///
/// **Searched, not scrolled.** Seventy-odd languages is a long list to look
/// down and a short list to type into, and the search reads the name a
/// language has for itself as well as the English one: somebody looking for
/// 中文 should not have to know that English calls it Chinese.
///
/// **A language not on the list is still a language.** Typing a tag — 'yo',
/// 'haw', 'qu' — offers it as typed. The list is what this app can put a
/// name beside, and nothing more than that.
Future<void> showSongLanguageSheet(
  BuildContext context, {
  required String? language,
  required SayTheLanguage onLanguage,
  List<String> suggested = const <String>[],
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _SongLanguageSheet(
      language: language,
      onLanguage: onLanguage,
      suggested: suggested,
    ),
  );
}

class _SongLanguageSheet extends StatefulWidget {
  const _SongLanguageSheet({
    required this.language,
    required this.onLanguage,
    required this.suggested,
  });

  final String? language;
  final SayTheLanguage onLanguage;
  final List<String> suggested;

  @override
  State<_SongLanguageSheet> createState() => _SongLanguageSheetState();
}

class _SongLanguageSheetState extends State<_SongLanguageSheet> {
  final TextEditingController _search = TextEditingController();
  String _typed = '';
  bool _saving = false;
  String? _refused;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() => _typed = _search.text.trim());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The languages this search names, or — with nothing typed — the ones the
  /// writer's own profile suggests, then the whole list.
  ///
  /// The suggestions are only ever an order. Nothing about a song is taken
  /// from a profile: somebody who sings in three languages has not said
  /// which one this song is, and the tap is still theirs to make (0156).
  List<SongLanguage> get _shown {
    final typed = _typed.toLowerCase();
    if (typed.isEmpty) {
      final first = <SongLanguage>[
        for (final tag in widget.suggested)
          for (final language in songLanguages)
            if (language.tag == tag) language,
      ];
      return <SongLanguage>[
        ...first,
        for (final language in songLanguages)
          if (!first.contains(language)) language,
      ];
    }
    return <SongLanguage>[
      for (final language in songLanguages)
        if (language.name.toLowerCase().contains(typed) ||
            language.endonym.toLowerCase().contains(typed) ||
            language.tag == typed)
          language,
    ];
  }

  /// A tag somebody typed that no name in the list matches — offered as
  /// itself, so a language this app cannot name is still a language it can
  /// carry.
  String? get _typedTag {
    if (_typed.isEmpty) return null;
    final tag = languageTagTyped(_typed);
    if (tag == null) return null;
    for (final language in songLanguages) {
      if (language.tag == tag) return null;
    }
    return tag;
  }

  Future<void> _say(String? tag) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _refused = null;
    });
    final refused = await widget.onLanguage(tag);
    if (!mounted) return;
    if (refused == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _refused = refused;
    });
  }

  @override
  Widget build(BuildContext context) {
    final said = widget.language;
    final shown = _shown;
    final typedTag = _typedTag;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'What is this song sung in?',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Everybody in the room reads the song the way this lays '
                    'it out.',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('song_language_search'),
                    controller: _search,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search_rounded, size: 18),
                      hintText: 'Find a language',
                    ),
                  ),
                  if (_refused != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      _refused!,
                      key: const Key('song_language_refused'),
                      style: const TextStyle(
                        color: Color(0xFFFF9AA9),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                children: <Widget>[
                  // Taking the answer away is only offered once there is one
                  // to take away. It is where it is because it is the answer
                  // that undoes the others, not one of them.
                  if (said != null)
                    _LanguageRow(
                      key: const Key('song_language_not_said'),
                      label: 'Not said',
                      note: 'Laid out the way it was before anybody said',
                      here: false,
                      onTap: _saving ? null : () => _say(null),
                    ),
                  if (typedTag != null)
                    _LanguageRow(
                      key: const Key('song_language_typed_tag'),
                      label: typedTag,
                      note: 'Use this tag as typed',
                      here: said == typedTag,
                      onTap: _saving ? null : () => _say(typedTag),
                    ),
                  for (final language in shown)
                    _LanguageRow(
                      key: Key('song_language_${language.tag}'),
                      label: language.shown,
                      here: said == language.tag,
                      onTap: _saving ? null : () => _say(language.tag),
                    ),
                  if (shown.isEmpty && typedTag == null)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 14, 12, 4),
                      child: Text(
                        'No language here by that name. A tag works too — '
                        '"yo" for Yoruba, "haw" for Hawaiian.',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.label,
    required this.here,
    required this.onTap,
    this.note,
    super.key,
  });

  final String label;
  final String? note;
  final bool here;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
      child: Material(
        color:
            here ? AppColors.cyan.withValues(alpha: 0.10) : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: here ? AppColors.cyan.withValues(alpha: 0.5) : AppColors.line,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: here ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
