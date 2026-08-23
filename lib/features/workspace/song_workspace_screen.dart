import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/project_export_service.dart';
import '../../services/song_analysis_service.dart';
import '../../widgets/invite_collaborator_dialog.dart';
import 'continuous_song_editor.dart';
import 'live_performance_screen.dart';
import 'lyric_import_flow.dart';
import 'song_analysis_screen.dart';

enum _VoiceNoteAction { play, rerecord, delete }

/// Actions reachable from the song screen's overflow menu.
///
/// Deliberately does *not* include analyze/record/perform any more: those
/// three are the verbs a musician came to this screen for, so they live in
/// the always-visible toolbar instead. They used to appear in both places
/// under two different names — the "Recording" pill and the "Analyze Song"
/// menu item pushed the exact same screen.
enum _SongMenuAction { importLyrics, invite, color, print, share }

class SongWorkspaceScreen extends StatefulWidget {
  const SongWorkspaceScreen({required this.projectId, super.key});

  final String projectId;

  @override
  State<SongWorkspaceScreen> createState() => _SongWorkspaceScreenState();
}

class _SongWorkspaceScreenState extends State<SongWorkspaceScreen> with WidgetsBindingObserver {
  final ScrollController _contributionScroll = ScrollController();
  final ContinuousSongEditorController _continuousController = ContinuousSongEditorController();
  final SpeechToText _speech = SpeechToText();

  AudioRecorder? _voiceRecorder;
  AudioPlayer? _voicePlayer;
  StreamSubscription<void>? _playerCompleteSubscription;
  Timer? _recordingTimer;
  int? _dictationStart;

  bool _listening = false;
  bool _autoScroll = true;
  bool _importingLyrics = false;
  bool _voiceActionBusy = false;
  String? _recordingContributionId;
  String? _savingContributionId;
  String? _loadingVoiceContributionId;
  String? _playingContributionId;
  DateTime? _voiceStartedAt;
  int _lastContributionCount = -1;
  SongAnalysisBundle? _analysisBundle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadAnalysisBundle());
  }

  /// Best-effort, non-blocking — lets the toolbar show whether this project
  /// already has a reference recording attached, without needing to open
  /// Analyze first. Not a substitute for a real multi-recording history
  /// (that needs a schema change), just visibility into the one recording
  /// the current model supports.
  Future<void> _loadAnalysisBundle() async {
    try {
      final bundle = await SongAnalysisService().load(widget.projectId);
      if (mounted) setState(() => _analysisBundle = bundle);
    } catch (_) {
      // Non-fatal: the toolbar just won't show a recording indicator.
    }
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
    _continuousController.dispose();
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
    // Gated on editor focus so an unrelated rotation/resize while reading
    // older lines doesn't yank the view down.
    if (_continuousController.focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _toggleSpeech() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      _dictationStart = null;
      return;
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

    // Dictate as a fresh line at the end of the document rather than trying
    // to track an arbitrary mid-document cursor position: simpler, and
    // matches how dictation always used to start a brand-new draft line.
    final textController = _continuousController.text;
    final existing = textController.text;
    if (existing.isNotEmpty && !existing.endsWith('\n')) {
      final withNewline = '$existing\n';
      textController.value = TextEditingValue(
        text: withNewline,
        selection: TextSelection.collapsed(offset: withNewline.length),
      );
    }
    _dictationStart = textController.text.length;

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
        final start = _dictationStart;
        if (start == null || !mounted) return;
        final base = textController.text.substring(0, start.clamp(0, textController.text.length));
        final newText = base + result.recognizedWords;
        textController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newText.length),
        );
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

  /// The signed-in member's own display color for [room], as assigned by
  /// the backend (accept_room_invitation_by_id / set_my_room_color) —
  /// falls back to AppColors.orange only if the member row can't be found
  /// yet (e.g. room still loading).
  Color _authorColorFor(MusicRoom? room) {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (room != null && userId != null) {
      for (final member in room.members) {
        if (member.userId == userId) return Color(member.colorValue);
      }
    }
    return AppColors.orange;
  }

  /// Reconciles the flowing document's [lines] against [project]'s existing
  /// contributions positionally (index-for-index) — matching how
  /// ContinuousSongEditor's own voice-note tap handling maps a visual line
  /// index straight to `project.contributions[index]`. A line whose content
  /// differs from the contribution at that position gets its body updated
  /// in place (preserving id/color/voice note); new trailing lines become
  /// new contributions in the author's color; contributions beyond the end
  /// of the new line list are deleted. Mid-document inserts/deletes shift
  /// every following contribution's body rather than its identity — the
  /// same approximation the widget's own voice-note mapping already makes.
  Future<void> _saveDocument(SongProject project, List<String> lines) async {
    final controller = BetaScope.of(context);
    final contributions = project.contributions;
    final room = controller.roomForProject(project.id);
    final authorColorValue = _authorColorFor(room).toARGB32();
    final count = lines.length > contributions.length ? lines.length : contributions.length;
    try {
      for (var i = 0; i < count; i += 1) {
        final hasLine = i < lines.length;
        final hasContribution = i < contributions.length;
        if (hasLine && hasContribution) {
          final stored = lines[i].isEmpty ? blankStoredLine : lines[i];
          if (stored != contributions[i].body) {
            await controller.repository.updateContribution(
              contribution: contributions[i],
              body: stored,
            );
          }
        } else if (hasLine) {
          final stored = lines[i].isEmpty ? blankStoredLine : lines[i];
          final basePosition = contributions.isEmpty ? 0.0 : contributions.last.position;
          await controller.repository.addContribution(
            project: project,
            body: stored,
            colorValue: authorColorValue,
            position: basePosition + 1024 * (i - contributions.length + 1),
          );
        } else {
          await controller.repository.deleteContribution(contributions[i]);
        }
      }
    } finally {
      await controller.load();
    }
  }

  Future<void> _openLivePerformance(SongProject project) async {
    // Live Performance is reachable straight from the project regardless
    // of whether the song has been analyzed yet — it falls back to manual
    // scroll speeds when there's no synced timing. Best-effort load the
    // analysis bundle so Synced mode is available when it has already been
    // run; a failed/missing load shouldn't block entry.
    SongAnalysisBundle? bundle;
    try {
      bundle = await SongAnalysisService().load(project.id);
    } catch (_) {
      bundle = null;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LivePerformanceScreen(project: project, analysis: bundle),
        fullscreenDialog: true,
      ),
    );
  }

  /// Opens the analysis screen — the chord/lyric/stem breakdown of this
  /// song's recording. [autoRecord] jumps straight into capturing a new take
  /// rather than landing on the summary.
  Future<void> _openAnalysis(SongProject project, {bool autoRecord = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SongAnalysisScreen(project: project, autoRecord: autoRecord),
        fullscreenDialog: true,
      ),
    );
    unawaited(_loadAnalysisBundle());
  }

  Future<void> _exportSong(SongProject project, _SongMenuAction action) async {
    if (action == _SongMenuAction.importLyrics) {
      await _importLyrics(project);
      return;
    }
    if (action == _SongMenuAction.color) {
      _showColorPicker();
      return;
    }
    if (action == _SongMenuAction.invite) {
      await _inviteToSong(project);
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
        case _SongMenuAction.importLyrics:
        case _SongMenuAction.invite:
        case _SongMenuAction.color:
          break; // handled above
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  /// Invites someone to just this one song rather than the whole Room —
  /// the narrower alternative to the Room's own "Invite collaborator",
  /// which grants every song in the Room at once.
  Future<void> _inviteToSong(SongProject project) async {
    final draft = await showDialog<InviteDraft>(
      context: context,
      builder: (_) => InviteCollaboratorDialog(
        title: 'Invite to This Song',
        subtitle: 'They\'ll get access to "${project.title}" only — not the rest of this Room.',
      ),
    );
    if (draft == null || !mounted) return;
    try {
      final result =
          await BetaScope.of(context).createProjectInvite(project, draft.email, role: draft.role);
      if (!mounted) return;
      if (result.matchedAccount) {
        _showMessage('Invite sent — ${draft.email} will see it in their Invites tab.');
      } else {
        await showInviteReadyDialog(context, email: draft.email, code: result.code);
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
      // Let every closing route (the source-picker sheet, and the review
      // dialog on top of it) fully settle before importing — a large batch
      // of new lines rebuilds a big chunk of the tree, and doing that while
      // an exit transition is still animating can trip a Flutter debug-only
      // InheritedElement assertion (harmless in release, where asserts are
      // stripped, but still worth avoiding). A single endOfFrame wasn't
      // enough (too early) and a fixed real-time delay wasn't reliable
      // either (transition length varies by device/animation curve) — wait
      // out several actual rendered frames instead, which tracks real
      // completion rather than guessing a duration.
      for (var frame = 0; frame < 8; frame += 1) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      final room = BetaScope.of(context).roomForProject(project.id);
      final count = await BetaScope.of(context).importContributions(
        project,
        drafts,
        colorValue: _authorColorFor(room).toARGB32(),
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

  Future<void> _showColorPicker() async {
    final room = BetaScope.of(context).roomForProject(widget.projectId);
    if (room == null) return;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final currentColorValue = _authorColorFor(room).toARGB32();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
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
              const Text(
                'Each member has one color in this Room, so collaborators are easy to follow.',
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: AppColors.memberPalette.map((color) {
                  final colorValue = color.toARGB32();
                  final selected = colorValue == currentColorValue;
                  final takenByOther = room.members.any(
                    (member) => member.userId != currentUserId && member.colorValue == colorValue,
                  );
                  return Semantics(
                    button: true,
                    enabled: !takenByOther,
                    selected: selected,
                    label: takenByOther ? 'Color already used by another member' : 'Choose writing color',
                    child: InkWell(
                      onTap: takenByOther
                          ? null
                          : () async {
                              if (!selected) {
                                try {
                                  await BetaScope.of(context).setMemberColor(room, colorValue);
                                } catch (error) {
                                  if (mounted) _showMessage(error.toString());
                                  return;
                                }
                              }
                              if (mounted) Navigator.pop(sheetContext);
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
                            BoxShadow(
                              color: color.withValues(alpha: takenByOther ? 0.08 : 0.22),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                        child: Opacity(
                          opacity: takenByOther ? 0.35 : 1,
                          child: selected
                              ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                              : takenByOther
                                  ? const Icon(Icons.lock_outline_rounded, color: Colors.white, size: 16)
                                  : null,
                        ),
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
    // Nothing else here gates re-entrancy until a recording actually starts
    // (_recordingContributionId only gets set once the mic is live), so
    // rapid repeated taps on the same bullet — or the debounced document
    // save in _voiceTap taking a moment before this even fires — could each
    // independently open their own confirmation dialog/action sheet,
    // stacking duplicate ones. That's the same bug that made "Remove
    // recording" look frozen on the analysis screen.
    if (_voiceActionBusy) return;
    _voiceActionBusy = true;
    try {
      await _voiceBulletAction(project, contribution);
    } finally {
      if (mounted) _voiceActionBusy = false;
    }
  }

  Future<void> _voiceBulletAction(
    SongProject project,
    Contribution contribution,
  ) async {
    if (contribution.voiceNote != null) {
      final action = await showModalBottomSheet<_VoiceNoteAction>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
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
          // showDialog defaults to the root navigator, but this app also
          // has a nested workspace Navigator (see workspace_shell.dart).
          // Popping with the outer `context` (instead of this builder's own
          // dialogContext) pops the wrong navigator's top route — it closes
          // this screen instead of the dialog, leaving the dialog itself
          // orphaned on top and blocking input. Looks like "goes back a
          // screen and freezes."
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete voice note?'),
            content: const Text('The lyric line will stay in the project.'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
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
      // showDialog defaults to the root navigator, but this app also has a
      // nested workspace Navigator (see workspace_shell.dart). Popping with
      // the outer `context` (instead of this builder's own dialogContext)
      // pops the wrong navigator's top route — it closes this screen
      // instead of the dialog, leaving the dialog itself orphaned on top
      // and blocking input. This was the actual cause of "tap the bullet's
      // record button, it goes back a screen and freezes" — not a
      // re-entrancy issue.
      builder: (dialogContext) => AlertDialog(
        title: Text(replacing ? 'Ready to re-record?' : 'Ready to record?'),
        content: Text(replacing
            ? 'Your current voice note stays available until the replacement is saved.'
            : 'Recording begins only after you press Start.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Not Yet')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Start'),
          ),
        ],
      ),
    );
    if (ready == true && mounted) await _startVoiceRecording(contribution);
  }

  Future<void> _startVoiceRecording(Contribution contribution) async {
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
      setState(() => _recordingContributionId = contribution.id);
      _recordingTimer?.cancel();
      // The timer exists solely for the three-minute auto-stop below. It
      // used to also setState an elapsed-time field on every tick that
      // nothing ever rendered — a rebuild per second for no visible change.
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _voiceStartedAt == null) return;
        final elapsed = DateTime.now().difference(_voiceStartedAt!);
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
    final authorColor = _authorColorFor(room);
    final editor = ContinuousSongEditor(
      project: project,
      controller: _continuousController,
      scrollController: _contributionScroll,
      authorColor: authorColor,
      onSaveDocument: (lines) => _saveDocument(project, lines),
      onVoiceBullet: (contribution) => _voiceBulletPressed(project, contribution),
      recordingContributionId: _recordingContributionId,
      savingContributionId: _savingContributionId,
      loadingVoiceContributionId: _loadingVoiceContributionId,
      playingContributionId: _playingContributionId,
    );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: landscape
            ? _LandscapeWorkspace(
                key: const Key('workspace_landscape_panel'),
                project: project,
                room: room,
                onBack: () {
                  Navigator.maybePop(context);
                },
                onRename: () => _rename(project),
                onOpenLive: () => _openLivePerformance(project),
                onExport: (action) => _exportSong(project, action),
                hasRecording: _analysisBundle?.reference != null,
                onAnalyze: () => _openAnalysis(project),
                onRecord: () => _openAnalysis(project, autoRecord: true),
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
                    onOpenLive: () => _openLivePerformance(project),
                    onAnalyze: () => _openAnalysis(project),
                    onRecord: () => _openAnalysis(project, autoRecord: true),
                    hasRecording: _analysisBundle?.reference != null,
                  ),
                  const Divider(height: 1),
                  Expanded(child: editor),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('talk_to_text_button'),
        onPressed: _toggleSpeech,
        tooltip: _listening ? 'Stop dictation' : 'Dictate lyrics',
        backgroundColor: _listening ? const Color(0xFFFF6178) : AppColors.cyan,
        child: Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded),
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
    final logoBytes = BetaScope.of(context).roomLogoBytes(room);
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
            _RoomMark(size: 42, logoBytes: logoBytes, fallbackIcon: room.icon),
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
                value: _SongMenuAction.importLyrics,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.file_download_outlined),
                  title: Text('Import lyrics'),
                ),
              ),
              PopupMenuItem<_SongMenuAction>(
                value: _SongMenuAction.invite,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.person_add_alt_1_rounded),
                  title: Text('Invite to This Song'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<_SongMenuAction>(
                value: _SongMenuAction.color,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle_outlined),
                  title: Text('Line color'),
                ),
              ),
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
    required this.onBack,
    required this.onRename,
    required this.onOpenLive,
    required this.onExport,
    required this.hasRecording,
    required this.onAnalyze,
    required this.onRecord,
    required this.editor,
    super.key,
  });

  final SongProject project;
  final MusicRoom room;
  final VoidCallback onBack;
  final VoidCallback onRename;
  final VoidCallback onOpenLive;
  final ValueChanged<_SongMenuAction> onExport;
  final bool hasRecording;
  final VoidCallback onAnalyze;
  final VoidCallback onRecord;
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
              // Same three verbs as portrait's toolbar, as icons to fit the
              // shorter landscape bar — and reaching the same callbacks, so
              // the two orientations can't drift apart in what they offer.
              IconButton(
                key: const Key('workspace_analyze_button'),
                onPressed: onAnalyze,
                tooltip: hasRecording ? 'Analysis' : 'Analyze this song',
                icon: Icon(
                  Icons.graphic_eq_rounded,
                  size: 19,
                  color: hasRecording ? AppColors.gold : AppColors.muted,
                ),
              ),
              IconButton(
                key: const Key('workspace_record_button'),
                onPressed: onRecord,
                tooltip: hasRecording ? 'Record a new take' : 'Record',
                icon: const Icon(Icons.mic_none_rounded, size: 19, color: AppColors.muted),
              ),
              IconButton(
                key: const Key('workspace_live_button'),
                onPressed: onOpenLive,
                tooltip: 'Perform',
                icon: const Icon(Icons.play_circle_outline_rounded, size: 19, color: AppColors.cyan),
              ),
              PopupMenuButton<_SongMenuAction>(
                key: const Key('song_options_menu'),
                tooltip: 'Song options',
                onSelected: onExport,
                itemBuilder: (_) => const <PopupMenuEntry<_SongMenuAction>>[
                  PopupMenuItem<_SongMenuAction>(
                    value: _SongMenuAction.importLyrics,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.file_download_outlined),
                      title: Text('Import lyrics'),
                    ),
                  ),
                  PopupMenuItem<_SongMenuAction>(
                    value: _SongMenuAction.invite,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.person_add_alt_1_rounded),
                      title: Text('Invite to This Song'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem<_SongMenuAction>(
                    value: _SongMenuAction.color,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.circle_outlined),
                      title: Text('Line color'),
                    ),
                  ),
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

class _RoomMark extends StatelessWidget {
  const _RoomMark({required this.size, required this.logoBytes, required this.fallbackIcon});

  final double size;
  final Uint8List? logoBytes;
  final String fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final bytes = logoBytes;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: <Color>[AppColors.blue, AppColors.cyan]),
        borderRadius: BorderRadius.circular(size * 0.33),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x2932D4FF), blurRadius: 24)],
      ),
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, width: size, height: size)
          : Text(fallbackIcon, style: TextStyle(fontSize: size * 0.5)),
    );
  }
}

class _WorkspaceToolbar extends StatelessWidget {
  const _WorkspaceToolbar({
    required this.onOpenLive,
    required this.hasRecording,
    required this.onAnalyze,
    required this.onRecord,
  });

  final VoidCallback onOpenLive;
  final bool hasRecording;
  final VoidCallback onAnalyze;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    // The three things a musician opens a song to do, always visible. Analyze
    // in particular used to be buried in the overflow menu between "Record
    // Audio" and "Send to printer" despite being the app's most distinctive
    // capability. Everything that isn't one of these three verbs — import,
    // invite, colour, print, share — lives in the overflow, listed once.
    final actions = <Widget>[
      _ToolPill(
        key: const Key('workspace_analyze_button'),
        icon: Icons.graphic_eq_rounded,
        label: hasRecording ? 'Analysis' : 'Analyze',
        active: hasRecording,
        activeColor: AppColors.gold,
        onTap: onAnalyze,
      ),
      _ToolPill(
        key: const Key('workspace_record_button'),
        icon: Icons.mic_none_rounded,
        label: hasRecording ? 'New take' : 'Record',
        active: false,
        onTap: onRecord,
      ),
      _ToolPill(
        key: const Key('workspace_live_button'),
        icon: Icons.play_circle_outline_rounded,
        label: 'Perform',
        active: false,
        onTap: onOpenLive,
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
              for (var i = 0; i < actions.length; i += 1) ...<Widget>[
                if (i > 0) const SizedBox(width: 8),
                actions[i],
              ],
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
    this.activeColor = AppColors.cyan,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : AppColors.muted;
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: active
            ? <BoxShadow>[BoxShadow(color: activeColor.withValues(alpha: 0.16), blurRadius: 18)]
            : const <BoxShadow>[],
      ),
      child: Material(
        color: active ? activeColor.withValues(alpha: 0.12) : AppColors.surface,
        shape: StadiumBorder(side: BorderSide(color: active ? activeColor : AppColors.line)),
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
