import '../../domain/name_policy.dart';
import '../../domain/studio_draft_models.dart';

/// Why a draft matched, so a result can explain itself instead of just
/// appearing.
enum DraftMatch { name, lyric }

class DraftSearchResult {
  const DraftSearchResult({required this.draft, required this.match, this.lyricSnippet});

  final StudioDraft draft;
  final DraftMatch match;

  /// The part of the transcript that matched, with a little context either
  /// side — the thing that makes "the one where I sang about streetlights"
  /// an actual query.
  final String? lyricSnippet;
}

/// Searches captured ideas by name and by what was sung in them.
///
/// Searching the transcript is the whole point. The reason idea libraries go
/// unused is that audio can't be skimmed: a take you can't identify without
/// playing it is a take you never revisit. Once the words are searchable, a
/// half-remembered line is enough to find the recording.
///
/// Pure, so it can be tested without a widget tree.
List<DraftSearchResult> searchDrafts(List<StudioDraft> drafts, String query) {
  final needle = NamePolicy.normalized(query);
  if (needle.isEmpty) {
    return <DraftSearchResult>[
      for (final draft in drafts) DraftSearchResult(draft: draft, match: DraftMatch.name),
    ];
  }

  final results = <DraftSearchResult>[];
  for (final draft in drafts) {
    if (NamePolicy.normalized(draft.displayName).contains(needle)) {
      results.add(DraftSearchResult(draft: draft, match: DraftMatch.name));
      continue;
    }
    final snippet = lyricSnippetAround(draft.transcriptText, needle);
    if (snippet != null) {
      results.add(DraftSearchResult(
        draft: draft,
        match: DraftMatch.lyric,
        lyricSnippet: snippet,
      ));
    }
  }
  // Name matches first — someone typing a title means the title.
  results.sort((left, right) => left.match.index.compareTo(right.match.index));
  return List<DraftSearchResult>.unmodifiable(results);
}

/// A readable excerpt of [transcript] around the first occurrence of
/// [normalizedNeedle], or null if it isn't there.
///
/// Windowed rather than truncated from the start: the match is the reason
/// the row is on screen, so showing the opening of a four-minute transcript
/// instead would defeat the purpose.
String? lyricSnippetAround(String? transcript, String normalizedNeedle, {int window = 34}) {
  final text = (transcript ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty || normalizedNeedle.isEmpty) return null;
  final index = text.toLowerCase().indexOf(normalizedNeedle);
  if (index == -1) return null;

  var start = index - window;
  var end = index + normalizedNeedle.length + window;
  final leadingCut = start > 0;
  final trailingCut = end < text.length;
  if (start < 0) start = 0;
  if (end > text.length) end = text.length;

  final excerpt = text.substring(start, end).trim();
  return '${leadingCut ? '…' : ''}$excerpt${trailingCut ? '…' : ''}';
}

/// The distinct keys present across [drafts], in a stable order, for filter
/// chips. Only keys that actually occur are offered — a filter for a key you
/// have nothing in is noise.
List<String> availableKeys(List<StudioDraft> drafts) {
  final keys = <String>{
    for (final draft in drafts)
      if ((draft.musicalKey ?? '').trim().isNotEmpty) draft.musicalKey!.trim(),
  };
  final sorted = keys.toList()..sort();
  return List<String>.unmodifiable(sorted);
}
