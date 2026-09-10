import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/people_presence.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/player_face.dart';
import '../../widgets/problem_report.dart';

/// The people you know, as opposed to the people you might meet.
///
/// This app has had two kinds of person in it and nothing in between:
/// somebody in a room with you, which is a working relationship with shared
/// files and shared edits, or a name on the Open Mic you have never met. The
/// person you jammed with once, the friend who plays bass, the drummer you met
/// here and would work with again — all of them were strangers every time you
/// opened the app, and the only way to keep hold of one was to put them in a
/// room, which grants them everything.
///
/// A connection grants nothing. It lets two people find each other again, see
/// whether the other is around, and — once push works — send something
/// directly rather than to a whole room.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Connection> _connections = const <Connection>[];
  List<SuggestedPerson> _suggestions = const <SuggestedPerson>[];
  bool _loading = true;
  String? _busyWith;

  /// Who is here this second, as opposed to who said they were around this
  /// fortnight. The two answer different questions and the row shows both.
  Set<String> _online = PeoplePresence.instance.onlineNow;
  StreamSubscription<Set<String>>? _presenceSub;

  @override
  void initState() {
    super.initState();
    _presenceSub = PeoplePresence.instance.online.listen((who) {
      if (mounted) setState(() => _online = who);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _presenceSub?.cancel();
    // Watching stops; announcing does not. You stay visible to everybody else
    // after closing this screen -- you simply stop paying for a socket per
    // person while looking at something else.
    unawaited(PeoplePresence.instance.stopWatching());
    super.dispose();
  }

  Future<void> _load() async {
    final controller = BetaScope.of(context, listen: false);
    try {
      final connections = await controller.repository.listConnections();
      final suggestions = await controller.repository.peopleYouMightAdd();
      if (!mounted) return;
      setState(() {
        _connections = connections;
        _suggestions = suggestions;
        _loading = false;
      });
      // Only the people actually on screen, and only while it is open. The
      // traffic this client sees is bounded by its own list rather than by
      // how many people use the app.
      unawaited(PeoplePresence.instance.watch(
        connections.where((c) => c.accepted).map((c) => c.personId),
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showProblem(context, error,
          service: 'app', stage: 'people.load', route: 'People');
    }
  }

  Future<void> _act(String personId, Future<void> Function() action) async {
    setState(() => _busyWith = personId);
    try {
      await action();
      await _load();
    } catch (error) {
      if (!mounted) return;
      showProblem(context, error,
          service: 'app', stage: 'people.act', route: 'People');
    } finally {
      if (mounted) setState(() => _busyWith = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _connections.where((c) => !c.accepted && c.incoming).toList();
    final asked = _connections.where((c) => !c.accepted && !c.incoming).toList();
    final known = _connections.where((c) => c.accepted).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
                  children: <Widget>[
                    const _YourAvailability(),
                    const SizedBox(height: 22),

                    // Answered first. A request nobody answers is the one
                    // thing on this screen that goes stale, and the person
                    // who sent it is waiting.
                    if (waiting.isNotEmpty) ...<Widget>[
                      const _Heading('Waiting on you'),
                      for (final person in waiting)
                        _ConnectionRow(
                          connection: person,
                          busy: _busyWith == person.personId,
                          onAccept: () => _act(
                            person.personId,
                            () => BetaScope.of(context, listen: false)
                                .repository
                                .respondToConnection(person.personId,
                                    accept: true),
                          ),
                          onDecline: () => _act(
                            person.personId,
                            () => BetaScope.of(context, listen: false)
                                .repository
                                .respondToConnection(person.personId,
                                    accept: false),
                          ),
                        ),
                      const SizedBox(height: 22),
                    ],

                    const _Heading('Your people'),
                    if (known.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'Nobody yet. Anybody you add here you can reach '
                          'directly, without putting them in a room first.',
                          style: TextStyle(color: AppColors.muted, height: 1.5),
                        ),
                      )
                    else
                      for (final person in known)
                        _ConnectionRow(
                          connection: person,
                          busy: _busyWith == person.personId,
                          here: _online.contains(person.personId),
                          onRemove: () => _act(
                            person.personId,
                            () => BetaScope.of(context, listen: false)
                                .repository
                                .removeConnection(person.personId),
                          ),
                        ),

                    if (asked.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 22),
                      const _Heading('Asked, no answer yet'),
                      for (final person in asked)
                        _ConnectionRow(
                          connection: person,
                          busy: _busyWith == person.personId,
                          onRemove: () => _act(
                            person.personId,
                            () => BetaScope.of(context, listen: false)
                                .repository
                                .removeConnection(person.personId),
                          ),
                        ),
                    ],

                    if (_suggestions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 22),
                      const _Heading('People you already work with'),
                      for (final person in _suggestions)
                        _SuggestionRow(
                          person: person,
                          busy: _busyWith == person.personId,
                          onAdd: () => _act(
                            person.personId,
                            () => BetaScope.of(context, listen: false)
                                .repository
                                .requestConnection(person.personId),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

/// What you have told everybody about how reachable you are.
///
/// Sits at the top rather than in settings, because a status somebody has to
/// go and find is a status that is six weeks out of date. It is the first
/// thing on the screen where you look at everybody else's.
class _YourAvailability extends StatefulWidget {
  const _YourAvailability();

  @override
  State<_YourAvailability> createState() => _YourAvailabilityState();
}

class _YourAvailabilityState extends State<_YourAvailability> {
  Availability _state = Availability.unset;
  bool _busy = false;

  Future<void> _set(Availability next) async {
    setState(() {
      _state = next;
      _busy = true;
    });
    try {
      await BetaScope.of(context, listen: false).repository.setAvailability(
            next,
            // A fortnight, and then it is not true any more.
            //
            // A status with no end is one somebody sets in a good week and
            // forgets, and the app goes on telling their band they are up for
            // playing long after they stopped being.
            until: next == Availability.unset
                ? null
                : DateTime.now().add(const Duration(days: 14)),
          );
    } catch (error) {
      if (!mounted) return;
      showProblem(context, error,
          service: 'app', stage: 'people.availability', route: 'People');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'You, this fortnight',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'What your people see before they ask you for anything.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final option in const <({Availability state, String label})>[
                (state: Availability.open, label: 'Up for playing'),
                (state: Availability.busy, label: 'Heads down'),
                (state: Availability.away, label: 'Away'),
                (state: Availability.unset, label: 'Say nothing'),
              ])
                ChoiceChip(
                  key: Key('availability_${option.state.name}'),
                  selected: _state == option.state,
                  showCheckmark: false,
                  label: Text(option.label),
                  onSelected: _busy ? null : (_) => unawaited(_set(option.state)),
                  selectedColor: AppColors.raised,
                  side: BorderSide(
                    color: _state == option.state
                        ? AppColors.cyan
                        : AppColors.line,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.connection,
    required this.busy,
    this.here = false,
    this.onAccept,
    this.onDecline,
    this.onRemove,
  });

  final Connection connection;
  final bool busy;

  /// Online right now. Shown as well as the status rather than instead of
  /// it: the dot says message them now, the status says whether it is worth
  /// asking at all, and on most days only the second one exists.
  final bool here;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final line = connection.availabilityLine;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        child: Row(
          children: <Widget>[
            // The dot rides on the face rather than sitting in the row.
            // A green circle in a column of its own reads as a column of
            // grey circles on every day nobody happens to be online, which
            // is the failure this whole design is trying to avoid.
            Stack(
              children: <Widget>[
                PlayerFace(
                  name: connection.displayName,
                  color: AppColors.cyan,
                  photo: controller.avatarBytesFor(connection.avatarPath),
                  size: 38,
                ),
                if (here)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      key: Key('here_${connection.personId}'),
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: AppColors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.deepNavy, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    connection.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // The status if they have set one, otherwise what they
                  // play, otherwise nothing. Never a made-up "offline":
                  // saying nothing is not the same as being away, and the
                  // app does not know which.
                  if (here)
                    Row(
                      children: <Widget>[
                        const Text(
                          'Here now',
                          style: TextStyle(
                              color: AppColors.green,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700),
                        ),
                        if (line != null) ...<Widget>[
                          const Text(' · ',
                              style: TextStyle(
                                  color: AppColors.muted, fontSize: 12.5)),
                          Flexible(
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 12.5),
                            ),
                          ),
                        ],
                      ],
                    )
                  else if (line != null)
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: connection.availability == Availability.open
                            ? AppColors.cyan
                            : AppColors.muted,
                        fontSize: 12.5,
                      ),
                    )
                  else if (connection.plays.isNotEmpty)
                    Text(
                      connection.plays.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12.5),
                    ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (onAccept != null) ...<Widget>[
              TextButton(
                onPressed: onDecline,
                child: const Text('No'),
              ),
              FilledButton(
                key: Key('accept_${connection.personId}'),
                onPressed: onAccept,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Yes'),
              ),
            ] else if (onRemove != null)
              IconButton(
                key: Key('remove_${connection.personId}'),
                onPressed: onRemove,
                tooltip: connection.accepted
                    ? 'Remove ${connection.displayName}'
                    : 'Take back the request',
                icon: const Icon(Icons.close_rounded,
                    size: 18, color: AppColors.muted),
              ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.person,
    required this.busy,
    required this.onAdd,
  });

  final SuggestedPerson person;
  final bool busy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        child: Row(
          children: <Widget>[
            PlayerFace(
              name: person.displayName,
              color: AppColors.blue,
              photo: controller.avatarBytesFor(person.avatarPath),
              size: 38,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    person.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // Why they are here, in words. A fact rather than a score:
                  // this app does not have enough people to guess with, and
                  // would not be forgiven for guessing wrong about who
                  // somebody plays with.
                  Text(
                    person.because,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                key: Key('add_${person.personId}'),
                onPressed: onAdd,
                style: TextButton.styleFrom(foregroundColor: AppColors.cyan),
                child: const Text('Add'),
              ),
          ],
        ),
      ),
    );
  }
}
