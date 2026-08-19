import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';
import '../workspace/song_workspace_screen.dart';
import 'new_song_flow.dart';

class MusicTemplatesScreen extends StatelessWidget {
  const MusicTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);

    Future<void> startSongwriting() async {
      final project = await showNewSongFlow(context, controller);
      if (project != null && context.mounted) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => SongWorkspaceScreen(projectId: project.id),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Music')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
        children: <Widget>[
          Text('Choose a project type', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 5),
          const Text('Music is the focused first beta.'),
          const SizedBox(height: 18),
          BloomTap(
            onTap: startSongwriting,
            borderRadius: BorderRadius.circular(19),
            child: AppSurface(
              child: Row(
                children: <Widget>[
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          Color(0x7A2B6FFF),
                          Color(0x382B6FFF),
                          Color(0x082B6FFF),
                        ],
                      ),
                    ),
                    child: const Icon(Icons.music_note_rounded, color: AppColors.cyan),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Songwriting',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                        ),
                        SizedBox(height: 3),
                        Text('Lyrics, sections, and shared ideas.'),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
