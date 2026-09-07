import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/user_facing_error.dart';
import 'musician_profile_screen.dart';
import 'open_mic_song_screen.dart';

/// Open Mic — where you meet somebody you have not met.
///
/// The name is the design. A room is yours and a band's; the open mic is a
/// place you visibly step onto and can step off again. That boundary being a
/// *place* rather than a setting is what makes it safe to have at all —
/// "public" is an abstraction nobody trusts, and "put this on the open mic"
/// is a thing a musician can picture.
///
/// **Why this is not a search form.** Instrument, genre, location, Search is
/// what every marketplace builds, and it fails for a reason no filter can
/// express: "guitarist" does not distinguish a metal player from a jazz one.
/// The judgement you actually want is made by ear in about ten seconds. So
/// the filter here is deliberately coarse — it narrows thousands to dozens,
/// and the listening does the rest.
class OpenMicScreen extends StatefulWidget {
  const OpenMicScreen({required this.repository, super.key});

  final MusicRepository repository;

  @override
  State<OpenMicScreen> createState() => _OpenMicScreenState();
}

class _OpenMicScreenState extends State<OpenMicScreen> {
  /// The vocabulary musicians already use, and the one `song_layers.part` has
  /// spoken since it existed. Roles rather than only instruments, because
  /// "lead guitar" and "rhythm guitar" are different jobs and a musician
  /// looking for one is not looking for the other.
  static const List<({String part, String label, IconData icon})> _parts =
      <({String part, String label, IconData icon})>[
        (part: 'vocal', label: 'Singer', icon: Icons.mic_rounded),
        (part: 'harmony', label: 'Harmony', icon: Icons.groups_rounded),
        (part: 'lead', label: 'Lead', icon: Icons.electric_bolt_rounded),
        (part: 'rhythm', label: 'Rhythm', icon: Icons.music_note_rounded),
        (part: 'bass', label: 'Bass', icon: Icons.waves_rounded),
        (part: 'drums', label: 'Drums', icon: Icons.album_rounded),
        (part: 'keys', label: 'Keys', icon: Icons.piano_rounded),
        (part: 'percussion', label: 'Percussion', icon: Icons.grain_rounded),
      ];

  /// People or songs. Two things are on an open mic — who is here, and
  /// what is being played — and this screen only knew about the first.
  bool _showingSongs = false;

  String? _part;
  final TextEditingController _city = TextEditingController();
  List<Musician>? _found;
  List<OpenMicSong>? _songs;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_showingSongs) {
      try {
        final songs =
            await widget.repository.openMicSongs(part: _part, limit: 40);
        if (mounted) setState(() => _songs = songs);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _songs = const <OpenMicSong>[];
          _error = reportAndDescribe(
            error,
            service: 'app',
            stage: 'open_mic_songs',
            route: 'Open Mic',
          );
        });
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    try {
      final found = await widget.repository.findMusicians(
        part: _part,
        city: _city.text,
        limit: 40,
      );
      if (mounted) setState(() => _found = found);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _found = const <Musician>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'find_musicians',
          route: 'Open Mic',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSong(OpenMicSong song) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Open Mic song'),
      builder: (_) => OpenMicSongScreen(
        projectId: song.id,
        repository: widget.repository,
        initial: song,
      ),
    ));
    if (mounted) CurrentRoute.enter('Open Mic');
  }

  Future<void> _openProfile(Musician musician) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => MusicianProfileScreen(
              profileId: musician.id,
              repository: widget.repository,
              initial: musician,
            ),
      ),
    );
    if (mounted) CurrentRoute.enter('Open Mic');
  }

  void _choose(String? part) {
    setState(() => _part = _part == part ? null : part);
    unawaited(_search());
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    // A tab now, not a pushed route, so it wears the same inline header the
    // other tabs do rather than an AppBar. It reached the third slot when the
    // Studio and the Control Room stopped being destinations: three tabs were
    // three filters on one library, and the freed one goes to the part of the
    // app that is supposed to grow.
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  'Open Mic',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
          child: SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.people_alt_rounded, size: 17),
                label: Text('People'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.library_music_rounded, size: 17),
                label: Text('Songs'),
              ),
            ],
            selected: <bool>{_showingSongs},
            onSelectionChanged: (picked) {
              setState(() {
                _showingSongs = picked.first;
                _error = null;
              });
              unawaited(_search());
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _showingSongs
                  ? (_part == null
                      ? 'Songs anybody can listen to'
                      : 'Songs asking for ${_labelFor(_part!).toLowerCase()}')
                  : (_part == null
                      ? 'Everybody who is here'
                      : 'People who play ${_labelFor(_part!).toLowerCase()}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
        ),
        SizedBox(
          height: 82,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            itemCount: _parts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final entry = _parts[index];
              return _PartChip(
                label: entry.label,
                icon: entry.icon,
                selected: _part == entry.part,
                onTap: _busy ? null : () => _choose(entry.part),
              );
            },
          ),
        ),
        if (!_showingSongs)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            controller: _city,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => unawaited(_search()),
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Any city',
              prefixIcon: const Icon(Icons.place_outlined, size: 18),
              suffixIcon: IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search_rounded, size: 20),
                onPressed: _busy ? null : () => unawaited(_search()),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const Divider(height: 1),
        if (_showingSongs)
          Expanded(child: _SongList(
            songs: _songs,
            error: _error,
            onOpen: _openSong,
          ))
        else
        Expanded(
          child:
              found == null
                  ? const Center(
                    child: CircularProgressIndicator(color: AppColors.gold),
                  )
                  : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    children: <Widget>[
                      if (_error != null) ...<Widget>[
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: AppColors.orange,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      if (found.isEmpty)
                        const _Empty()
                      else
                        for (final musician in found)
                          _MusicianCard(
                            musician: musician,
                            filter: _part,
                            onTap: () => _openProfile(musician),
                          ),
                    ],
                  ),
        ),
      ],
    );
  }

  static String _labelFor(String part) {
    for (final entry in _parts) {
      if (entry.part == part) return entry.label;
    }
    return part;
  }
}

/// The songs half of the Open Mic.
///
/// Cards lead with what a song is *asking for*, because that is the one thing
/// that decides whether somebody taps. A list of titles is a list nobody can
/// act on: you cannot tell from "Ladder Of Life" whether it wants a bass
/// player, and playing all of them to find out is exactly the friction that
/// makes a pile of audio go unlistened to.
class _SongList extends StatelessWidget {
  const _SongList({
    required this.songs,
    required this.error,
    required this.onOpen,
  });

  final List<OpenMicSong>? songs;
  final String? error;
  final ValueChanged<OpenMicSong> onOpen;

  @override
  Widget build(BuildContext context) {
    final found = songs;
    if (found == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.gold));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: <Widget>[
        if (error != null) ...<Widget>[
          Text(error!,
              style: const TextStyle(color: AppColors.orange, fontSize: 13)),
          const SizedBox(height: 14),
        ],
        if (found.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Column(
              children: <Widget>[
                Icon(Icons.library_music_outlined,
                    size: 34, color: AppColors.line),
                SizedBox(height: 12),
                Text(
                  'No songs up yet',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                // Names the action rather than describing the mechanism.
                // The old copy explained how a song gets here, which is a
                // sentence about the app; this is one about them.
                Text(
                  'Put one of yours up and let somebody find the part it '
                  'is missing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
            ),
          )
        else
          for (final song in found) _SongCard(song: song, onTap: () => onOpen(song)),
      ],
    );
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({required this.song, required this.onTap});

  final OpenMicSong song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: song.isAsking
                ? AppColors.cyan.withValues(alpha: 0.45)
                : AppColors.line,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  song.ownerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
                if (song.isAsking) ...<Widget>[
                  const SizedBox(height: 9),
                  Text(
                    song.askingFor.isEmpty
                        ? 'Asking for help'
                        : 'Asking for ${song.askingFor.join(', ')}',
                    style: const TextStyle(
                      color: AppColors.cyan,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${song.takeCount} '
                  '${song.takeCount == 1 ? 'part' : 'parts'} to listen to',
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PartChip extends StatelessWidget {
  const _PartChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 74,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color:
              selected
                  ? AppColors.cyan.withValues(alpha: 0.14)
                  : AppColors.raised,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.cyan : AppColors.line,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 21,
              color: selected ? AppColors.cyan : AppColors.muted,
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppColors.cyan : AppColors.text,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MusicianCard extends StatelessWidget {
  const _MusicianCard({
    required this.musician,
    required this.filter,
    required this.onTap,
  });

  final Musician musician;
  final String? filter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final top = musician.topParts;
    // Material rather than a decorated Container, so the tap is visible. An
    // InkWell paints its splash on the nearest Material ancestor, and an
    // opaque box in between hides it — the card would take the tap and look
    // like it had not.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        musician.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (musician.city != null) ...<Widget>[
                      const Icon(
                        Icons.place_outlined,
                        size: 13,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        musician.city!,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),

                // What they have actually played, first and in the app's own colour.
                // A recording is a fact; the list below it is a hope, and the two
                // are never merged into one impression.
                if (top.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final entry in top)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.cyan.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${entry.key} · ${entry.value}',
                            style: TextStyle(
                              color:
                                  entry.key == filter
                                      ? AppColors.cyan
                                      : AppColors.text,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  )
                else
                  Text(
                    musician.plays.isEmpty
                        ? 'Has not recorded anything here yet'
                        : 'Says they play ${musician.plays.join(', ')} · '
                            'nothing recorded here yet',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),

                if (musician.hasRecord) ...<Widget>[
                  const SizedBox(height: 9),
                  Text(
                    '${musician.songsPlayedOn} '
                    '${musician.songsPlayedOn == 1 ? 'song' : 'songs'} · '
                    '${musician.peopleWorkedWith} '
                    '${musician.peopleWorkedWith == 1 ? 'person' : 'people'}',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                    ),
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

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 40),
      child: Column(
        children: <Widget>[
          Icon(Icons.mic_external_off_rounded, size: 34, color: AppColors.line),
          SizedBox(height: 12),
          Text(
            'Nobody here yet',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 6),
          // Offers instead of explaining. The old copy was three accurate
          // sentences about why the list was empty, which left somebody
          // exactly where they found them. Nobody is listed by default and
          // that stays true — but the useful thing to tell the first person
          // here is that they can be first.
          Text(
            'Be the first. List yourself and people looking for what you '
            'play will find you.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
