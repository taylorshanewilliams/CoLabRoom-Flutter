import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import '../../data/music_repository.dart';
import '../../services/people_presence.dart';
import '../../widgets/player_face.dart';
import '../openmic/musician_profile_screen.dart';
import '../openmic/people_screen.dart';
import '../openmic/person_thread_sheet.dart';

/// Everybody you know, in a row, with who is here now.
///
/// Taylor: "a way to see all your friends, band mates, connections, people
/// you collaborating with etc in one place, whos online". The People screen
/// is that place and has been -- connections, then everybody who shares a
/// room or a song with you -- but it lived behind the Open Mic, two taps
/// from where anybody talks. This is its front row, on the Messages tab:
/// faces, the ones here now first and marked, a count, and *All* into the
/// full screen. Tap a face and the thread between you opens; somebody the
/// app will not let you write to yet opens on their page instead.
class _Person {
  const _Person({
    required this.id,
    required this.name,
    required this.canMessage,
    this.avatarPath,
  });

  final String id;
  final String name;
  final String? avatarPath;
  final bool canMessage;
}

class PeopleStrip extends StatefulWidget {
  const PeopleStrip({required this.repository, super.key});

  final MusicRepository repository;

  @override
  State<PeopleStrip> createState() => _PeopleStripState();
}

class _PeopleStripState extends State<PeopleStrip> {
  List<_Person> _people = const <_Person>[];
  Set<String> _online = PeoplePresence.instance.onlineNow;
  StreamSubscription<Set<String>>? _presence;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _presence = PeoplePresence.instance.online.listen((who) {
      if (!mounted) return;
      setState(() => _online = who);
      // The People screen stops every watch when it closes. An empty set
      // while there is somebody to watch is that, and the row watches
      // again rather than showing nobody here for the rest of the session.
      if (who.isEmpty && _people.isNotEmpty) unawaited(_watch());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _presence?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final connections = await widget.repository.listConnections();
      final suggested = await widget.repository.peopleYouMightAdd();
      if (!mounted) return;
      final seen = <String>{};
      final people = <_Person>[
        for (final c in connections)
          if (c.accepted && seen.add(c.personId))
            _Person(
              id: c.personId,
              name: c.displayName,
              avatarPath: c.avatarPath,
              canMessage: true,
            ),
        for (final s in suggested)
          if (seen.add(s.personId))
            _Person(
              id: s.personId,
              name: s.displayName,
              avatarPath: s.avatarPath,
              canMessage: s.canMessage,
            ),
      ];
      setState(() {
        _people = people;
        _loaded = true;
      });
      await _watch();
    } catch (_) {
      // The row is the least important thing on the tab. Nothing to show
      // is the honest state when it cannot be read.
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _watch() =>
      PeoplePresence.instance.watch(_people.map((p) => p.id));

  Future<void> _open(_Person person) async {
    final controller = BetaScope.of(context, listen: false);
    if (person.canMessage) {
      await showPersonThread(
        context,
        repository: widget.repository,
        changes: controller,
        personId: person.id,
        personName: person.name,
      );
      if (!mounted) return;
      unawaited(controller.refreshThreads());
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.musician(person.id)),
      builder: (_) => MusicianProfileScreen(
        profileId: person.id,
        repository: widget.repository,
      ),
    ));
    if (mounted) unawaited(_load());
  }

  Future<void> _all() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: AppRoutes.people),
      builder: (_) => const PeopleScreen(),
    ));
    // They may have added somebody, and the People screen took the
    // presence watches with it when it closed.
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _people.isEmpty) return const SizedBox.shrink();
    final controller = BetaScope.of(context);
    final ordered = <_Person>[
      for (final p in _people)
        if (_online.contains(p.id)) p,
      for (final p in _people)
        if (!_online.contains(p.id)) p,
    ];
    final here = ordered.where((p) => _online.contains(p.id)).length;
    return Padding(
      key: const Key('people_strip'),
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  here == 0
                      ? 'YOUR PEOPLE · ${ordered.length}'
                      : 'YOUR PEOPLE · ${ordered.length} · $here HERE NOW',
                  key: const Key('people_strip_label'),
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
              TextButton(
                key: const Key('people_strip_all'),
                onPressed: () => unawaited(_all()),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.cyan,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('All', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          SizedBox(
            height: 74,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 10),
              itemCount: ordered.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) {
                final person = ordered[i];
                final here = _online.contains(person.id);
                return InkWell(
                  key: Key('strip_person_${person.id}'),
                  onTap: () => unawaited(_open(person)),
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 58,
                    child: Column(
                      children: <Widget>[
                        Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            PlayerFace(
                              name: person.name,
                              color: person.canMessage ? AppColors.cyan : AppColors.muted,
                              photo: controller.avatarBytesFor(person.avatarPath),
                              size: 46,
                            ),
                            if (here)
                              Positioned(
                                right: -1,
                                bottom: -1,
                                child: Container(
                                  key: Key('strip_here_${person.id}'),
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: AppColors.green,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: AppColors.ink, width: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          person.name.split(' ').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: here ? AppColors.text : AppColors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
