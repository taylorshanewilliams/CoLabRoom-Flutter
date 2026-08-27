import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart' show SongAnalysisState;
import '../../widgets/app_surface.dart';
import '../workspace/song_analysis_screen.dart';

typedef ControlRoomEntry = ({MusicRoom room, SongProject project});

/// What the room decided to show, worked out before any of it is drawn.
///
/// Separated from [ControlRoomScreen.build] so the rules can be tested
/// without a device — which piles a song lands in, and which single song the
/// room leads with, is the whole design of this tab.
class ControlRoomPlan {
  const ControlRoomPlan._({
    required this.lead,
    required this.leadIsSheet,
    required this.working,
    required this.waiting,
    required this.sheets,
  });

  factory ControlRoomPlan.from(List<MusicRoom> rooms) {
    final recordings = <ControlRoomEntry>[
      for (final room in rooms)
        for (final project in room.projects)
          // A song with no recording has nothing this room can do to it.
          if (project.hasAudioReference) (room: room, project: project),
    ]..sort((a, b) => b.project.updatedAt.compareTo(a.project.updatedAt));

    final sheets = <ControlRoomEntry>[];
    final working = <ControlRoomEntry>[];
    final waiting = <ControlRoomEntry>[];
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

    // The room opens on one decision rather than a scroll. The newest
    // recording with no sheet is what somebody almost always came here for;
    // when there is none, the last sheet they touched is the next best
    // answer, and it keeps a working account from opening on an empty room.
    final leadIsSheet = waiting.isEmpty && sheets.isNotEmpty;
    final ControlRoomEntry? lead = waiting.isNotEmpty
        ? waiting.first
        : (sheets.isNotEmpty ? sheets.first : null);

    return ControlRoomPlan._(
      lead: lead,
      leadIsSheet: leadIsSheet,
      working: working,
      waiting: waiting.isEmpty ? waiting : waiting.sublist(1),
      sheets: leadIsSheet ? sheets.sublist(1) : sheets,
    );
  }

  /// The song the room leads with, or null when there is no recording in the
  /// account at all.
  final ControlRoomEntry? lead;

  /// Whether [lead] already has its sheet — which changes what the card
  /// offers, from making one to opening the one that exists.
  final bool leadIsSheet;

  final List<ControlRoomEntry> working;

  /// Waiting and already-made, both with [lead] removed: the room never
  /// shows the same song twice.
  final List<ControlRoomEntry> waiting;
  final List<ControlRoomEntry> sheets;

  /// How many songs a person could act on here. The number is the point of
  /// the room, not the size of the account.
  int get total =>
      working.length + waiting.length + sheets.length + (lead == null ? 0 : 1);
}

/// Where a song goes to be finished.
///
/// The Studio is the live room — record, layer, hand it to your mates, all
/// free. This is the other half of a real facility: the room you go to when
/// the playing is done and you want to know what you actually played. Chords,
/// key, structure, the words in time.
///
/// It is a tab rather than a button inside a song because the split is the
/// point. Analysis costs real money to run, and it used to be reached through
/// the Studio — the one place somebody goes to lay an idea down — so every
/// route to putting a riff on a phone pointed at the GPU. Separating the two
/// rooms makes the free thing free-looking and the expensive thing
/// deliberate, and it does it with a floor plan rather than a warning.
///
/// **It shows recordings, not songs.** It used to list the whole account,
/// including songs with no recording at all, under a heading saying they
/// needed one — a list of things this room cannot act on, which is what made
/// it read as an inventory rather than a room. Those live in Songs. What is
/// left is one question, asked once: which recording do we work out? A single
/// song leads, and the rest fall into the two piles that question has —
/// waiting for a sheet, and already has one.
class ControlRoomScreen extends StatelessWidget {
  const ControlRoomScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final plan = ControlRoomPlan.from(BetaScope.of(context).rooms);
    final lead = plan.lead;

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 6),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('The Control Room',
                    style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 6),
                const Text(
                  'Listen back and find out what you played. Chords, key, '
                  'structure, and the words in time.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
            ),
          ),
        ),
        if (lead == null)
          const SliverFillRemaining(hasScrollBody: false, child: _NothingYet())
        else ...<Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
            sliver: SliverToBoxAdapter(
              child: _LeadCard(entry: lead, isSheet: plan.leadIsSheet),
            ),
          ),
          if (plan.working.isNotEmpty) ...<Widget>[
            const _Heading('Working it out'),
            _SongList(entries: plan.working),
          ],
          if (plan.waiting.isNotEmpty) ...<Widget>[
            const _Heading('Ready for a song sheet'),
            _SongList(entries: plan.waiting),
          ],
          if (plan.sheets.isNotEmpty) ...<Widget>[
            const _Heading('Your song sheets'),
            _SongList(entries: plan.sheets),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 90)),
        ],
      ],
    );
  }
}

void _open(BuildContext context, SongProject project) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SongAnalysisScreen(project: project),
    ),
  );
}

/// The one song the room leads with.
///
/// Gold, because gold is what this app spends on the things that cost real
/// machinery, and this is the door to the only one of those. It does not
/// start the analysis itself — the button that does lives on the song, with
/// the depth choice beside it, and a room that could start a paid job from a
/// list is a room that could start one by accident.
class _LeadCard extends StatelessWidget {
  const _LeadCard({required this.entry, required this.isSheet});

  final ControlRoomEntry entry;
  final bool isSheet;

  @override
  Widget build(BuildContext context) {
    final project = entry.project;
    final failed = project.analysisState == SongAnalysisState.failed;
    return InkWell(
      key: const Key('control_room_lead'),
      onTap: () => _open(context, project),
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.42)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              isSheet ? 'PICK UP WHERE YOU LEFT OFF' : 'NEXT UP',
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              project.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                height: 1.1,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${entry.room.icon} ${entry.room.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Icon(
                  isSheet ? Icons.menu_book_rounded : Icons.description_outlined,
                  color: AppColors.gold,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        isSheet ? 'Open the song sheet' : 'Make the song sheet',
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        isSheet
                            ? 'Chords, key, and the words in time'
                            // That the last run did not finish is the whole
                            // reason this row differs: it is not a state you
                            // should have to open the song to discover.
                            : failed
                                ? 'Last run didn’t finish — worth another go'
                                : 'Listens and writes it down',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.gold, size: 22),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
      sliver: SliverToBoxAdapter(
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

class _SongList extends StatelessWidget {
  const _SongList({required this.entries});

  final List<ControlRoomEntry> entries;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      sliver: SliverList.separated(
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _SongRow(entry: entries[index]),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({required this.entry});

  final ControlRoomEntry entry;

  @override
  Widget build(BuildContext context) {
    final project = entry.project;
    final state = project.analysisState;
    final ready = state == SongAnalysisState.ready;
    final busy = state == SongAnalysisState.queued ||
        state == SongAnalysisState.processing;
    final lines = project.contributions.length;

    return InkWell(
      onTap: () => _open(context, project),
      borderRadius: BorderRadius.circular(19),
      child: AppSurface(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.raised,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                ready
                    ? Icons.menu_book_rounded
                    : busy
                        ? Icons.hourglass_bottom_rounded
                        : Icons.graphic_eq_rounded,
                size: 18,
                color: ready ? AppColors.gold : AppColors.cyan,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      '${entry.room.icon} ${entry.room.name}',
                      if (busy) 'working it out…',
                      if (state == SongAnalysisState.failed) 'didn’t finish',
                      if (ready && lines > 0)
                        '$lines ${lines == 1 ? 'line' : 'lines'}',
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.muted, size: 20),
          ],
        ),
      ),
    );
  }
}

class _NothingYet extends StatelessWidget {
  const _NothingYet();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 34),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.tune_rounded, size: 34, color: AppColors.line),
            const SizedBox(height: 14),
            const Text(
              'Nothing to work out yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'This room works from a recording. Lay one down in the Studio '
              'first — that part is free — and it will be waiting here when '
              'you want to know what you played.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.muted, fontSize: 12.5, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
