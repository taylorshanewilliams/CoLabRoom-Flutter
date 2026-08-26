import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';
import '../workspace/song_analysis_screen.dart';

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
class ControlRoomScreen extends StatelessWidget {
  const ControlRoomScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final songs = <({MusicRoom room, SongProject project})>[
      for (final room in controller.rooms)
        for (final project in room.projects) (room: room, project: project),
    ]..sort((a, b) => b.project.updatedAt.compareTo(a.project.updatedAt));

    // Songs with a recording can be worked out; songs without cannot, and
    // saying so is kinder than listing them and refusing.
    final ready = songs.where((s) => s.project.hasAudioReference).toList();
    final waiting = songs.where((s) => !s.project.hasAudioReference).toList();

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
        if (songs.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _NothingYet(),
          )
        else ...<Widget>[
          if (ready.isNotEmpty) ...<Widget>[
            const _Heading('Ready to work out'),
            _SongList(entries: ready),
          ],
          if (waiting.isNotEmpty) ...<Widget>[
            const _Heading('Needs a recording first'),
            _SongList(entries: waiting, dimmed: true),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 90)),
        ],
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 8),
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
  const _SongList({required this.entries, this.dimmed = false});

  final List<({MusicRoom room, SongProject project})> entries;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      sliver: SliverList.separated(
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _SongRow(
            room: entry.room,
            project: entry.project,
            dimmed: dimmed,
          );
        },
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.room,
    required this.project,
    required this.dimmed,
  });

  final MusicRoom room;
  final SongProject project;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final lines = project.contributions.length;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SongAnalysisScreen(project: project),
        ),
      ),
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
                dimmed ? Icons.mic_none_rounded : Icons.graphic_eq_rounded,
                size: 18,
                color: dimmed ? AppColors.muted : AppColors.gold,
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
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: dimmed ? AppColors.muted : AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      '${room.icon} ${room.name}',
                      if (lines > 0)
                        '$lines ${lines == 1 ? 'line' : 'lines'}',
                      if (dimmed) 'no recording yet',
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5),
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
              'Songs show up here once they exist. Record something in the '
              'Studio first — that part is free, and this room is for after '
              'the playing is done.',
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
