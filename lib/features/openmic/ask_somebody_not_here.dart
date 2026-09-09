import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../domain/musical_roles.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/problem_report.dart';

/// Asking somebody who is not here yet.
///
/// The room can only ever offer the people already in it, and at four
/// accounts that is nobody. Meanwhile every musician alive already knows a
/// bass player — they are simply not on this app, and the app had no way to
/// reach past its own edge.
///
/// **The invitation nobody can write is the one this can.** "Join my app" is
/// a favour somebody is asking. *"I want you to play bass on this song"* is a
/// compliment with a reason attached, and it is the same sentence the ask
/// sheet already sends to people who are here. Sent outward it becomes the
/// only acquisition loop this app needs: every person who wants something is
/// holding a genuinely good pitch, and the thing they are inviting somebody
/// to do is the thing the app is for.
///
/// It reuses the per-song invitation from 0013 rather than inventing a second
/// kind of pending thing — so what arrives grants exactly one song, claimed
/// on signup by the trigger that has done that since 0026, and no part of
/// somebody's library opens up because a stranger accepted a text message.
class AskSomebodyNotHere extends StatefulWidget {
  const AskSomebodyNotHere({
    required this.repository,
    required this.myName,
    this.about,
    super.key,
  });

  final MusicRepository repository;

  /// Whose name goes on the message. An invitation from nobody is spam.
  final String myName;

  /// What the room was narrowed to when this was opened, if anything — so
  /// somebody who searched for a bass player and found none is not asked
  /// again what they wanted.
  final String? about;

  @override
  State<AskSomebodyNotHere> createState() => _AskSomebodyNotHereState();
}

class _AskSomebodyNotHereState extends State<AskSomebodyNotHere> {
  final TextEditingController _email = TextEditingController();
  List<OfferableSong>? _songs;
  String? _songId;
  late String? _part = widget.about;
  String? _error;
  bool _sending = false;

  /// The finished message, once there is one.
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // Songs I could offer somebody. Asked about myself, which returns my
      // own catalogue with nothing marked as already asked — the picker
      // wants the list, not the comparison.
      final songs = await widget.repository
          .songsICanOffer(widget.repository.currentUserId);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _songId = songs.firstOrNull?.id;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _songs = const <OfferableSong>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'songs_i_can_offer',
          route: 'Ask somebody not here',
        );
      });
    }
  }

  OfferableSong? get _song =>
      _songs?.where((song) => song.id == _songId).firstOrNull;

  Future<void> _make() async {
    final song = _song;
    if (song == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final invite = await widget.repository.createProjectInviteFor(
        projectId: song.id,
        email: _email.text,
      );
      if (!mounted) return;
      setState(() {
        _message = _compose(song, invite.code);
        _sending = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'create_project_invitation',
          route: 'Ask somebody not here',
        );
      });
    }
  }

  /// What actually gets sent.
  ///
  /// Written to be read in a text message by somebody who has never heard of
  /// this app, so it leads with the ask and never with the product. The
  /// second line is the promise that makes it safe to accept: one song, not
  /// somebody's whole library.
  String _compose(OfferableSong song, String code) {
    final part = _part;
    final what = part == null
        ? 'play on'
        : 'play ${MusicalRole.labelFor(part).toLowerCase()} on';
    return '${widget.myName} would like you to $what “${song.title}”.\n\n'
        'It is on CoLabRoom. You can hear the song and put a part on it — '
        'just that one song, nothing else of theirs.\n\n'
        'Your invite code: $code';
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 6,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 18,
        ),
        child: SingleChildScrollView(
          child: message != null ? _ready(message) : _form(),
        ),
      ),
    );
  }

  Widget _form() {
    final songs = _songs;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Ask somebody who is not here yet',
          style: TextStyle(
              color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'You already know somebody who plays. This sends them the song and '
          'what you want, not an advert.',
          style:
              TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
        ),
        const SizedBox(height: 16),
        if (songs == null)
          const Center(
              child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: AppColors.gold),
          ))
        else if (songs.isEmpty)
          const Text(
            'You have no songs to offer yet. Record something first — an '
            'invitation with nothing to listen to is an advert.',
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
          )
        else ...<Widget>[
          const _Label('Which song'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _songId,
            isExpanded: true,
            decoration: const InputDecoration(
                isDense: true, border: OutlineInputBorder()),
            items: <DropdownMenuItem<String>>[
              for (final song in songs)
                DropdownMenuItem<String>(
                  value: song.id,
                  child: Text(song.title, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => _songId = value),
          ),
          const SizedBox(height: 16),
          const _Label('What for', note: 'optional'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              for (final role in MusicalRole.offered)
                FilterChip(
                  label: Text(role.label),
                  selected: _part == role.value,
                  onSelected: (on) =>
                      setState(() => _part = on ? role.value : null),
                  showCheckmark: false,
                  backgroundColor: AppColors.raised,
                  selectedColor: AppColors.cyan.withValues(alpha: 0.18),
                  side: BorderSide(
                    color:
                        _part == role.value ? AppColors.cyan : AppColors.line,
                  ),
                  labelStyle: TextStyle(
                    color:
                        _part == role.value ? AppColors.cyan : AppColors.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const _Label('Their email'),
          const SizedBox(height: 6),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'so it finds them when they join',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            ProblemNote(_error!),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _sending ? null : () => unawaited(_make()),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.cyan,
                foregroundColor: AppColors.ink,
              ),
              child: Text(_sending ? 'Working…' : 'Write the message'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _ready(String message) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Ready to send',
          style: TextStyle(
              color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppColors.raised,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line),
          ),
          child: SelectableText(
            message,
            style: const TextStyle(
                color: AppColors.text, fontSize: 13, height: 1.5),
          ),
        ),
        const SizedBox(height: 10),
        // Said plainly rather than papered over. There is no public download
        // link yet, and a message promising one would be the app lying about
        // itself in the first sentence somebody ever reads about it.
        const Text(
          'They will need the app. Send them the same link you used to '
          'install it — the code waits until they get here.',
          style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
        ),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                onPressed: () => unawaited(
                    SharePlus.instance.share(ShareParams(text: message))),
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('Send it'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: message));
                if (!mounted) return;
                messenger.showSnackBar(
                  const SnackBar(content: Text('Copied.')),
                );
              },
              child: const Text('Copy'),
            ),
          ],
        ),
      ],
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
      children: <Widget>[
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.1,
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 6),
          Text(note!,
              style: const TextStyle(color: AppColors.line, fontSize: 10)),
        ],
      ],
    );
  }
}
