import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/calls.dart';
import '../../services/call_session.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/profile_face.dart';
import '../openmic/report_sheet.dart';

/// How a call screen gets into a call. [LiveKitCallSession.join] in the app;
/// a fake in tests.
typedef JoinCall = Future<CallSession> Function(CallTicket ticket);

/// A room's call: everybody in it, and the few controls a lesson needs.
///
/// Stage A of slice 4 (16 September 2026): adults in a room, voice and video,
/// nothing recorded. Music mode is one tap because a guitar lesson over a
/// voice call is a guitar lesson with the held notes cut off.
class CallScreen extends StatefulWidget {
  const CallScreen({
    required this.roomId,
    required this.roomName,
    required this.repository,
    this.join,
    this.hearEvery = const Duration(seconds: 20),
    super.key,
  });

  final String roomId;
  final String roomName;
  final MusicRepository repository;
  final JoinCall? join;

  /// How often this phone tells the room it is still in the call.
  final Duration hearEvery;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallSession? _session;
  String? _problem;
  Timer? _hear;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final ticket = await widget.repository.callTicket(roomId: widget.roomId, device: callDevice);
      final session = await (widget.join ?? LiveKitCallSession.join)(ticket);
      if (!mounted) {
        unawaited(session.leave());
        return;
      }
      session.addListener(_changed);
      setState(() => _session = session);
      final problem = session.microphoneProblem ?? session.cameraProblem;
      if (problem != null) _say(problem);
      unawaited(_hearMe());
      _hear = Timer.periodic(widget.hearEvery, (_) => unawaited(_hearMe()));
    } on CallRefused catch (refused) {
      if (mounted) setState(() => _problem = refused.message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _problem = reportAndDescribe(error, service: 'app', stage: 'calls.join', route: 'Call');
      });
    }
  }

  Future<void> _hearMe() async {
    try {
      await widget.repository.hearMeInCall(roomId: widget.roomId, device: callDevice);
    } catch (_) {
      // The next one will do; the call itself does not depend on it.
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_session?.state == CallState.ended && !_leaving) {
      _leaving = true;
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _hear?.cancel();
    final session = _session;
    session?.removeListener(_changed);
    if (session != null) unawaited(session.leave());
    unawaited(widget.repository.leaveCall(roomId: widget.roomId, device: callDevice).catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _leave() async {
    _leaving = true;
    await _session?.leave();
    // Said before the screen closes: the room looks again the moment it is
    // back, and on 17 Sep it looked first and said "you are in this call on
    // another device" about the call just left.
    try {
      await widget.repository.leaveCall(roomId: widget.roomId, device: callDevice);
    } catch (_) {
      // dispose says it again; a stale row fades on its own in 45 seconds.
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _musicMode(CallSession session) async {
    final turningOn = !session.musicMode;
    await session.setMusicMode(turningOn);
    if (!mounted || !turningOn) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
        content: Text(
          'Music mode: your instrument goes through as it is, with no echo cancelling '
          'or noise gate. Wear headphones, or the others will hear themselves.',
        ),
      ));
  }

  Future<void> _aboutPerson(CallPerson person) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const Key('call_report'),
              leading: const Icon(Icons.flag_outlined),
              title: Text('Report ${person.name}'),
              onTap: () => Navigator.pop(sheetContext, 'report'),
            ),
            ListTile(
              key: const Key('call_block'),
              leading: const Icon(Icons.block_rounded, color: AppColors.orange),
              title: Text('Block ${person.name}'),
              subtitle: const Text('You leave the call, and they cannot find or contact you.'),
              onTap: () => Navigator.pop(sheetContext, 'block'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'report') {
      await showReportSheet(
        context,
        repository: widget.repository,
        kind: 'profile',
        about: '${person.name}, in a call in ${widget.roomName}',
        profileId: person.userId,
        roomId: widget.roomId,
      );
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text('Block ${person.name}?'),
        content: const Text(
          'You leave this call now, and neither of you can join a call the other is in. '
          'They will not be able to find you, ask you, or invite you to anything. '
          'They are not told. You can undo this in Account.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('call_block_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.repository.blockUser(person.userId);
      if (!mounted) return;
      await _leave();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error, service: 'app', stage: 'calls.block', route: 'Call')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.roomName, maxLines: 1, overflow: TextOverflow.ellipsis),
            const Text(
              'Call · nothing is recorded',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _problem != null
            ? _refused(_problem!)
            : session == null
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        CircularProgressIndicator(),
                        SizedBox(height: 14),
                        Text('Joining the call…', style: TextStyle(color: AppColors.muted)),
                      ],
                    ),
                  )
                : Column(
                    children: <Widget>[
                      Expanded(child: _tiles(session)),
                      _controls(session),
                    ],
                  ),
      ),
    );
  }

  Widget _refused(String problem) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.videocam_off_outlined, size: 44, color: AppColors.muted),
              const SizedBox(height: 14),
              Text(
                problem,
                key: const Key('call_problem'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.text, fontSize: 15.5, height: 1.4),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Back to the room'),
              ),
            ],
          ),
        ),
      );

  Widget _tiles(CallSession session) {
    final people = session.people;
    if (people.length <= 1) {
      return Column(
        children: <Widget>[
          Expanded(child: people.isEmpty ? const SizedBox() : _tile(people.single)),
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'Nobody else is here yet. The room has been told.',
              key: Key('call_waiting'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ),
        ],
      );
    }
    final columns = people.length <= 2 ? 1 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final rows = (people.length / columns).ceil();
        final height = constraints.maxHeight / rows;
        final width = constraints.maxWidth / columns;
        return GridView.count(
          crossAxisCount: columns,
          childAspectRatio: width / height,
          padding: const EdgeInsets.all(6),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          physics: const NeverScrollableScrollPhysics(),
          children: <Widget>[for (final person in people) _tile(person)],
        );
      },
    );
  }

  Widget _tile(CallPerson person) {
    final video = person.video;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: AppColors.raised,
          child: InkWell(
            key: Key('call_person_${person.userId}${person.isYou ? '_you' : ''}'),
            onLongPress: person.isYou ? null : () => unawaited(_aboutPerson(person)),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (person.cameraOn && video != null)
                  lk.VideoTrackRenderer(
                    video,
                    fit: lk.VideoViewFit.cover,
                    mirrorMode: person.isYou ? lk.VideoViewMirrorMode.mirror : lk.VideoViewMirrorMode.off,
                  )
                else
                  Center(
                    child: ProfileFace(name: person.name, seed: person.userId, size: 88),
                  ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            person.isYou ? 'You' : person.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      if (!person.micOn) ...<Widget>[
                        const SizedBox(width: 6),
                        const Icon(Icons.mic_off_rounded, color: Colors.white, size: 18),
                      ],
                    ],
                  ),
                ),
                if (!person.isYou)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      key: Key('call_about_${person.userId}'),
                      tooltip: 'Report or block ${person.name}',
                      onPressed: () => unawaited(_aboutPerson(person)),
                      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(CallSession session) {
    Widget round({
      required Key key,
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
      Color? color,
      bool lit = false,
    }) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton.filled(
              key: key,
              onPressed: onPressed,
              tooltip: label,
              style: IconButton.styleFrom(
                backgroundColor: color ?? (lit ? AppColors.gold : AppColors.raised),
                foregroundColor: lit || color != null ? AppColors.ink : AppColors.text,
                minimumSize: const Size(52, 52),
              ),
              icon: Icon(icon),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
          ],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        spacing: 10,
        runSpacing: 8,
        children: <Widget>[
          if (session.microphoneProblem case final problem?)
            round(
              key: const Key('call_mic'),
              icon: Icons.mic_off_rounded,
              label: 'No mic',
              onPressed: () => _say(problem),
            )
          else
            round(
              key: const Key('call_mic'),
              icon: session.micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
              label: session.micOn ? 'Mute' : 'Unmute',
              onPressed: () => unawaited(session.setMic(!session.micOn)),
            ),
          if (session.cameraProblem case final problem? when !session.cameraOn)
            round(
              key: const Key('call_camera'),
              icon: Icons.videocam_off_rounded,
              label: 'No camera',
              onPressed: () {
                _say(problem);
                unawaited(session.setCamera(true));
              },
            )
          else
            round(
              key: const Key('call_camera'),
              icon: session.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              label: session.cameraOn ? 'Camera off' : 'Camera on',
              onPressed: () => unawaited(session.setCamera(!session.cameraOn)),
            ),
          round(
            key: const Key('call_flip'),
            icon: Icons.cameraswitch_rounded,
            label: 'Flip',
            onPressed: () => unawaited(session.flipCamera()),
          ),
          round(
            key: const Key('call_music'),
            icon: Icons.headphones_rounded,
            label: 'Music mode',
            lit: session.musicMode,
            onPressed: () => unawaited(_musicMode(session)),
          ),
          round(
            key: const Key('call_leave'),
            icon: Icons.call_end_rounded,
            label: 'Leave',
            color: const Color(0xFFFF5B6E),
            onPressed: () => unawaited(_leave()),
          ),
        ],
      ),
    );
  }
}
