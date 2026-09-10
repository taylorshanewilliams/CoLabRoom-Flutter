import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/people_presence.dart';
import '../../widgets/player_face.dart';
import '../../widgets/problem_report.dart';
import 'musician_profile_screen.dart';

/// The people you know, as opposed to the people you might meet.
///
/// This app had two kinds of person in it and nothing in between: somebody in
/// a room with you, which is shared files and shared edits, or a name on the
/// Open Mic you have never met. A connection grants nothing — it is a way to
/// find each other again, not a permission.
///
/// Taylor, on the first version of this screen: "can we work on the design of
/// it so its more open, more seemless and intuitive. simple yet deep, a place
/// where you can see your friends, add friends, search for friends, if you
/// click on a friend you can see there profile, and if you have friend
/// requests you can look at there profile first."
///
/// Three things changed for that.
///
/// **It opens on people.** The first version opened on a box of chips asking
/// how available you were — a form about yourself, on the screen you came to
/// in order to look at somebody else. Your own status is one line now, at the
/// end, said in a sentence.
///
/// **Every name goes somewhere.** A row that cannot be tapped is a dead end,
/// and that list was all dead ends: three groups of names with buttons on
/// them and no way to find out who any of these people were. Every row opens
/// their profile now, requests included — deciding about somebody you half
/// remember is exactly when you need to see their face and what they play.
///
/// **One field finds and adds.** Those were two ideas in the first version
/// and they are one motion: you type a name, and whoever matches is offered,
/// whether they are already yours or a stranger.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final TextEditingController _search = TextEditingController();

  List<Connection> _connections = const <Connection>[];
  List<SuggestedPerson> _suggestions = const <SuggestedPerson>[];
  List<FoundPerson> _found = const <FoundPerson>[];

  bool _loading = true;
  bool _searching = false;
  String _query = '';
  String? _busyWith;

  Set<String> _online = PeoplePresence.instance.onlineNow;
  StreamSubscription<Set<String>>? _presenceSub;
  Timer? _debounce;

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
    _debounce?.cancel();
    _search.dispose();
    _presenceSub?.cancel();
    // Watching stops; announcing does not. You stay visible to everybody else
    // after closing this screen — you simply stop paying for a socket per
    // person while looking at something else.
    unawaited(PeoplePresence.instance.stopWatching());
    super.dispose();
  }

  MusicRepository get _repo => BetaScope.of(context, listen: false).repository;

  Future<void> _load() async {
    try {
      final connections = await _repo.listConnections();
      final suggestions = await _repo.peopleYouMightAdd();
      if (!mounted) return;
      setState(() {
        _connections = connections;
        _suggestions = suggestions;
        _loading = false;
      });
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

  /// Typing searches everybody, a beat after the typing stops.
  ///
  /// Debounced because a query per keystroke is a query per keystroke, and
  /// because a list that reshuffles under a moving thumb is unusable.
  void _onQuery(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _found = const <FoundPerson>[];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final found = await _repo.searchPeople(value);
        if (!mounted || _query != value) return;
        setState(() {
          _found = found;
          _searching = false;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() => _searching = false);
        showProblem(context, error,
            service: 'app', stage: 'people.search', route: 'People');
      }
    });
  }

  Future<void> _act(String personId, Future<void> Function() action) async {
    setState(() => _busyWith = personId);
    try {
      await action();
      await _load();
      if (_query.trim().isNotEmpty) _onQuery(_query);
    } catch (error) {
      if (!mounted) return;
      showProblem(context, error,
          service: 'app', stage: 'people.act', route: 'People');
    } finally {
      if (mounted) setState(() => _busyWith = null);
    }
  }

  /// Every row on this screen leads here.
  ///
  /// The requests included: deciding about somebody you half remember is
  /// exactly the moment you need to see their face and what they play, and
  /// the first version asked for that decision from a name alone.
  Future<void> _openProfile(String personId) async {
    final repository = _repo;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Musician'),
      builder: (_) => MusicianProfileScreen(
        profileId: personId,
        repository: repository,
      ),
    ));
    // They may have been added or removed while they were in there.
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.trim().isNotEmpty;
    final waiting =
        _connections.where((c) => !c.accepted && c.incoming).toList();
    final asked = _connections.where((c) => !c.accepted && !c.incoming).toList();
    final known = _connections.where((c) => c.accepted).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: TextField(
                key: const Key('people_search'),
                controller: _search,
                onChanged: _onQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  // One field for both jobs. Finding somebody you know and
                  // adding somebody you do not are the same motion: you type
                  // a name.
                  hintText: 'Find someone by name',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: 'Clear',
                          onPressed: () {
                            _search.clear();
                            _onQuery('');
                          },
                          icon: const Icon(Icons.close_rounded, size: 19),
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : searching
                      ? _results()
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: _mine(waiting, asked, known),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results() {
    // Yours first, and clearly yours. Somebody typing a name they already
    // know is usually looking for a person they already have.
    final needle = _query.trim().toLowerCase();
    final mine = _connections
        .where((c) => c.displayName.toLowerCase().contains(needle))
        .toList();
    final strangers = _found
        .where((f) => !_connections.any((c) => c.personId == f.personId))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
      children: <Widget>[
        if (mine.isNotEmpty) ...<Widget>[
          const _Label('YOUR PEOPLE'),
          for (final person in mine)
            _PersonRow(
              name: person.displayName,
              avatarPath: person.avatarPath,
              line: person.availabilityLine ?? person.plays.join(' · '),
              here: _online.contains(person.personId),
              onTap: () => unawaited(_openProfile(person.personId)),
            ),
        ],
        if (_searching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (strangers.isNotEmpty) ...<Widget>[
          const _Label('EVERYBODY ELSE'),
          for (final person in strangers)
            _PersonRow(
              name: person.displayName,
              avatarPath: person.avatarPath,
              line: <String>[
                if (person.plays.isNotEmpty) person.plays.join(' · '),
                if (person.city != null) person.city!,
              ].join('  ·  '),
              onTap: () => unawaited(_openProfile(person.personId)),
              trailing: _AddButton(
                standing: person.already,
                busy: _busyWith == person.personId,
                onAdd: () => _act(person.personId,
                    () => _repo.requestConnection(person.personId)),
              ),
            ),
        ] else if (mine.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 8),
            child: Text(
              'Nobody called “${_query.trim()}”.\n\nPeople turn up here once '
              'they have said they want to be found.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, height: 1.6),
            ),
          ),
      ],
    );
  }

  Widget _mine(
    List<Connection> waiting,
    List<Connection> asked,
    List<Connection> known,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
      children: <Widget>[
        // Answered first. A request nobody answers is the one thing here that
        // goes stale, and somebody is waiting on it.
        if (waiting.isNotEmpty) ...<Widget>[
          const _Label('WANTS TO CONNECT'),
          for (final person in waiting)
            _PersonRow(
              name: person.displayName,
              avatarPath: person.avatarPath,
              line: person.plays.isEmpty
                  ? 'Tap to see who they are'
                  : person.plays.join(' · '),
              onTap: () => unawaited(_openProfile(person.personId)),
              trailing: _busyWith == person.personId
                  ? const _Spinner()
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => _act(
                              person.personId,
                              () => _repo.respondToConnection(person.personId,
                                  accept: false)),
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.muted),
                          child: const Text('No'),
                        ),
                        FilledButton(
                          key: Key('accept_${person.personId}'),
                          onPressed: () => _act(
                              person.personId,
                              () => _repo.respondToConnection(person.personId,
                                  accept: true)),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.cyan,
                            foregroundColor: AppColors.ink,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: const Text('Yes'),
                        ),
                      ],
                    ),
            ),
        ],
        if (known.isEmpty && waiting.isEmpty && asked.isEmpty)
          const _NobodyYet()
        else if (known.isNotEmpty) ...<Widget>[
          _Label('YOUR PEOPLE · ${known.length}'),
          for (final person in known)
            _PersonRow(
              name: person.displayName,
              avatarPath: person.avatarPath,
              line: person.availabilityLine ?? person.plays.join(' · '),
              lineIsStatus: person.availability == Availability.open,
              here: _online.contains(person.personId),
              onTap: () => unawaited(_openProfile(person.personId)),
            ),
        ],
        if (asked.isNotEmpty) ...<Widget>[
          const _Label('ASKED, NO ANSWER YET'),
          for (final person in asked)
            _PersonRow(
              name: person.displayName,
              avatarPath: person.avatarPath,
              line: 'Waiting on them',
              dimmed: true,
              onTap: () => unawaited(_openProfile(person.personId)),
              trailing: _busyWith == person.personId
                  ? const _Spinner()
                  : IconButton(
                      key: Key('remove_${person.personId}'),
                      tooltip: 'Take back the request',
                      onPressed: () => _act(person.personId,
                          () => _repo.removeConnection(person.personId)),
                      icon: const Icon(Icons.close_rounded,
                          size: 18, color: AppColors.muted),
                    ),
            ),
        ],
        if (_suggestions.isNotEmpty) ...<Widget>[
          const _Label('PEOPLE YOU ALREADY WORK WITH'),
          for (final person in _suggestions)
            _PersonRow(
              name: person.displayName,
              avatarPath: person.avatarPath,
              line: person.because,
              onTap: () => unawaited(_openProfile(person.personId)),
              trailing: _busyWith == person.personId
                  ? const _Spinner()
                  : TextButton(
                      key: Key('add_${person.personId}'),
                      onPressed: () => _act(person.personId,
                          () => _repo.requestConnection(person.personId)),
                      style:
                          TextButton.styleFrom(foregroundColor: AppColors.cyan),
                      child: const Text('Add'),
                    ),
            ),
        ],
        const SizedBox(height: 18),
        const Divider(height: 1, color: AppColors.line),
        const _YourStatus(),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 16, 2, 6),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.7,
          ),
        ),
      );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}

/// One person, one row, and the row is the way in.
///
/// No card and no border. The first version boxed every name in its own
/// surface, which turns a list of eight people into eight objects to look at
/// rather than a list to read down.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.name,
    required this.line,
    required this.onTap,
    this.avatarPath,
    this.trailing,
    this.here = false,
    this.dimmed = false,
    this.lineIsStatus = false,
  });

  final String name;
  final String line;
  final String? avatarPath;
  final Widget? trailing;
  final bool here;
  final bool dimmed;
  final bool lineIsStatus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: <Widget>[
            Stack(
              children: <Widget>[
                Opacity(
                  opacity: dimmed ? 0.55 : 1,
                  child: PlayerFace(
                    name: name,
                    color: AppColors.cyan,
                    photo: controller.avatarBytesFor(avatarPath),
                    size: 42,
                  ),
                ),
                // No grey dot for offline. A column of grey circles is what
                // this list would be on almost every day, and it would make a
                // working feature read as a dead one.
                if (here)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      key: Key('here_$name'),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: AppColors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.deepNavy, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: dimmed ? AppColors.muted : AppColors.text,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (line.isNotEmpty)
                    Text(
                      here ? 'Here now  ·  $line' : line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: here
                            ? AppColors.green
                            : lineIsStatus
                                ? AppColors.cyan
                                : AppColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else
              const Icon(Icons.chevron_right_rounded,
                  size: 19, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.standing,
    required this.busy,
    required this.onAdd,
  });

  final ConnectionStanding standing;
  final bool busy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    if (busy) return const _Spinner();
    // What the button says is decided by the server, so a name found in a
    // search cannot offer to add somebody you already asked last week.
    return switch (standing) {
      ConnectionStanding.accepted => const Text('Connected',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
      ConnectionStanding.pending => const Text('Asked',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
      ConnectionStanding.none => TextButton(
          onPressed: onAdd,
          style: TextButton.styleFrom(foregroundColor: AppColors.cyan),
          child: const Text('Add'),
        ),
    };
  }
}

class _NobodyYet extends StatelessWidget {
  const _NobodyYet();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(8, 40, 8, 24),
        child: Column(
          children: <Widget>[
            Icon(Icons.group_outlined, size: 34, color: AppColors.muted),
            SizedBox(height: 14),
            Text(
              'Nobody here yet',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Search for somebody by name, or add the people you are already '
              'in a room with. Adding somebody lets you reach them directly, '
              'without putting them in a room first.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.55),
            ),
          ],
        ),
      );
}

/// Your own status, said in a sentence, at the end.
///
/// The first version opened on this as a box of chips — a form about yourself
/// on the screen you came to in order to look at somebody else. It is one
/// line now, and it still says the thing that matters: what your people see
/// before they ask you for anything.
class _YourStatus extends StatefulWidget {
  const _YourStatus();

  @override
  State<_YourStatus> createState() => _YourStatusState();
}

class _YourStatusState extends State<_YourStatus> {
  Availability _state = Availability.unset;
  bool _busy = false;

  static const Map<Availability, String> _words = <Availability, String>{
    Availability.open: 'up for playing',
    Availability.busy: 'heads down',
    Availability.away: 'away',
    Availability.unset: 'saying nothing',
  };

  static String _label(Availability option) => switch (option) {
        Availability.open => 'Up for playing',
        Availability.busy => 'Heads down',
        Availability.away => 'Away',
        Availability.unset => 'Say nothing',
      };

  Future<void> _pick() async {
    final chosen = await showModalBottomSheet<Availability>(
      context: context,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'What your people see',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            for (final option in Availability.values)
              ListTile(
                key: Key('availability_${option.name}'),
                title: Text(_label(option)),
                trailing: _state == option
                    ? const Icon(Icons.check_rounded, color: AppColors.cyan)
                    : null,
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    setState(() {
      _state = chosen;
      _busy = true;
    });
    try {
      await BetaScope.of(context, listen: false).repository.setAvailability(
            chosen,
            // A fortnight, and then it is not true any more. A status with no
            // end is one somebody sets in a good week and forgets, while the
            // app goes on telling their band they are free.
            until: chosen == Availability.unset
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
    return InkWell(
      key: const Key('your_status'),
      onTap: _busy ? null : () => unawaited(_pick()),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        child: Row(
          children: <Widget>[
            const Icon(Icons.person_outline_rounded,
                size: 18, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your people see you as ${_words[_state]}',
                style: const TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ),
            const Text('Change',
                style: TextStyle(
                    color: AppColors.cyan,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}
