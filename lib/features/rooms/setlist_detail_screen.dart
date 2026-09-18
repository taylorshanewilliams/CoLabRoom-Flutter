import 'dart:async';

import 'package:flutter/material.dart';
import '../../app/routes.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/music_reference.dart' show samePitch;
import '../../services/song_analysis_service.dart';
import '../../widgets/app_surface.dart';
import '../workspace/song_workspace_screen.dart';
import '../../services/user_facing_error.dart';
import '../../services/kept_songs.dart';
import '../../services/song_search.dart';
import 'setlist_pack.dart';

enum _SetlistMenuAction { print, sharePdf, share, rename, delete, keepHere }

/// The analysis behind a song, or null when there is none to be had.
typedef LoadAnalysis = Future<SongAnalysisBundle?> Function(String projectId);

class SetlistDetailScreen extends StatefulWidget {
  const SetlistDetailScreen({
    required this.setlistId,
    this.loadAnalysis,
    this.analysisService,
    super.key,
  });

  final String setlistId;

  /// Where each song's analysis comes from. The app reads it from the
  /// analysis service; a test hands in what it likes.
  final LoadAnalysis? loadAnalysis;

  /// The service itself, for what needs a real answer rather than a lenient
  /// one: keeping the set on this phone fetches each sheet through it and
  /// stops, saying so, on the first that cannot be fetched. Null in
  /// production.
  final SongAnalysisService? analysisService;

  @override
  State<SetlistDetailScreen> createState() => _SetlistDetailScreenState();
}

class _SetlistDetailScreenState extends State<SetlistDetailScreen> {
  // Optimistic local order so drag-and-drop feels instant instead of
  // waiting on a round trip to the backend before the list visibly moves.
  List<String>? _localOrder;

  /// Each song's analysis, once it has arrived. What the key, the tempo, the
  /// count-in and the form fall back to when the band has said nothing on
  /// the set, and what the charts in the pack are built from.
  final Map<String, SongAnalysisBundle?> _analyses = <String, SongAnalysisBundle?>{};
  final Map<String, Future<SongAnalysisBundle?>> _loads = <String, Future<SongAnalysisBundle?>>{};

  SongAnalysisService get _analysis => widget.analysisService ?? SongAnalysisService();

  /// Which of this phone's kept songs are known so far, or null until the
  /// first read -- and on the web for good, where the menu says nothing
  /// about keeping.
  Set<String>? _keptIds;

  @override
  void initState() {
    super.initState();
    unawaited(_loadKept());
  }

  Future<void> _loadKept() async {
    if (!KeptSongs.supported) return;
    final ids = await _analysis.kept.keptIds();
    if (mounted) setState(() => _keptIds = ids);
  }

  Future<SongAnalysisBundle?> _fromService(String projectId) async {
    try {
      return await _analysis.load(projectId);
    } catch (_) {
      // Non-fatal: the row says what the band wrote and nothing more, and
      // the pack lists the song without a chart.
      return null;
    }
  }

  /// The analysis for one song, asked for once and kept.
  Future<SongAnalysisBundle?> _analysisFor(String projectId) {
    return _loads.putIfAbsent(projectId, () async {
      final bundle = await (widget.loadAnalysis ?? _fromService)(projectId);
      if (mounted) setState(() => _analyses[projectId] = bundle);
      return bundle;
    });
  }

  /// The pack's songs, with every analysis in hand.
  Future<List<SetlistPackSong>> _packSongs(Setlist setlist, List<SongProject> projects) async {
    final analyses = <String, SongAnalysisBundle?>{
      for (final project in projects) project.id: await _analysisFor(project.id),
    };
    return SetlistPack.songs(setlist: setlist, projects: projects, analyses: analyses);
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final setlist = controller.setlistById(widget.setlistId);
    if (setlist == null) {
      return const Scaffold(body: Center(child: Text('This setlist is no longer available.')));
    }

    // Resync local order whenever the underlying song set changes (songs
    // added/removed elsewhere), but keep it otherwise so a drag isn't
    // clobbered by an in-flight reload from a previous reorder.
    if (_localOrder == null || _localOrder!.toSet().difference(setlist.projectIds.toSet()).isNotEmpty ||
        setlist.projectIds.toSet().difference(_localOrder!.toSet()).isNotEmpty) {
      _localOrder = List<String>.from(setlist.projectIds);
    }
    final order = _localOrder!;

    final projects = <SongProject>[];
    for (final projectId in order) {
      final project = controller.projectById(projectId);
      if (project != null) projects.add(project);
    }
    for (final project in projects) {
      unawaited(_analysisFor(project.id));
    }

    /// What the band says about one song here, given back as null once it
    /// has landed or as the sentence to show when it did not.
    Future<String?> save(SetlistSong song) async {
      try {
        await controller.saveSetlistSong(setlist, song);
        return null;
      } on ArgumentError catch (error) {
        return error.message.toString();
      } on StateError catch (error) {
        return error.message;
      } catch (error) {
        return reportAndDescribe(error, service: 'app', stage: 'set_song', route: 'Setlist');
      }
    }

    Future<void> editSong(SongProject project) async {
      // The hints are the song's own answers, and the analysis they come
      // from may still be on its way when the tune icon is tapped a moment
      // after arriving. The sheet opens at once with what is known and fills
      // the hints in when the rest lands, rather than making the tap wait on
      // the network (review, 18 September 2026).
      final songSaysLater =
          _analysisFor(project.id).then((bundle) => setSongFacts(null, project, bundle));
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.deepNavy,
        builder: (_) => _SetSongSheet(
          project: project,
          entry: setlist.songFor(project.id) ?? SetlistSong(projectId: project.id),
          songSays: setSongFacts(null, project, _analyses[project.id]),
          songSaysLater: songSaysLater,
          onSave: save,
        ),
      );
    }

    // Called via onReorderItem rather than the deprecated onReorder, which
    // means newIndex already accounts for the item being lifted out at
    // oldIndex — the classic `if (newIndex > oldIndex) newIndex -= 1` fixup
    // is not just unnecessary here, it would move the item one slot short.
    void reorder(int oldIndex, int newIndex) {
      final updated = List<String>.from(order);
      final movedId = updated.removeAt(oldIndex);
      updated.insert(newIndex, movedId);
      setState(() => _localOrder = updated);
      unawaited(controller.reorderSetlistProjects(setlist, updated));
    }

    Future<void> rename() async {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => _RenameSetDialog(initialName: setlist.name),
      );
      if (name == null || name.trim().isEmpty || name.trim() == setlist.name) return;
      try {
        await controller.renameSetlist(setlist, name);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reportAndDescribe(error, service: 'app', stage: 'rename_set', route: 'Setlist'))));
        }
      }
    }

    Future<void> delete() async {
      final sure = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Delete ${setlist.name}?'),
          content: const Text('The set goes. The songs in it stay exactly where they are.'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep it')),
            FilledButton(
              key: const Key('delete_set_confirm'),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete set'),
            ),
          ],
        ),
      );
      if (sure != true || !context.mounted) return;
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      try {
        await controller.deleteSetlist(setlist);
        navigator.pop();
        messenger.showSnackBar(SnackBar(content: Text('${setlist.name} is deleted. Its songs are untouched.')));
      } catch (error) {
        messenger.showSnackBar(SnackBar(content: Text(reportAndDescribe(error, service: 'app', stage: 'delete_set', route: 'Setlist'))));
      }
    }

    // Kept on this phone means every song in it is. A set half here would
    // open in the van with holes in it, so the state says so until the
    // whole of it is here, and keeping it again fetches only what is not.
    final keptIds = _keptIds;
    final keptAll = keptIds != null &&
        projects.isNotEmpty &&
        projects.every((project) => keptIds.contains(project.id));

    /// Keeps every song in the set on this phone, or takes them all off.
    ///
    /// Stops at the first song whose sheet cannot be fetched and says which,
    /// rather than keeping the rest and calling the set kept. What was
    /// fetched before it stays, so trying again is cheap.
    Future<void> keepHere() async {
      final messenger = ScaffoldMessenger.of(context);
      final kept = _analysis.kept;
      if (keptAll) {
        for (final project in projects) {
          await kept.remove(project.id);
        }
        await _loadKept();
        // In place of whatever is showing, never queued behind it: "is on
        // this phone" still on screen would otherwise hold this back for
        // four seconds and say the opposite of what just happened.
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('${setlist.name} is no longer kept on this phone.')));
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Keeping ${setlist.name} on this phone…')));
      for (final project in projects) {
        try {
          final sheet = await _analysis.load(project.id);
          await kept.keep(project, sheet, onProgress: (stage) {
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text('${project.title}: $stage')));
          });
        } catch (error) {
          await _loadKept();
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(isConnectivityFailure(error)
                  ? 'No connection, so ${project.title} was not kept. Try again where there is signal.'
                  : 'Could not keep ${project.title}: ${reportAndDescribe(error, service: 'app', stage: 'keep_set', route: 'Setlist')}'),
            ));
          return;
        }
      }
      await _loadKept();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${setlist.name} is on this phone.')));
    }

    Future<void> export(_SetlistMenuAction action) async {
      if (action == _SetlistMenuAction.rename) return rename();
      if (action == _SetlistMenuAction.delete) return delete();
      if (action == _SetlistMenuAction.keepHere) return keepHere();
      try {
        final songs = await _packSongs(setlist, projects);
        switch (action) {
          case _SetlistMenuAction.print:
            await SetlistPack.print(setlist, songs);
            break;
          case _SetlistMenuAction.sharePdf:
            await SetlistPack.share(setlist, songs);
            break;
          case _SetlistMenuAction.share:
            await SetlistPack.shareText(setlist, songs);
            break;
          case _SetlistMenuAction.rename:
          case _SetlistMenuAction.delete:
          case _SetlistMenuAction.keepHere:
            break;
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reportAndDescribe(error, service: 'app', route: 'Setlist'))));
        }
      }
    }

    Future<void> addSongs() async {
      final selected = await showModalBottomSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.deepNavy,
        builder: (_) => _AddSongsSheet(
          rooms: controller.rooms,
          existingIds: setlist.projectIds.toSet(),
        ),
      );
      if (selected == null || selected.isEmpty) return;
      try {
        await controller.addProjectsToSetlist(setlist, selected);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reportAndDescribe(error, service: 'app', route: 'Setlist'))));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(setlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            onPressed: addSongs,
            tooltip: 'Add songs',
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          PopupMenuButton<_SetlistMenuAction>(
            tooltip: 'Setlist options',
            onSelected: export,
            itemBuilder: (_) => <PopupMenuEntry<_SetlistMenuAction>>[
              // Both the printer and the PDF get the pack: the running order
              // with each song's key, tempo, count-in, form, ending and note,
              // then a chord chart per song in the key the set does it in.
              // One file a stand-in can read on the night (Every Musician,
              // Same Song, 17 September 2026).
              const PopupMenuItem<_SetlistMenuAction>(
                key: Key('print_set'),
                value: _SetlistMenuAction.print,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.print_rounded),
                  title: Text('Send to printer'),
                ),
              ),
              const PopupMenuItem<_SetlistMenuAction>(
                key: Key('share_set_pdf'),
                value: _SetlistMenuAction.sharePdf,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.picture_as_pdf_outlined),
                  title: Text('Share as PDF, with a chart per song'),
                ),
              ),
              const PopupMenuItem<_SetlistMenuAction>(
                value: _SetlistMenuAction.share,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.share_rounded),
                  title: Text('Share by text or email'),
                ),
              ),
              // The set for the van: every song's words, sheet and recording
              // on this phone, where Perform finds them without signal. A
              // convenience of this device and nothing the band is told.
              if (keptIds != null && projects.isNotEmpty)
                PopupMenuItem<_SetlistMenuAction>(
                  key: const Key('keep_set_here'),
                  value: _SetlistMenuAction.keepHere,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(keptAll ? Icons.phone_android_rounded : Icons.download_for_offline_outlined),
                    title: Text(keptAll ? 'On this phone' : 'Keep this set on this phone'),
                    subtitle: Text(keptAll ? 'Tap to take it off again' : 'Every song, for where there is no signal'),
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<_SetlistMenuAction>(
                key: Key('rename_set'),
                value: _SetlistMenuAction.rename,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.edit_rounded),
                  title: Text('Rename set'),
                ),
              ),
              const PopupMenuItem<_SetlistMenuAction>(
                key: Key('delete_set'),
                value: _SetlistMenuAction.delete,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline_rounded, color: Color(0xFFFF9AA9)),
                  title: Text('Delete set', style: TextStyle(color: Color(0xFFFF9AA9))),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: projects.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.queue_music_rounded, size: 44, color: AppColors.cyan),
                    const SizedBox(height: 12),
                    const Text('This setlist is ready for songs.'),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: addSongs,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Songs'),
                    ),
                  ],
                ),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
              buildDefaultDragHandles: false,
              itemCount: projects.length,
              onReorderItem: reorder,
              itemBuilder: (context, index) {
                final project = projects[index];
                // What this set says about the song, with the song's own
                // answers where the band has said nothing.
                final facts = setSongFacts(
                  setlist.songFor(project.id),
                  project,
                  _analyses[project.id],
                );
                return ReorderableDragStartListener(
                  key: ValueKey<String>(project.id),
                  index: index,
                  child: Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: AppSurface(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
                    child: Row(
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.drag_indicator_rounded, color: AppColors.muted),
                        ),
                        SizedBox(
                          width: 26,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: AppColors.cyan,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const Icon(Icons.music_note_rounded, color: AppColors.cyan),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                settings: RouteSettings(
                                    name: AppRoutes.song(project.id)),
                                builder: (_) => SongWorkspaceScreen(projectId: project.id),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    project.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  if (facts.line.isNotEmpty)
                                    Text(
                                      facts.line,
                                      key: Key('set_song_line_${project.id}'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppColors.muted, fontSize: 12),
                                    ),
                                  if (facts.note != null)
                                    Text(
                                      facts.note!,
                                      key: Key('set_song_note_${project.id}'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppColors.text, fontSize: 12),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: Key('set_song_${project.id}'),
                          onPressed: () => editSong(project),
                          tooltip: 'Key, tempo and notes',
                          icon: const Icon(Icons.tune_rounded, color: AppColors.muted),
                        ),
                        IconButton(
                          onPressed: () => controller.removeProjectFromSetlist(setlist, project.id),
                          tooltip: 'Remove from setlist',
                          icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  ),
                );
              },
            ),
      ),
    );
  }
}

/// What the band does with one song in this set.
///
/// Every field stands in front of what the song says, and an empty one means
/// "use what the song says" — so the hint in each field is the song's own
/// answer, and the sheet needs no explaining beyond one line. The key is
/// picked from chips rather than typed, the way "Where the 1 is" picks it,
/// because a key typed with a typo is a chart in the wrong key on the night.
///
/// Nothing here is written to the song. Doing a song down a tone on
/// Saturday has not changed what key the song is in (Every Musician, Same
/// Song, 17 September 2026).
class _SetSongSheet extends StatefulWidget {
  const _SetSongSheet({
    required this.project,
    required this.entry,
    required this.songSays,
    required this.songSaysLater,
    required this.onSave,
  });

  final SongProject project;

  /// What the band has said so far.
  final SetlistSong entry;

  /// What the song says on its own, for the hints: what is known as the
  /// sheet opens, and the same again once the song's analysis has arrived.
  final SetSongFacts songSays;
  final Future<SetSongFacts> songSaysLater;

  /// Completes with null once it has landed, or with the sentence to show
  /// when it did not — said here, where the person tapped, because a
  /// snackbar would land underneath this sheet.
  final Future<String?> Function(SetlistSong song) onSave;

  @override
  State<_SetSongSheet> createState() => _SetSongSheetState();
}

class _SetSongSheetState extends State<_SetSongSheet> {
  late String? _key = widget.entry.key;
  late final TextEditingController _bpm = TextEditingController(
    text: widget.entry.bpm == null ? '' : _tempoText(widget.entry.bpm!),
  );
  late final TextEditingController _countIn = TextEditingController(text: widget.entry.countIn ?? '');
  late final TextEditingController _form = TextEditingController(text: widget.entry.form ?? '');
  late final TextEditingController _ending = TextEditingController(text: widget.entry.ending ?? '');
  late final TextEditingController _note = TextEditingController(text: widget.entry.note ?? '');
  bool _saving = false;
  String? _refused;

  /// The song's own answers, replaced once when the analysis lands.
  late SetSongFacts _songSays = widget.songSays;

  @override
  void initState() {
    super.initState();
    unawaited(widget.songSaysLater.then((facts) {
      if (mounted) setState(() => _songSays = facts);
    }));
  }

  /// The twelve, written the way a chart writes them: the flat side of the
  /// circle in flats, because a song is far more often in E♭ than in D♯.
  /// Stored with ASCII accidentals, which is what 0157 accepts and every key
  /// parser here reads, and drawn with printed ones.
  static const List<String> _theTwelve = <String>[
    'C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B',
  ];

  static String _printed(String stored) =>
      stored.replaceAll('#', '♯').replaceAll('b', '♭');

  static String _tempoText(double bpm) =>
      bpm == bpm.roundToDouble() ? bpm.round().toString() : bpm.toString();

  @override
  void dispose() {
    _bpm.dispose();
    _countIn.dispose();
    _form.dispose();
    _ending.dispose();
    _note.dispose();
    super.dispose();
  }

  /// The chip that spells [key]'s root — matched by pitch, so a key that
  /// arrived as A♯ lights the B♭ chip. Null for no key, or one nothing here
  /// can read.
  static String? _chipFor(String? key) {
    final said = key?.trim();
    if (said == null || said.isEmpty) return null;
    final root = RegExp(r'^([A-G][#b]?)').firstMatch(said)?.group(1);
    if (root == null) return null;
    for (final candidate in _theTwelve) {
      if (samePitch(candidate, root)) return candidate;
    }
    return null;
  }

  /// The root of the key the set says, as the chips spell it.
  String? get _rootNow => _chipFor(_key);

  /// Where Major or Minor starts from before a root has been picked: the
  /// song's own root, so a band that only wants to say "we do it minor" gets
  /// G minor over a song in G, not C minor (review, 18 September 2026).
  String get _rootToStartFrom => _rootNow ?? _chipFor(_songSays.songKey) ?? 'C';

  bool get _minorNow => (_key ?? '').toLowerCase().contains('minor');

  void _pick(String root, bool minor) {
    setState(() {
      _key = '$root ${minor ? 'minor' : 'major'}';
      _refused = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final tempoText = _bpm.text.trim();
    double? bpm;
    if (tempoText.isNotEmpty) {
      bpm = double.tryParse(tempoText);
      if (bpm == null) {
        setState(() => _refused = 'A tempo is a number, like 96.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _refused = null;
    });
    final refused = await widget.onSave(SetlistSong(
      projectId: widget.project.id,
      key: _key,
      bpm: bpm,
      countIn: _countIn.text,
      form: _form.text,
      ending: _ending.text,
      note: _note.text,
    ));
    if (!mounted) return;
    if (refused == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _refused = refused;
    });
  }

  @override
  Widget build(BuildContext context) {
    final songKey = _songSays.songKey;
    final tempo = _songSays.bpm;
    return SafeArea(
      top: false,
      child: Padding(
        // Above the keyboard, or the last two fields cannot be reached.
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.project.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 3),
              const Text(
                'In this set. Leave anything empty to use what the song says.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 18),
              const _FieldLabel('Key'),
              Text(
                songKey == null
                    ? 'The song has no key yet.'
                    : "The song's key is $songKey.",
                style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final root in _theTwelve)
                    _KeyChip(
                      label: _printed(root),
                      itemKey: Key('set_key_$root'),
                      selected: _rootNow == root,
                      onTap: () => _pick(root, _minorNow),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final minor in <bool>[false, true])
                    _KeyChip(
                      label: minor ? 'Minor' : 'Major',
                      itemKey: Key('set_key_${minor ? 'minor' : 'major'}'),
                      selected: _key != null && minor == _minorNow,
                      onTap: () => _pick(_rootToStartFrom, minor),
                    ),
                ],
              ),
              if (_key != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('set_key_use_songs'),
                    onPressed: () => setState(() => _key = null),
                    child: const Text("Use the song's key"),
                  ),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('set_song_bpm'),
                controller: _bpm,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Tempo',
                  hintText: tempo == null || tempo <= 0
                      ? 'bpm'
                      : '${tempo.round()} bpm, from the recording',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('set_song_count_in'),
                controller: _countIn,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Count-in',
                  hintText: _songSays.countIn ?? 'Who counts it, and how',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('set_song_form'),
                controller: _form,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Form',
                  hintText: _songSays.form ?? 'Intro · Verse · Chorus',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('set_song_ending'),
                controller: _ending,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Ending',
                  hintText: 'Cold, ritard, tag the chorus',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('set_song_note'),
                controller: _note,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Straight into the next one',
                  isDense: true,
                ),
              ),
              if (_refused != null) ...<Widget>[
                const SizedBox(height: 10),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _refused!,
                    key: const Key('set_song_refused'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('set_song_save'),
                    onPressed: _saving ? null : () => unawaited(_save()),
                    child: const Text('Save'),
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

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.text,
        fontSize: 13,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({
    required this.label,
    required this.itemKey,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Key itemKey;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold.withValues(alpha: 0.16) : AppColors.raised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.gold.withValues(alpha: 0.55) : AppColors.line,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.gold : AppColors.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _AddSongsSheet extends StatefulWidget {
  const _AddSongsSheet({required this.rooms, required this.existingIds});

  final List<MusicRoom> rooms;
  final Set<String> existingIds;

  @override
  State<_AddSongsSheet> createState() => _AddSongsSheetState();
}

class _AddSongsSheetState extends State<_AddSongsSheet> {
  final Set<String> _selected = <String>{};
  final _query = TextEditingController();
  String? _roomId;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.text.trim().toLowerCase();
    final available = widget.rooms
        .where((room) => _roomId == null || room.id == _roomId)
        .expand((room) => room.projects)
        .where((project) =>
            !widget.existingIds.contains(project.id) &&
            (normalizedQuery.isEmpty || songMatch(project, normalizedQuery) != null))
        .toList(growable: false);
    return SafeArea(
      top: false,
      // An AlertDialog's shrink-wrapped ListView had no bounded ancestor to
      // shrink-wrap within (a Dialog doesn't force one), so with enough
      // songs it tried to size itself to the sum of every row — taller
      // than the dialog could ever be, which is a real overflow the Flutter
      // framework can't recover from cleanly. Bottom sheets need the same
      // care: an explicit fixed height plus Expanded (not shrinkWrap) is
      // what actually gives the list something bounded to scroll within.
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Add Songs', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                  hintText: 'Search songs',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    _RoomFilterChip(
                      label: 'All rooms',
                      selected: _roomId == null,
                      onTap: () => setState(() => _roomId = null),
                    ),
                    for (final room in widget.rooms) ...<Widget>[
                      const SizedBox(width: 8),
                      _RoomFilterChip(
                        label: room.name,
                        selected: _roomId == room.id,
                        onTap: () => setState(() => _roomId = room.id),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: available.isEmpty
                    ? Center(
                        child: Text(
                          normalizedQuery.isNotEmpty || _roomId != null
                              ? 'No matching songs.'
                              : 'Every available song is already in this setlist.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: available.length,
                        itemBuilder: (context, index) {
                          final project = available[index];
                          return CheckboxListTile(
                            key: ValueKey<String>(project.id),
                            value: _selected.contains(project.id),
                            title: Text(project.title),
                            onChanged: (selected) => setState(() {
                              if (selected ?? false) {
                                _selected.add(project.id);
                              } else {
                                _selected.remove(project.id);
                              }
                            }),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected),
                    child: const Text('Add'),
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

class _RoomFilterChip extends StatelessWidget {
  const _RoomFilterChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.raised,
      side: BorderSide(color: selected ? AppColors.cyan : AppColors.line),
    );
  }
}

class _RenameSetDialog extends StatefulWidget {
  const _RenameSetDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameSetDialog> createState() => _RenameSetDialogState();
}

class _RenameSetDialogState extends State<_RenameSetDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename set'),
      content: TextField(
        key: const Key('rename_set_field'),
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(context, value);
        },
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => FilledButton(
            key: const Key('rename_set_save'),
            onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, _name.text),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
