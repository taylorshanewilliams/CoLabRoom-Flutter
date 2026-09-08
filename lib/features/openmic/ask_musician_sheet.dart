import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../domain/musical_roles.dart';
import '../../services/user_facing_error.dart';

/// Asking one musician to play on one song.
///
/// Three decisions, in the order somebody actually makes them: **which song**,
/// **what for**, and **anything to say**. Only the first is required — a
/// musician who does not yet know what a song needs is the normal case, and a
/// form that insisted on a part would turn "come listen to this" into a job
/// specification.
///
/// The part chips are the same vocabulary Open Mic filters on and the same one
/// `song_layers.part` has always spoken, so what somebody is asked for is what
/// they get counted for when they play it.
class AskMusicianSheet extends StatefulWidget {
  const AskMusicianSheet({
    required this.musician,
    required this.repository,
    this.suggestedPart,
    super.key,
  });

  final Musician musician;
  final MusicRepository repository;

  /// What the person doing the asking was already looking for.
  ///
  /// Somebody who walked the Open Mic down to *bass*, listened to three
  /// people and tapped one of them has already said what they want — twice,
  /// in two screens. Making them say it a third time in this sheet is the
  /// app asking them to re-enter a decision it watched them make.
  ///
  /// Only ever a starting point. It is the same chip row as before and any
  /// of it can be tapped off, because what you searched for and what you
  /// want from this particular person are allowed to differ.
  final String? suggestedPart;

  @override
  State<AskMusicianSheet> createState() => _AskMusicianSheetState();
}

class _AskMusicianSheetState extends State<AskMusicianSheet> {
  /// The one list, so what somebody can be asked for matches what they can
  /// say they do.
  static List<MusicalRole> get _parts => MusicalRole.offered;


  final TextEditingController _note = TextEditingController();
  List<OfferableSong>? _songs;
  String? _songId;
  late String? _part = widget.suggestedPart;

  /// Whether somebody has touched the part chips themselves.
  ///
  /// Until they do, the suggestion follows the song they have selected. After
  /// they do, it stops moving — a control that keeps changing under somebody
  /// who has just set it is worse than one that never helps at all.
  bool _chosePart = false;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final songs = await widget.repository.songsICanOffer(widget.musician.id);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        // The most recently touched song they could offer, preselected — it
        // is the one they are almost always here about, and a picker that
        // starts on nothing makes everybody do the same tap.
        _songId = songs.where((s) => !s.alreadyAsked).firstOrNull?.id;
        _part ??= _whatThisSongLacks(_songId);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _songs = const <OfferableSong>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'songs_i_can_offer',
          route: 'Ask a musician',
        );
      });
    }
  }

  /// What they play most, offered first.
  ///
  /// A bass player is usually being asked for bass. Putting their own record
  /// at the front of the chip row means the common case is already selected
  /// by the time somebody looks at it.
  List<MusicalRole> get _orderedParts {
    final theirs = widget.musician.partsRecorded.keys.toSet()
      ..addAll(widget.musician.plays);
    // What they actually do, first. Asking somebody for the thing they have
    // said they do is the ask that gets a yes.
    final known = <MusicalRole>[];
    final rest = <MusicalRole>[];
    for (final entry in _parts) {
      (theirs.contains(entry.value) ? known : rest).add(entry);
    }
    return <MusicalRole>[...known, ...rest];
  }

  /// The first thing this person does that the chosen song has not got.
  ///
  /// Two facts, one small step, and the step is taken here rather than in the
  /// database on purpose: what a song *needs* is a musical judgement and the
  /// app has no standing to make it. What it can say is that this person
  /// plays bass and nothing on this song is bass, which is a good enough
  /// reason to have the chip already lit and no reason at all to insist.
  ///
  /// Null when they have nothing to offer that is not already there — in
  /// which case the sheet stays on "not sure yet", which is an honest state
  /// and the one most unfinished songs are actually in.
  String? _whatThisSongLacks(String? songId) {
    if (songId == null) return null;
    final song =
        _songs?.where((candidate) => candidate.id == songId).firstOrNull;
    if (song == null) return null;
    final already = song.partsOnIt.toSet();
    for (final role in _orderedParts) {
      final theirs = widget.musician.partsRecorded.containsKey(role.value) ||
          widget.musician.plays.contains(role.value);
      if (theirs && !already.contains(role.value)) return role.value;
    }
    return null;
  }

  Future<void> _send() async {
    final songId = _songId;
    if (songId == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.repository.askMusician(
        projectId: songId,
        profileId: widget.musician.id,
        part: _part,
        note: _note.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'ask_musician',
          route: 'Ask a musician',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs;
    final name = widget.musician.displayName;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Ask $name',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),

              const _Label('Which song'),
              const SizedBox(height: 8),
              if (songs == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (songs.isEmpty)
                const Text(
                  'You have no songs to offer yet. Record something first — '
                  'a musician deciding whether to help wants to hear what '
                  'they would be helping with.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                )
              else
                for (final song in songs.take(12))
                  _SongRow(
                    song: song,
                    selected: song.id == _songId,
                    onTap: song.alreadyAsked
                        ? null
                        : () => setState(() {
                            _songId = song.id;
                            // The suggestion follows the song until somebody
                            // says otherwise.
                            if (!_chosePart) {
                              _part = widget.suggestedPart ??
                                  _whatThisSongLacks(song.id);
                            }
                          }),
                  ),

              if (songs != null && songs.isNotEmpty) ...<Widget>[
                const SizedBox(height: 20),
                const _Label('What for', note: 'optional'),
                const SizedBox(height: 4),
                // Said plainly, because "leave it blank" is a real and often
                // correct answer. Sometimes you know exactly what a song
                // needs; sometimes finding out is the reason you are asking.
                const Text(
                  'Leave it blank if you would rather hear what they think '
                  'it needs.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: <Widget>[
                    for (final entry in _orderedParts)
                      FilterChip(
                        label: Text(entry.label),
                        selected: _part == entry.value,
                        onSelected: (on) =>
                            setState(() {
                              _chosePart = true;
                              _part = on ? entry.value : null;
                            }),
                        showCheckmark: false,
                        backgroundColor: AppColors.raised,
                        selectedColor: AppColors.cyan.withValues(alpha: 0.18),
                        side: BorderSide(
                          color: _part == entry.value
                              ? AppColors.cyan
                              : AppColors.line,
                        ),
                        labelStyle: TextStyle(
                          color: _part == entry.value
                              ? AppColors.cyan
                              : AppColors.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                const _Label('Anything to say', note: 'optional'),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  maxLines: 3,
                  maxLength: 280,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Heard your stuff — this one needs what you do.',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],

              if (_error != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: const TextStyle(
                      color: AppColors.orange, fontSize: 12.5, height: 1.4),
                ),
              ],

              const SizedBox(height: 14),
              FilledButton(
                onPressed: (_songId == null || _sending)
                    ? null
                    : () => unawaited(_send()),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                ),
                child: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.ink),
                      )
                    : Text('Ask $name'),
              ),
              const SizedBox(height: 8),
              const Text(
                'They can say no, and nothing of yours opens up until they '
                'say yes.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.selected,
    required this.onTap,
  });

  final OfferableSong song;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected ? AppColors.cyan.withValues(alpha: 0.1) : AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(color: selected ? AppColors.cyan : AppColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: disabled
                      ? AppColors.line
                      : (selected ? AppColors.cyan : AppColors.muted),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: disabled ? AppColors.muted : AppColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Shown rather than hidden. A song quietly missing from this
                // list is somebody wondering where it went; "already asked"
                // answers the question they were about to have.
                if (song.alreadyAsked)
                  const Text(
                    'already asked',
                    style: TextStyle(color: AppColors.muted, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
            ),
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
            ),
          ),
        ],
      ],
    );
  }
}
