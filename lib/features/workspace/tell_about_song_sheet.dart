import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/player_face.dart';
import '../../widgets/problem_report.dart';

/// Telling somebody, on purpose.
///
/// Taylor: "you could notify indivudual users direcctly to there phone that
/// you uploaded something, changed something, etc...or if you want to notify
/// the whole room, you could do that."
///
/// Everything the app has notified anybody about until now has been automatic
/// — a trigger noticing an invite, an ask, a finished analysis. Useful, and
/// not the same thing as a person deciding somebody should hear this. A band
/// works in bursts: you put a take up on Tuesday and it matters that the bass
/// player knows on Tuesday, not whenever they next happen to open the app.
Future<void> showTellAboutSong(
  BuildContext context, {
  required SongProject project,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _TellSheet(project: project),
  );
}

class _TellSheet extends StatefulWidget {
  const _TellSheet({required this.project});

  final SongProject project;

  @override
  State<_TellSheet> createState() => _TellSheetState();
}

class _TellSheetState extends State<_TellSheet> {
  final TextEditingController _note = TextEditingController();
  List<SuggestedPerson> _people = const <SuggestedPerson>[];
  bool _loading = true;
  bool _sending = false;

  /// Who is ticked. Empty with [_room] true means everybody in the room.
  ///
  /// Multi-select because a band does not divide neatly into "one person" and
  /// "all of them" -- the two who play strings, or everyone except the person
  /// who was there when you recorded it. Making somebody send the same
  /// message four times to reach four people is the kind of thing that stops
  /// them telling anybody.
  final Set<String> _chosen = <String>{};
  bool _room = true;

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
      final people = await BetaScope.of(context, listen: false)
          .repository
          .peopleToTell(widget.project.id);
      if (!mounted) return;
      setState(() {
        _people = people;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showProblem(context, error,
          service: 'app', stage: 'tell.load', route: 'Song');
    }
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final told = await BetaScope.of(context, listen: false)
          .repository
          .tellAboutSong(
            widget.project.id,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            personIds: _room ? null : _chosen.toList(growable: false),
          );
      navigator.pop();
      // How many, not "sent". A room where everybody has blocked you tells
      // nobody, and the button must not claim otherwise.
      messenger.showSnackBar(SnackBar(
        content: Text(told == 0
            ? 'Nobody to tell.'
            : told == 1
                ? 'Told them.'
                : 'Told $told people.'),
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      showProblem(context, error,
          service: 'app', stage: 'tell.send', route: 'Song');
    }
  }

  bool get _canSend => _room || _chosen.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Tell somebody about ${widget.project.title}',
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              'They get it on their phone, if they have notifications on.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...<Widget>[
              // Plain rows rather than radios. RadioListTile's group API is
              // deprecated, and the group logic it needed here read as a
              // puzzle -- "selected unless the room is chosen or this is not
              // the chosen one" is not a thing anybody should have to parse
              // to know what is ticked.
              _Choice(
                key: const Key('tell_room'),
                label: 'Everybody in this room',
                // On by default, and its own kind of thing rather than every
                // name ticked. Somebody who has just put a take up usually
                // means the band, and this keeps meaning the band as people
                // join or leave it.
                selected: _room,
                onTap: () => setState(() {
                  _room = true;
                  _chosen.clear();
                }),
              ),
              if (_people.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6, bottom: 2, left: 4),
                  child: Text('Or pick who',
                      style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
                ),
              for (final person in _people)
                _Choice(
                  key: Key('tell_${person.personId}'),
                  label: person.displayName,
                  // Why they are on the list, in words. The same rule as the
                  // People screen: a fact, never a score.
                  because: person.because,
                  multiple: true,
                  selected: _chosen.contains(person.personId),
                  face: PlayerFace(
                    name: person.displayName,
                    color: AppColors.cyan,
                    photo: controller.avatarBytesFor(person.avatarPath),
                    size: 32,
                  ),
                  onTap: () => setState(() {
                    if (!_chosen.remove(person.personId)) {
                      _chosen.add(person.personId);
                    }
                    // Picking anybody at all means you did not mean "the
                    // room"; unpicking the last one puts it back, because an
                    // empty list would otherwise send to nobody and disable
                    // the button with no explanation.
                    _room = _chosen.isEmpty;
                  }),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('tell_note'),
                controller: _note,
                maxLength: 140,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Say what changed (optional)',
                  hintText: 'New take on the second verse',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('tell_send'),
                  onPressed: _sending || !_canSend ? null : () => unawaited(_send()),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cyan,
                    foregroundColor: AppColors.ink,
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_room
                          ? 'Tell the room'
                          : _chosen.length == 1
                              ? 'Tell them'
                              : 'Tell ${_chosen.length} people'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.because,
    this.face,
    this.multiple = false,
    super.key,
  });

  final String label;
  final String? because;
  final Widget? face;
  final bool selected;

  /// A tick rather than a dot. The shape has to say whether choosing this one
  /// unchooses the others, before somebody finds out by losing a selection.
  final bool multiple;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: <Widget>[
            Icon(
              multiple
                  ? (selected
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded)
                  : (selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded),
              size: 20,
              color: selected ? AppColors.cyan : AppColors.muted,
            ),
            const SizedBox(width: 12),
            if (face != null) ...<Widget>[face!, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                  ),
                  if (because != null)
                    Text(
                      because!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5),
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
