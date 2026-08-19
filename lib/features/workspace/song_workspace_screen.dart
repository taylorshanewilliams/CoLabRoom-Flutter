import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/project_export_service.dart';
import 'lyric_import_flow.dart';
import 'song_analysis_screen.dart';

enum _VoiceNoteAction { play, rerecord, delete }

enum _SongMenuAction { analyze, print, share }

class SongWorkspaceScreen extends StatefulWidget {
  const SongWorkspaceScreen({required this.projectId, super.key});

  final String projectId;

  @override
  State<SongWorkspaceScreen> createState() => _SongWorkspaceScreenState();
}

class _SongWorkspaceScreenState extends State<SongWorkspaceScreen> with WidgetsBindingObserver {
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _contributionScroll = ScrollController();
  final SpeechToText _speech = SpeechToText();

  AudioRecorder? _voiceRecorder;
  AudioPlayer? _voicePlayer;
  StreamSubscription<void>? _playerCompleteSubscription;
  Timer? _recordingTimer;

  bool _listening = false;
  bool _autoScroll = true;
  bool _importingLyrics = false;
  Color _authorColor = AppColors.orange;
  String? _recordingContributionId;
  String? _savingContributionId;
  String? _loadingVoiceContributionId;
  String? _playingContributionId;
  DateTime? _voiceStartedAt;
  Duration _recordingElapsed = Duration.zero;
  int _lastContributionCount = -1;
  int? _draftIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _playerCompleteSubscription?.cancel();
    _speech.stop();
    final recorder = _voiceRecorder;
    if (recorder != null) {
      unawaited(recorder.cancel());
      unawaited(recorder.dispose());
    }
    final player = _voicePlayer;
    if (player != null) unawaited(player.dispose());
    _composer.dispose();
    _composerFocus.dispose();
    _contributionScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // The on-screen keyboard opening/closing resizes the viewport, which
    // forces an instant, unanimated ScrollPosition correction to stay in
    // bounds. That correction lands *after* the keyboard finishes its own
    // resize animation — after our animated _scrollToBottom() (fired when
    // the new line was added) has already finished — so its abrupt landing
    // is what actually gets seen, overriding the smooth scroll. Re-issue an
    // animated scroll once metrics settle so the final motion stays smooth.
    // Gated on composer focus so an unrelated rotation/resize while reading
    // older lines doesn't yank the view down.
    if (_composerFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _toggleSpeech() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    if (_draftIndex == null) {
      final project = BetaScope.of(context).projectById(widget.projectId);
      _beginDraft(project?.contributions.length ?? 0);
      await Future<void>.delayed(Duration.zero);
    }

    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        setState(() => _listening = status == 'listening');
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _listening = false);
        _showMessage('Speech recognition: ${error.errorMsg}');
      },
    );
    if (!available || !mounted) {
      if (mounted) _showMessage('Speech recognition is unavailable on this device.');
      return;
    }

    setState(() => _listening = true);
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 5),
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
      ),
      onResult: (result) {
        final words = result.recognizedWords;
        _composer.value = TextEditingValue(
          text: words,
          selection: TextSelection.collapsed(offset: words.length),
        );
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _rename(SongProject project) async {
    final controller = BetaScope.of(context);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _RenameProjectDialog(initialTitle: project.title),
    );
    if (value == null) return;
    try {
      await controller.renameSong(project, value);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _addContribution(SongProject project) async {
    final requestedIndex = _draftIndex ?? project.contributions.length;
    final index = requestedIndex < 0
        ? 0
        : requestedIndex > project.contributions.length
            ? project.contributions.length
            : requestedIndex;
    final previous = index > 0 ? project.contributions[index - 1].position : null;
    final next = index < project.contributions.length
        ? project.contributions[index].position
        : null;
    final position = previous == null
        ? (next == null ? 1024.0 : next - 1024)
        : (next == null ? previous + 1024 : (previous + next) / 2);
    try {
      await BetaScope.of(context).addContribution(
        project,
        _composer.text,
        colorValue: _authorColor.toARGB32(),
        position: position,
      );
      _composer.clear();
      if (mounted) setState(() => _draftIndex = null);
      _scrollToBottom();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  void _beginDraft(int index) {
    setState(() {
      _draftIndex = index;
      _composer.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  Future<void> _updateContribution(Contribution contribution, String body) async {
    if (body == contribution.body || body.trim().isEmpty) return;
    try {
      await BetaScope.of(context).updateContribution(contribution, body);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
      rethrow;
    }
  }

  Future<void> _deleteContribution(Contribution contribution) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this line?'),
        content: const Text('Its attached voice note will also be deleted.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await BetaScope.of(context).deleteContribution(contribution);
  }

  Future<void> _exportSong(SongProject project, _SongMenuAction action) async {
    if (action == _SongMenuAction.analyze) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => SongAnalysisScreen(project: project)),
      );
      return;
    }
    try {
      switch (action) {
        case _SongMenuAction.print:
          await ProjectExportService.printSong(project);
          break;
        case _SongMenuAction.share:
          await ProjectExportService.shareSong(project);
          break;
        case _SongMenuAction.analyze:
          break; // handled above
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _importLyrics(SongProject project) async {
    if (_importingLyrics) return;
    setState(() => _importingLyrics = true);
    try {
      final drafts = await showLyricImportFlow(context);
      if (drafts == null || !mounted) return;
      final count = await BetaScope.of(context).importContributions(
        project,
        drafts,
        colorValue: _authorColor.toARGB32(),
      );
      if (!mounted) return;
      _showMessage('Imported $count lyric ${count == 1 ? 'line' : 'lines'}.');
      _scrollToBottom(force: true);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _importingLyrics = false);
    }
  }

  void _scrollToBottom({bool force = false}) {
    // Schedule the scroll for after the next frame rather than bailing out
    // here: at the moment a new contribution lands, the ListView/ScrollView
    // for the (possibly just-built) content may not have attached its
    // ScrollPosition to `_contributionScroll` yet, so checking `hasClients`
    // synchronously caused this to silently no-op on first load and on any
    // rebuild that happens in the same frame the scrollable is (re)created.
    if (!_autoScroll && !force) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_contributionScroll.hasClients) return;
      _contributionScroll.animateTo(
        _contributionScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toggleAutoScroll() {
    setState(() => _autoScroll = !_autoScroll);
    if (_autoScroll) _scrollToBottom(force: true);
  }

  Future<void> _showColorPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Writing color', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('New lines use this color so collaborators are easy to follow.'),
              const SizedBox(height: 18),
              Wrap(
                spacing: 14,
                children: <Color>[
                  AppColors.orange,
                  AppColors.cyan,
                  AppColors.green,
                  const Color(0xFFB993FF),
                ].map((color) {
                  final selected = color == _authorColor;
                  return Semantics(
                    button: true,
                    selected: selected,
                    label: 'Choose writing color',
                    child: InkWell(
                      onTap: () {
                        setState(() => _authorColor = color);
                        Navigator.pop(sheetContext);
                      },
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 20),
                          ],
                        ),
                        child: selected
                            ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                            : null,
                      ),
                    ),
                  );
                }).toList(growable: false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _recordingPath() async {
    final fileName = 'colabroom_voice_${DateTime.now().microsecondsSinceEpoch}.wav';
    if (kIsWeb) return fileName;
    final directory = await getTemporaryDirectory();
    return '${directory.path}/$fileName';
  }

  Future<void> _voiceBulletPressed(
    SongProject project,
    Contribution contribution,
  ) async {
    if (_savingContributionId != null || _loadingVoiceContributionId != null) return;
    if (_recordingContributionId == contribution.id) {
      await _finishVoiceRecording(project, contribution);
      return;
    }
    if (contribution.voiceNote != null) {
      final action = await showModalBottomSheet<_VoiceNoteAction>(
        context: context,
        showDragHandle: true,
        backgroundColor: AppColors.deepNavy,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(
                  _playingContributionId == contribution.id
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  color: AppColors.cyan,
                ),
                title: Text(_playingContributionId == contribution.id ? 'Stop playback' : 'Play voice note'),
                onTap: () => Navigator.pop(context, _VoiceNoteAction.play),
              ),
              ListTile(
                leading: const Icon(Icons.mic_rounded, color: AppColors.cyan),
                title: const Text('Re-record voice note'),
                onTap: () => Navigator.pop(context, _VoiceNoteAction.rerecord),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFF718B)),
                title: const Text('Delete voice note'),
                onTap: () => Navigator.pop(context, _VoiceNoteAction.delete),
              ),
            ],
          ),
        ),
      );
      if (!mounted || action == null) return;
      if (action == _VoiceNoteAction.play) {
        await _toggleVoicePlayback(contribution);
      } else if (action == _VoiceNoteAction.rerecord) {
        await _confirmAndStartVoiceRecording(contribution, replacing: true);
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete voice note?'),
            content: const Text('The lyric line will stay in the project.'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (confirmed == true && mounted) {
          await BetaScope.of(context).deleteVoiceNote(contribution.voiceNote!);
        }
      }
      return;
    }
    if (_recordingContributionId != null) {
      _showMessage('Finish the current voice note before starting another.');
      return;
    }
    await _confirmAndStartVoiceRecording(contribution);
  }

  Future<void> _confirmAndStartVoiceRecording(
    Contribution contribution, {
    bool replacing = false,
  }) async {
    final ready = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(replacing ? 'Ready to re-record?' : 'Ready to record?'),
        content: Text(replacing
            ? 'Your current voice note stays available until the replacement is saved.'
            : 'Recording begins only after you press Start.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not Yet')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Start'),
          ),
        ],
      ),
    );
    if (ready == true && mounted) await _startVoiceRecording(contribution);
  }

  Future<void> _startVoiceRecording(Contribution contribution) async {
    if (_listening) await _toggleSpeech();
    final recorder = _voiceRecorder ??= AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        if (mounted) _showMessage('Microphone permission is needed for voice notes.');
        return;
      }
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: await _recordingPath(),
      );
      if (!mounted) return;
      _voiceStartedAt = DateTime.now();
      setState(() {
        _recordingContributionId = contribution.id;
        _recordingElapsed = Duration.zero;
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _voiceStartedAt == null) return;
        final elapsed = DateTime.now().difference(_voiceStartedAt!);
        setState(() => _recordingElapsed = elapsed);
        if (elapsed >= const Duration(minutes: 3)) {
          final controller = BetaScope.of(context);
          final project = controller.projectById(widget.projectId);
          Contribution? current;
          if (project != null) {
            for (final candidate in project.contributions) {
              if (candidate.id == _recordingContributionId) current = candidate;
            }
          }
          if (project != null && current != null) {
            unawaited(_finishVoiceRecording(project, current));
          }
        }
      });
      _showMessage('Recording voice note — tap the red square to save.');
    } catch (error) {
      if (mounted) _showMessage('Could not start recording: $error');
    }
  }

  Future<void> _finishVoiceRecording(
    SongProject project,
    Contribution contribution,
  ) async {
    final recorder = _voiceRecorder;
    if (recorder == null || _recordingContributionId != contribution.id) return;
    _recordingTimer?.cancel();
    final duration = DateTime.now().difference(_voiceStartedAt ?? DateTime.now());
    setState(() {
      _recordingContributionId = null;
      _savingContributionId = contribution.id;
      _recordingElapsed = Duration.zero;
    });
    try {
      final path = await recorder.stop();
      if (path == null) throw StateError('The recorder did not return a voice note.');
      final bytes = await XFile(path).readAsBytes();
      if (bytes.isEmpty) throw StateError('The voice note was empty.');
      if (!mounted) return;
      await BetaScope.of(context).attachVoiceNote(
        project,
        contribution,
        bytes,
        durationMs: duration.inMilliseconds,
      );
      if (mounted) _showMessage('Voice note attached to this line.');
    } catch (error) {
      if (mounted) _showMessage('Could not save the voice note: $error');
    } finally {
      _voiceStartedAt = null;
      if (mounted) setState(() => _savingContributionId = null);
    }
  }

  Future<void> _toggleVoicePlayback(Contribution contribution) async {
    final note = contribution.voiceNote;
    if (note == null) return;
    final player = _voicePlayer ??= AudioPlayer();
    _playerCompleteSubscription ??= player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingContributionId = null);
    });
    try {
      if (_playingContributionId == contribution.id) {
        await player.stop();
        if (mounted) setState(() => _playingContributionId = null);
        return;
      }
      await player.stop();
      if (!mounted) return;
      setState(() {
        _playingContributionId = null;
        _loadingVoiceContributionId = contribution.id;
      });
      final bytes = await BetaScope.of(context).loadVoiceNote(note);
      await player.play(BytesSource(bytes));
      if (mounted) {
        setState(() {
          _loadingVoiceContributionId = null;
          _playingContributionId = contribution.id;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loadingVoiceContributionId = null);
        _showMessage('Could not play the voice note: $error');
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final project = controller.projectById(widget.projectId);
    final room = controller.roomForProject(widget.projectId);
    if (project == null || room == null) {
      return const Scaffold(body: Center(child: Text('This project is no longer available.')));
    }

    if (_lastContributionCount != project.contributions.length) {
      _lastContributionCount = project.contributions.length;
      _scrollToBottom();
    }

    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape && media.size.width >= 540;
    final keyboardOpen = media.viewInsets.bottom > 0;
    final editor = _ContributionWorkspace(
      project: project,
      bookMode: landscape,
      composer: _composer,
      composerFocus: _composerFocus,
      scrollController: _contributionScroll,
      draftIndex: _draftIndex,
      listening: _listening,
      authorColor: _authorColor,
      recordingContributionId: _recordingContributionId,
      savingContributionId: _savingContributionId,
      loadingVoiceContributionId: _loadingVoiceContributionId,
      playingContributionId: _playingContributionId,
      recordingElapsed: _recordingElapsed,
      onSpeech: _toggleSpeech,
      onSubmit: () => _addContribution(project),
      onBeginDraft: _beginDraft,
      onCancelDraft: () => setState(() {
        _draftIndex = null;
        _composer.clear();
        _composerFocus.unfocus();
      }),
      onUpdate: _updateContribution,
      onDelete: _deleteContribution,
      onVoiceBullet: (contribution) => _voiceBulletPressed(project, contribution),
    );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: landscape
            ? _LandscapeWorkspace(
                key: const Key('workspace_landscape_panel'),
                project: project,
                room: room,
                autoScroll: _autoScroll,
                authorColor: _authorColor,
                importingLyrics: _importingLyrics,
                onBack: () {
                  Navigator.maybePop(context);
                },
                onRename: () => _rename(project),
                onToggleAutoScroll: _toggleAutoScroll,
                onColor: _showColorPicker,
                onImport: () => _importLyrics(project),
                onExport: (action) => _exportSong(project, action),
                editor: editor,
              )
            : Column(
                children: <Widget>[
                  _PortraitProjectHeader(
                    project: project,
                    room: room,
                    compact: keyboardOpen,
                    onBack: () {
                      Navigator.maybePop(context);
                    },
                    onRename: () => _rename(project),
                    onExport: (action) => _exportSong(project, action),
                  ),
                  _WorkspaceToolbar(
                    autoScroll: _autoScroll,
                    authorColor: _authorColor,
                    importingLyrics: _importingLyrics,
                    onToggleAutoScroll: _toggleAutoScroll,
                    onColor: _showColorPicker,
                    onImport: () => _importLyrics(project),
                  ),
                  const Divider(height: 1),
                  Expanded(child: editor),
                ],
              ),
      ),
    );
  }
}

class _PortraitProjectHeader extends StatelessWidget {
  const _PortraitProjectHeader({
    required this.project,
    required this.room,
    required this.compact,
    required this.onBack,
    required this.onRename,
    required this.onExport,
  });

  final SongProject project;
  final MusicRoom room;
  final bool compact;
  final VoidCallback onBack;
  final VoidCallback onRename;
  final ValueChanged<_SongMenuAction> onExport;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: compact ? 52 : 68,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onBack,
            tooltip: 'Back to projects',
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
          ),
          if (!compact) ...<Widget>[
            const _MusicMark(size: 42),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: InkWell(
              onTap: onRename,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            project.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.edit_rounded, size: 14, color: AppColors.cyan),
                      ],
                    ),
                    if (!compact)
                      Text(
                        '${room.icon}  ${room.name}  ·  ${room.members.length} ${room.members.length == 1 ? 'member' : 'members'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<_SongMenuAction>(
            key: const Key('song_options_menu'),
            tooltip: 'Song options',
            onSelected: onExport,
            itemBuilder: (_) => const <PopupMenuEntry<_SongMenuAction>>[
              PopupMenuItem<_SongMenuAction>(
                value: _SongMenuAction.analyze,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.graphic_eq_rounded),
                  title: Text('Analyze & Live Performance'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<_SongMenuAction>(
                value: _SongMenuAction.print,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.print_rounded),
                  title: Text('Send to printer'),
                ),
              ),
              PopupMenuItem<_SongMenuAction>(
                value: _SongMenuAction.share,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.share_rounded),
                  title: Text('Share by text or email'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _LandscapeWorkspace extends StatelessWidget {
  const _LandscapeWorkspace({
    required this.project,
    required this.room,
    required this.autoScroll,
    required this.authorColor,
    required this.importingLyrics,
    required this.onBack,
    required this.onRename,
    required this.onToggleAutoScroll,
    required this.onColor,
    required this.onImport,
    required this.onExport,
    required this.editor,
    super.key,
  });

  final SongProject project;
  final MusicRoom room;
  final bool autoScroll;
  final Color authorColor;
  final bool importingLyrics;
  final VoidCallback onBack;
  final VoidCallback onRename;
  final VoidCallback onToggleAutoScroll;
  final VoidCallback onColor;
  final VoidCallback onImport;
  final ValueChanged<_SongMenuAction> onExport;
  final Widget editor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SizedBox(
          height: 48,
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onBack,
                tooltip: 'Back to projects',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              ),
              Expanded(
                child: InkWell(
                  onTap: onRename,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          project.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '${room.icon} ${room.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('workspace_auto_scroll'),
                onPressed: onToggleAutoScroll,
                tooltip: autoScroll ? 'Turn auto-scroll off' : 'Turn auto-scroll on',
                icon: Icon(
                  Icons.swap_vert_rounded,
                  size: 19,
                  color: autoScroll ? AppColors.cyan : AppColors.muted,
                ),
              ),
              IconButton(
                onPressed: onColor,
                tooltip: 'Choose line color',
                icon: Icon(Icons.circle, size: 16, color: authorColor),
              ),
              IconButton(
                key: const Key('workspace_import_lyrics'),
                onPressed: importingLyrics ? null : onImport,
                tooltip: 'Import lyrics',
                icon: importingLyrics
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_outlined, size: 20),
              ),
              PopupMenuButton<_SongMenuAction>(
                key: const Key('song_options_menu'),
                tooltip: 'Song options',
                onSelected: onExport,
                itemBuilder: (_) => const <PopupMenuEntry<_SongMenuAction>>[
                  PopupMenuItem<_SongMenuAction>(
                    value: _SongMenuAction.analyze,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.graphic_eq_rounded),
                      title: Text('Analyze & Live Performance'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem<_SongMenuAction>(
                    value: _SongMenuAction.print,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.print_rounded),
                      title: Text('Send to printer'),
                    ),
                  ),
                  PopupMenuItem<_SongMenuAction>(
                    value: _SongMenuAction.share,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.share_rounded),
                      title: Text('Share by text or email'),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: editor),
      ],
    );
  }
}

class _MusicMark extends StatelessWidget {
  const _MusicMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: <Color>[AppColors.blue, AppColors.cyan]),
        borderRadius: BorderRadius.circular(size * 0.33),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x2932D4FF), blurRadius: 24)],
      ),
      child: Icon(Icons.music_note_rounded, color: Colors.white, size: size * 0.55),
    );
  }
}

class _WorkspaceToolbar extends StatelessWidget {
  const _WorkspaceToolbar({
    required this.autoScroll,
    required this.authorColor,
    required this.importingLyrics,
    required this.onToggleAutoScroll,
    required this.onColor,
    required this.onImport,
  });

  final bool autoScroll;
  final Color authorColor;
  final bool importingLyrics;
  final VoidCallback onToggleAutoScroll;
  final VoidCallback onColor;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      _ToolPill(
        key: const Key('workspace_auto_scroll'),
        icon: Icons.swap_vert_rounded,
        label: autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
        active: autoScroll,
        onTap: onToggleAutoScroll,
      ),
      _ToolPill(
        icon: Icons.circle,
        iconColor: authorColor,
        label: 'Line color',
        active: false,
        onTap: onColor,
      ),
      _ToolPill(
        key: const Key('workspace_import_lyrics'),
        icon: Icons.file_download_outlined,
        label: importingLyrics ? 'Importing…' : 'Import lyrics',
        active: false,
        onTap: importingLyrics ? null : onImport,
      ),
    ];
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 3, 12, 5),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              actions.first,
              const SizedBox(width: 8),
              actions[1],
              const SizedBox(width: 8),
              actions.last,
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolPill extends StatelessWidget {
  const _ToolPill({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.iconColor,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? (active ? AppColors.cyan : AppColors.muted);
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: active
            ? const <BoxShadow>[BoxShadow(color: Color(0x293AD3FF), blurRadius: 18)]
            : const <BoxShadow>[],
      ),
      child: Material(
        color: active ? const Color(0xFF0C2341) : AppColors.surface,
        shape: StadiumBorder(side: BorderSide(color: active ? AppColors.cyan : AppColors.line)),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: active ? AppColors.text : AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
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

class _RenameProjectDialog extends StatefulWidget {
  const _RenameProjectDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _title;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename Project'),
      content: TextField(
        controller: _title,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) => Navigator.pop(context, value),
        decoration: const InputDecoration(
          helperText: 'Project names are unique across your account.',
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _title.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ContributionWorkspace extends StatelessWidget {
  const _ContributionWorkspace({
    required this.project,
    required this.bookMode,
    required this.composer,
    required this.composerFocus,
    required this.scrollController,
    required this.draftIndex,
    required this.listening,
    required this.authorColor,
    required this.recordingContributionId,
    required this.savingContributionId,
    required this.loadingVoiceContributionId,
    required this.playingContributionId,
    required this.recordingElapsed,
    required this.onSpeech,
    required this.onSubmit,
    required this.onBeginDraft,
    required this.onCancelDraft,
    required this.onUpdate,
    required this.onDelete,
    required this.onVoiceBullet,
  });

  final SongProject project;
  final bool bookMode;
  final TextEditingController composer;
  final FocusNode composerFocus;
  final ScrollController scrollController;
  final int? draftIndex;
  final bool listening;
  final Color authorColor;
  final String? recordingContributionId;
  final String? savingContributionId;
  final String? loadingVoiceContributionId;
  final String? playingContributionId;
  final Duration recordingElapsed;
  final VoidCallback onSpeech;
  final VoidCallback onSubmit;
  final ValueChanged<int> onBeginDraft;
  final VoidCallback onCancelDraft;
  final Future<void> Function(Contribution contribution, String body) onUpdate;
  final Future<void> Function(Contribution contribution) onDelete;
  final ValueChanged<Contribution> onVoiceBullet;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: bookMode ? _buildBook() : _buildPortrait()),
        Positioned(
          right: bookMode ? 10 : 14,
          bottom: bookMode ? 8 : 14,
          child: _TalkToTextButton(
            listening: listening,
            compact: bookMode,
            onPressed: onSpeech,
          ),
        ),
      ],
    );
  }

  Widget _buildPortrait() {
    final lineCount = project.contributions.length;
    return ListView.builder(
      controller: scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 82),
      itemCount: lineCount * 2 + 1,
      itemBuilder: (context, index) {
        if (index.isEven) {
          final insertionIndex = index ~/ 2;
          return _InsertionTarget(
            key: Key('insert_line_$insertionIndex'),
            active: draftIndex == insertionIndex,
            empty: lineCount == 0,
            tail: insertionIndex == lineCount,
            dense: false,
            listening: listening,
            authorColor: authorColor,
            controller: composer,
            focusNode: composerFocus,
            fontSize: 13.25,
            onTap: () => onBeginDraft(insertionIndex),
            onCancel: onCancelDraft,
            onSubmit: onSubmit,
          );
        }
        final contributionIndex = index ~/ 2;
        return _line(project.contributions[contributionIndex], contributionIndex, 13.25);
      },
    );
  }

  Widget _buildBook() {
    final lines = project.contributions;
    if (lines.isEmpty) return _buildPortrait();
    final split = _bookSplitIndex(lines);
    return LayoutBuilder(
      builder: (context, constraints) {
        final leftRows = _estimatedRows(lines.take(split));
        final rightRows = _estimatedRows(lines.skip(split));
        final busiestPage = leftRows > rightRows ? leftRows : rightRows;
        final availableHeight = (constraints.maxHeight - 18).clamp(120.0, double.infinity).toDouble();
        final fontSize = (availableHeight / ((busiestPage + 1) * 1.35)).clamp(9.25, 12.0).toDouble();
        final estimatedHeight = (busiestPage + 2) * fontSize * 1.4;
        final contentHeight = estimatedHeight > availableHeight ? estimatedHeight : availableHeight;
        return SingleChildScrollView(
          key: const Key('workspace_lyric_book'),
          controller: scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 44),
          child: SizedBox(
            height: contentHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: _bookColumn(
                    key: const Key('workspace_book_left'),
                    start: 0,
                    end: split,
                    fontSize: fontSize,
                    includeBoundaryDraft: true,
                  ),
                ),
                const VerticalDivider(width: 22, indent: 4, endIndent: 4),
                Expanded(
                  child: _bookColumn(
                    key: const Key('workspace_book_right'),
                    start: split,
                    end: lines.length,
                    fontSize: fontSize,
                    includeBoundaryDraft: split == 0,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bookColumn({
    required Key key,
    required int start,
    required int end,
    required double fontSize,
    required bool includeBoundaryDraft,
  }) {
    final children = <Widget>[];
    for (var index = start; index < end; index++) {
      final boundaryBelongsHere = index != start || start == 0 || includeBoundaryDraft;
      if (boundaryBelongsHere) {
        children.add(_bookInsertion(index, fontSize));
      }
      children.add(_line(project.contributions[index], index, fontSize));
    }
    if (includeBoundaryDraft || end == project.contributions.length) {
      children.add(_bookInsertion(end, fontSize));
    }
    children.add(
      Expanded(
        child: InkWell(
          onTap: () => onBeginDraft(end),
          child: const SizedBox(height: 52),
        ),
      ),
    );
    return Column(key: key, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _bookInsertion(int index, double fontSize) {
    return _InsertionTarget(
      key: Key('insert_line_$index'),
      active: draftIndex == index,
      empty: project.contributions.isEmpty,
      tail: false,
      dense: true,
      listening: listening,
      authorColor: authorColor,
      controller: composer,
      focusNode: composerFocus,
      fontSize: fontSize,
      onTap: () => onBeginDraft(index),
      onCancel: onCancelDraft,
      onSubmit: onSubmit,
    );
  }

  Widget _line(Contribution contribution, int index, double fontSize) {
    return _ContributionLine(
      key: ValueKey<String>(contribution.id),
      contribution: contribution,
      compact: bookMode,
      fontSize: fontSize,
      recording: recordingContributionId == contribution.id,
      saving: savingContributionId == contribution.id,
      loading: loadingVoiceContributionId == contribution.id,
      playing: playingContributionId == contribution.id,
      recordingElapsed: recordingElapsed,
      onSave: (body) => onUpdate(contribution, body),
      onDelete: () => onDelete(contribution),
      onInsertAfter: () => onBeginDraft(index + 1),
      onVoiceBullet: () => onVoiceBullet(contribution),
    );
  }

  int _bookSplitIndex(List<Contribution> lines) {
    if (lines.length <= 1) return lines.length;
    final total = _estimatedRows(lines);
    var used = 0;
    for (var index = 0; index < lines.length - 1; index++) {
      used += _lineWeight(lines[index]);
      if (used >= total / 2) return index + 1;
    }
    return (lines.length + 1) ~/ 2;
  }

  int _estimatedRows(Iterable<Contribution> lines) {
    var rows = 0;
    for (final line in lines) {
      rows += _lineWeight(line);
    }
    return rows;
  }

  int _lineWeight(Contribution line) {
    final wrappedRows = (line.body.length / 46).ceil();
    return (wrappedRows < 1 ? 1 : wrappedRows) + (line.kind == ContributionKind.section ? 1 : 0);
  }
}

class _InsertionTarget extends StatelessWidget {
  const _InsertionTarget({
    required this.active,
    required this.empty,
    required this.tail,
    required this.dense,
    required this.listening,
    required this.authorColor,
    required this.controller,
    required this.focusNode,
    required this.fontSize,
    required this.onTap,
    required this.onCancel,
    required this.onSubmit,
    super.key,
  });

  final bool active;
  final bool empty;
  final bool tail;
  final bool dense;
  final bool listening;
  final Color authorColor;
  final TextEditingController controller;
  final FocusNode focusNode;
  final double fontSize;
  final VoidCallback onTap;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    if (active) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 2 : 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            SizedBox(
              width: dense ? 25 : 30,
              height: dense ? 32 : 38,
              child: Center(
                child: Container(
                  width: dense ? 6 : 7,
                  height: dense ? 6 : 7,
                  decoration: BoxDecoration(
                    color: authorColor,
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(color: authorColor.withValues(alpha: 0.18), blurRadius: 13),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: TextField(
                key: const Key('song_line_composer'),
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => onSubmit(),
                style: TextStyle(fontSize: fontSize, height: 1.24),
                decoration: InputDecoration(
                  hintText: listening ? 'Listening…' : 'Write here…',
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              tooltip: 'Cancel line',
              icon: const Icon(Icons.close_rounded, size: 19),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onSubmit,
              tooltip: 'Save line',
              icon: const Icon(Icons.check_rounded, color: AppColors.cyan),
            ),
          ],
        ),
      );
    }
    if (empty) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: dense ? 120 : 220,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.edit_note_rounded, color: AppColors.cyan, size: 28),
                  const SizedBox(height: 8),
                  const Text(
                    'Tap anywhere to write',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(height: dense ? 5 : (tail ? 150 : 8)),
    );
  }
}

class _ContributionLine extends StatefulWidget {
  const _ContributionLine({
    required this.contribution,
    required this.compact,
    required this.fontSize,
    required this.recording,
    required this.saving,
    required this.loading,
    required this.playing,
    required this.recordingElapsed,
    required this.onSave,
    required this.onDelete,
    required this.onInsertAfter,
    required this.onVoiceBullet,
    super.key,
  });

  final Contribution contribution;
  final bool compact;
  final double fontSize;
  final bool recording;
  final bool saving;
  final bool loading;
  final bool playing;
  final Duration recordingElapsed;
  final Future<void> Function(String body) onSave;
  final Future<void> Function() onDelete;
  final VoidCallback onInsertAfter;
  final VoidCallback onVoiceBullet;

  @override
  State<_ContributionLine> createState() => _ContributionLineState();
}

class _ContributionLineState extends State<_ContributionLine> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  Timer? _saveDebounce;
  bool _dirty = false;
  bool _savingEdit = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.contribution.body);
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ContributionLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && !_dirty && widget.contribution.body != _controller.text) {
      _controller.text = widget.contribution.body;
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_focusNode.hasFocus) unawaited(_save());
  }

  void _changed(String _) {
    _dirty = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () => unawaited(_save()));
  }

  Future<void> _save({bool moveNext = false}) async {
    _saveDebounce?.cancel();
    if (_savingEdit) return;
    final body = _controller.text;
    if (!_dirty || body == widget.contribution.body) {
      _dirty = false;
      if (moveNext) widget.onInsertAfter();
      return;
    }
    if (body.trim().isEmpty) {
      if (moveNext) {
        await widget.onDelete();
      } else if (!_focusNode.hasFocus) {
        _controller.text = widget.contribution.body;
        _dirty = false;
      }
      return;
    }
    _dirty = false;
    setState(() => _savingEdit = true);
    try {
      await widget.onSave(body);
      if (moveNext) widget.onInsertAfter();
    } catch (_) {
      _dirty = true;
    } finally {
      if (mounted) setState(() => _savingEdit = false);
      if (mounted && _dirty) {
        _saveDebounce = Timer(const Duration(milliseconds: 500), () => unawaited(_save()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contribution = widget.contribution;
    final color = Color(contribution.colorValue);
    final note = contribution.voiceNote;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.compact ? 25 : 34),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: widget.compact ? 0 : 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _VoiceBullet(
              key: Key('voice_bullet_${contribution.id}'),
              color: color,
              authorName: contribution.authorName,
              compact: widget.compact,
              hasVoiceNote: note != null,
              recording: widget.recording,
              saving: widget.saving,
              loading: widget.loading,
              playing: widget.playing,
              onPressed: widget.onVoiceBullet,
            ),
            SizedBox(width: widget.compact ? 3 : 5),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: Key('edit_line_${contribution.id}'),
                      controller: _controller,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: null,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      cursorColor: AppColors.cyan,
                      onChanged: _changed,
                      onSubmitted: (_) => unawaited(_save(moveNext: true)),
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: contribution.kind == ContributionKind.section
                            ? widget.fontSize - 0.35
                            : widget.fontSize,
                        height: widget.compact ? 1.16 : 1.24,
                        fontWeight: contribution.kind == ContributionKind.section
                            ? FontWeight.w800
                            : FontWeight.w400,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 5),
                      ),
                    ),
                  ),
                  if (widget.recording)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        _formatDuration(widget.recordingElapsed),
                        style: const TextStyle(
                          color: Color(0xFFFF718B),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (_focusNode.hasFocus)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      onPressed: _savingEdit ? null : widget.onDelete,
                      tooltip: 'Delete line',
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Color(0x99FF718B),
                        size: 17,
                      ),
                    )
                  else if (_savingEdit)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 7),
                      child: SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
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

class _VoiceBullet extends StatelessWidget {
  const _VoiceBullet({
    required this.color,
    required this.authorName,
    required this.compact,
    required this.hasVoiceNote,
    required this.recording,
    required this.saving,
    required this.loading,
    required this.playing,
    required this.onPressed,
    super.key,
  });

  final Color color;
  final String authorName;
  final bool compact;
  final bool hasVoiceNote;
  final bool recording;
  final bool saving;
  final bool loading;
  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final busy = saving || loading;
    final active = hasVoiceNote || recording || busy;
    final activeColor = recording ? const Color(0xFFFF718B) : AppColors.cyan;
    final action = recording
        ? 'Stop and attach voice note'
        : hasVoiceNote
            ? (playing ? 'Stop voice note' : 'Play voice note')
            : 'Record a voice note';
    final tooltip = '$authorName · $action';
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: busy ? null : onPressed,
          radius: compact ? 18 : 21,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: compact ? 24 : 28,
            height: compact ? 24 : 28,
            decoration: BoxDecoration(
              color: active ? activeColor.withValues(alpha: 0.13) : Colors.transparent,
              shape: BoxShape.circle,
              border: active ? Border.all(color: activeColor.withValues(alpha: 0.7)) : null,
              boxShadow: active
                  ? <BoxShadow>[
                      BoxShadow(color: activeColor.withValues(alpha: 0.22), blurRadius: 19),
                    ]
                  : <BoxShadow>[
                      BoxShadow(color: color.withValues(alpha: 0.16), blurRadius: 14),
                    ],
            ),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
                    )
                  : recording
                      ? Icon(
                          Icons.stop_rounded,
                          color: const Color(0xFFFF718B),
                          size: compact ? 15 : 18,
                        )
                      : hasVoiceNote
                          ? Icon(
                              playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                              color: AppColors.cyan,
                              size: compact ? 16 : 19,
                            )
                          : Container(
                              width: compact ? 6 : 7,
                              height: compact ? 6 : 7,
                              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                            ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TalkToTextButton extends StatelessWidget {
  const _TalkToTextButton({
    required this.listening,
    required this.compact,
    required this.onPressed,
  });

  final bool listening;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      key: const Key('talk_to_text_button'),
      duration: const Duration(milliseconds: 180),
      height: compact ? 38 : 42,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: <Color>[AppColors.blue, AppColors.cyan]),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x3532D4FF), blurRadius: 26, spreadRadius: 1),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  listening ? Icons.stop_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: compact ? 17 : 18,
                ),
                if (!compact) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    listening ? 'Listening…' : 'Talk to Text',
                    style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
