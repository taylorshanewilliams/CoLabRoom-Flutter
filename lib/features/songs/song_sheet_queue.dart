// The song-sheet queue.
//
// This was the Control Room's brain, and it outlived the Control Room. That
// tab answered one question — which recording do we work out next? — and held
// a permanent quarter of the navigation to do it. In production 19 of 22
// recordings already had their sheet, so the room was almost always a list of
// three, and three items do not earn a destination.
//
// The rules were always the valuable part, and they are unchanged: which pile
// a recording lands in, and which single one leads. What changed is where the
// answer is drawn — a banner on Songs when there is something waiting, and
// nothing at all when there is not. A room should be empty when there is
// nothing to do in it; better still, it should not be a room.

import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart' show SongAnalysisState;

typedef SheetQueueEntry = ({MusicRoom room, SongProject project});

/// What is waiting for a song sheet, worked out before any of it is drawn.
///
/// Pure, so the rules can be tested without a device — which pile a recording
/// lands in, and which single one leads, is the whole design and none of it
/// needs a screen to be true.
class SongSheetQueue {
  const SongSheetQueue._({
    required this.lead,
    required this.leadIsSheet,
    required this.working,
    required this.waiting,
    required this.sheets,
  });

  /// The same queue without the songs somebody has told it to stop asking
  /// about.
  ///
  /// Applied after the queue is built rather than inside it, so the counts
  /// beneath the lead ("2 more waiting") stay true to the pile rather than
  /// to one person's patience — and so a song set aside on a phone is not a
  /// song hidden from the room.
  SongSheetQueue without(Set<String> setAside) {
    if (setAside.isEmpty) return this;
    bool kept(SheetQueueEntry e) => !setAside.contains(e.project.id);

    final keptWaiting = waiting.where(kept).toList(growable: false);
    final keptSheets = sheets.where(kept).toList(growable: false);
    final nowLeadIsSheet = keptWaiting.isEmpty && keptSheets.isNotEmpty;
    return SongSheetQueue._(
      lead: keptWaiting.isNotEmpty
          ? keptWaiting.first
          : (keptSheets.isNotEmpty ? keptSheets.first : null),
      leadIsSheet: nowLeadIsSheet,
      working: working,
      waiting: keptWaiting,
      sheets: keptSheets,
    );
  }

  factory SongSheetQueue.from(List<MusicRoom> rooms) {
    final recordings = <SheetQueueEntry>[
      for (final room in rooms)
        for (final project in room.projects)
          // A song with no recording has nothing this room can do to it.
          if (project.hasAudioReference) (room: room, project: project),
    ]..sort((a, b) => b.project.updatedAt.compareTo(a.project.updatedAt));

    final sheets = <SheetQueueEntry>[];
    final working = <SheetQueueEntry>[];
    final waiting = <SheetQueueEntry>[];
    for (final entry in recordings) {
      switch (entry.project.analysisState) {
        case SongAnalysisState.ready:
          sheets.add(entry);
        case SongAnalysisState.queued:
        case SongAnalysisState.processing:
          working.add(entry);
        // A failed run is not a third pile. It is a recording still waiting
        // for its sheet that happens to have been tried once — so it sits
        // with the others and says so on its own row.
        case SongAnalysisState.uploaded:
        case SongAnalysisState.failed:
        case null:
          waiting.add(entry);
      }
    }

    // One decision rather than a scroll. The newest
    // recording with no sheet is what somebody almost always came here for;
    // when there is none, the last sheet they touched is the next best
    // answer, and it keeps a working account from opening on an empty room.
    final leadIsSheet = waiting.isEmpty && sheets.isNotEmpty;
    final SheetQueueEntry? lead =
        waiting.isNotEmpty
            ? waiting.first
            : (sheets.isNotEmpty ? sheets.first : null);

    return SongSheetQueue._(
      lead: lead,
      leadIsSheet: leadIsSheet,
      working: working,
      waiting: waiting.isEmpty ? waiting : waiting.sublist(1),
      sheets: leadIsSheet ? sheets.sublist(1) : sheets,
    );
  }

  /// The one song to lead with, or null when there is no recording in the
  /// account at all.
  final SheetQueueEntry? lead;

  /// Whether [lead] already has its sheet — which changes what the card
  /// offers, from making one to opening the one that exists.
  final bool leadIsSheet;

  final List<SheetQueueEntry> working;

  /// Waiting and already-made, both with [lead] removed: the same song is
  /// never offered twice.
  final List<SheetQueueEntry> waiting;
  final List<SheetQueueEntry> sheets;

  /// How many songs a person could act on. The number is the point — not the
  /// size of the account.
  int get total =>
      working.length + waiting.length + sheets.length + (lead == null ? 0 : 1);
}
