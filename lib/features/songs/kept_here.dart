import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import '../../domain/music_models.dart';
import '../../services/song_analysis_service.dart';
import '../../widgets/app_surface.dart';
import '../workspace/live_performance_screen.dart';
import '../../widgets/note_that_fits.dart';

/// The songs kept on this phone, each with the one thing that can be done
/// with it when nothing else will load: perform it.
///
/// This lives on the screen that says the workspace could not be opened,
/// because that is where a phone with no signal actually lands. The app
/// waits for the library before it builds anything else, so in the van there
/// is no Songs tab to put a list on and no song to open a menu from -- only
/// that screen, a Try again button, and until now nothing else (Every
/// Musician, Same Song, 17 September 2026). A song kept for exactly this
/// moment has to be reachable from exactly this place.
///
/// Draws nothing at all when nothing is kept, which is nearly everybody:
/// the screen it sits on is then the screen it always was. And it lists only
/// what the account signed in on this phone kept (see KeptSongs), so it says
/// nothing on a phone somebody else has signed in to.
class KeptHere extends StatefulWidget {
  const KeptHere({this.analysisService, super.key});

  /// Where the kept songs live and where Perform gets the recording. Null in
  /// production; a test hands in one with no disk under it.
  final SongAnalysisService? analysisService;

  @override
  State<KeptHere> createState() => _KeptHereState();
}

class _KeptHereState extends State<KeptHere> {
  List<SongProject> _songs = const <SongProject>[];

  SongAnalysisService get _analysis => widget.analysisService ?? SongAnalysisService();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final songs = await _analysis.kept.list();
    if (mounted) setState(() => _songs = songs);
  }

  /// Perform, from the copy on this phone: the words and the sheet read
  /// from disk here, and the recording found there by the analysis service,
  /// which asks the kept copy before it asks anything else.
  ///
  /// Nothing practised here is kept as a mark. A mark goes to the server,
  /// and the reason this screen is showing is that the server cannot be
  /// reached; promising to remember and then not would be worse than not
  /// promising.
  Future<void> _perform(SongProject song) async {
    final kept = await _analysis.kept.load(song.id);
    if (!mounted) return;
    if (kept == null) {
      ScaffoldMessenger.of(context).showNote('That song is no longer on this phone.');
      unawaited(_load());
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.songLive(song.id)),
        builder: (_) => LivePerformanceScreen(
          project: kept.project,
          analysis: kept.sheet,
          analysisService: widget.analysisService,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_songs.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('kept_here'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'On this phone',
            style: TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        for (final song in _songs)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: InkWell(
              key: Key('kept_song_${song.id}'),
              onTap: () => unawaited(_perform(song)),
              borderRadius: BorderRadius.circular(19),
              child: AppSurface(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.phone_android_rounded, color: AppColors.cyan, size: 19),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Perform it without signal',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppColors.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.play_circle_outline_rounded, color: AppColors.cyan, size: 20),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
