import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../domain/music_models.dart';
import '../../domain/name_policy.dart';
import '../../services/brought_chart.dart';
import '../../widgets/app_surface.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/note_that_fits.dart';
import '../workspace/bring_a_chart_flow.dart';
import '../workspace/whose_song_sheet.dart';

/// Asks for a name and makes a room with it.
///
/// [unseen] is rooms the calling screen leaves out of its list. Room names
/// are unique per account, so one of those still holds its name, and making
/// a room called that would be refused as taken by a room the person cannot
/// find anywhere. They get that room instead (review, 17 September 2026).
Future<MusicRoom?> showCreateRoomDialog(
  BuildContext context,
  MusicBetaController controller, {
  Iterable<MusicRoom> unseen = const <MusicRoom>[],
}) async {
  final draft = await showDialog<_RoomDraft>(
    context: context,
    builder: (_) => const _CreateRoomDialog(),
  );
  if (draft == null) return null;
  for (final room in unseen) {
    if (NamePolicy.same(room.name, draft.name)) return room;
  }
  try {
    return await controller.createRoom(name: draft.name, icon: draft.icon);
  } catch (error) {
    if (context.mounted) _showError(context, error);
    return null;
  }
}

Future<SongProject?> showNewSongFlow(
  BuildContext context,
  MusicBetaController controller, {
  MusicRoom? initialRoom,
}) async {
  final room = initialRoom ?? await chooseRoomForNewSong(context, controller);
  if (room == null || !context.mounted) return null;
  return _askForSongTitle(context, controller, room);
}

/// Where a new song should live: a room somebody picks, or one they make
/// without leaving.
///
/// Its own function because two flows need it now — a song started from
/// nothing, and a song started from a chart somebody brought — and a second
/// copy of "pick a room or make one" would be a second set of words for one
/// question.
Future<MusicRoom?> chooseRoomForNewSong(
  BuildContext context,
  MusicBetaController controller,
) async {
  final choice = await showModalBottomSheet<_RoomChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => _RoomPickerSheet(controller: controller),
  );
  if (choice == null || !context.mounted) return null;
  if (!choice.createNew) return choice.room;
  return showCreateRoomDialog(context, controller);
}

/// A song made out of a chart somebody already has.
///
/// Taylor, 19 September 2026: can people practise any song they want in here?
/// This is the way in — a room, a name, the chart, a look at what was
/// understood, and whose song it is.
///
/// **Whose song, asked here rather than later.** Every other song in this app
/// is asked that question the first time its audience moves beyond "Only
/// you", and left unanswered until then (0142). A song made by bringing a
/// chart is different in one way that matters: it is almost always somebody
/// else's, because that is what bringing a chart means. So it is asked once,
/// in the same three words it is asked in everywhere else, and an unanswered
/// one is kept as somebody else's — the answer that keeps it in the room, off
/// both public surfaces, and exporting its chords without its words.
Future<SongProject?> showLearnASongFlow(
  BuildContext context,
  MusicBetaController controller, {
  MusicRoom? initialRoom,
}) async {
  final room = initialRoom ?? await chooseRoomForNewSong(context, controller);
  if (room == null || !context.mounted) return null;

  final named = await showDialog<_SongAndArtist>(
    context: context,
    builder: (_) => _LearnASongDialog(roomName: room.name),
  );
  if (named == null || !context.mounted) return null;

  // The chart is read before the song exists, so that cancelling at the
  // preview leaves nothing behind. A half-made song with no chart in it is
  // exactly the litter the Studio's old holding pen used to leave.
  final chart = await readAChart(context, songTitle: named.title);
  if (chart == null || !context.mounted) return null;

  final SongProject project;
  try {
    project = await controller.createSong(room, named.title);
  } catch (error) {
    if (context.mounted) _showError(context, error);
    return null;
  }

  try {
    await controller.repository.bringChart(
      project.id,
      // The artist goes into the chart rather than into a column of its own:
      // it is a fact the chart states about itself, and ChordPro already has
      // a place for it that every other reader of the format understands.
      _withArtist(chart, named.artist).chordPro,
    );
  } catch (error) {
    if (context.mounted) _showError(context, error);
    return project;
  }

  if (!context.mounted) return project;
  final answer =
      await showWhoseSongSheet(context, songTitle: named.title) ??
          SongOrigin.cover;
  try {
    await controller.repository.setSongOrigin(project.id, answer);
  } catch (error) {
    if (context.mounted) _showError(context, error);
  }
  return project;
}

/// The chart with the artist somebody typed written into it, when the chart
/// did not already name one.
BroughtChart _withArtist(BroughtChart chart, String artist) {
  final said = artist.trim();
  if (said.isEmpty || chart.artist != null) return chart;
  return BroughtChart(
    title: chart.title,
    artist: said,
    key: chart.key,
    capo: chart.capo,
    tuning: chart.tuning,
    lines: chart.lines,
  );
}

Future<SongProject?> _askForSongTitle(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final title = await showDialog<String>(
    context: context,
    builder: (_) => _SongTitleDialog(roomName: room.name),
  );
  if (title == null) return null;
  try {
    return await controller.createSong(room, title);
  } catch (error) {
    if (context.mounted) _showError(context, error);
    return null;
  }
}

void _showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showNote(
    reportAndDescribe(error, service: 'app', route: 'New song'),
  );
}

class _RoomDraft {
  const _RoomDraft(this.name, this.icon);

  final String name;
  final String icon;
}

class _CreateRoomDialog extends StatefulWidget {
  const _CreateRoomDialog();

  @override
  State<_CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends State<_CreateRoomDialog> {
  final _name = TextEditingController();

  /// Still written, never shown.
  ///
  /// The glyph is a column on the room row and the app no longer draws it
  /// anywhere — so the picker that asked for one was asking somebody to
  /// decide something with no consequence, on the screen where they are
  /// trying to name a band. Kept as a constant so existing rooms, the
  /// database default and anything that reads the column all go on working.
  static const String _icon = '♪';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create a room'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Name it your way—capital letters and spaces are preserved.'),
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Room name'),
            ),
          ],
        ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        // Waits for words: with nothing typed it used to close and complain.
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => FilledButton(
            onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, _RoomDraft(_name.text, _icon)),
            child: const Text('Create room'),
          ),
        ),
      ],
    );
  }
}

class _SongTitleDialog extends StatefulWidget {
  const _SongTitleDialog({required this.roomName});

  final String roomName;

  @override
  State<_SongTitleDialog> createState() => _SongTitleDialogState();
}

class _SongTitleDialogState extends State<_SongTitleDialog> {
  final _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name your song'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _title,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Song name',
            helperText: 'Saving to ${widget.roomName}',
            // Wraps. Left to itself a helper is one line with an ellipsis, and
            // a room called "Wednesday night at the Old Chapel" left this
            // reading "Saving to Wednesday night at the O…" — the one word
            // that matters cut off (audit, 17 September 2026).
            helperMaxLines: 3,
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value);
          },
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        // Waits for words: with nothing typed it used to close and complain.
        ListenableBuilder(
          listenable: _title,
          builder: (context, _) => FilledButton(
            onPressed: _title.text.trim().isEmpty ? null : () => Navigator.pop(context, _title.text),
            child: const Text('Create Song'),
          ),
        ),
      ],
    );
  }
}

class _SongAndArtist {
  const _SongAndArtist(this.title, this.artist);

  final String title;
  final String artist;
}

/// What the song is called, and who wrote it.
///
/// The artist is optional and says so, because plenty of the songs people
/// bring a chart for are traditional, and plenty more they simply do not
/// know. It is not a form: two boxes, one of which can stay empty.
class _LearnASongDialog extends StatefulWidget {
  const _LearnASongDialog({required this.roomName});

  final String roomName;

  @override
  State<_LearnASongDialog> createState() => _LearnASongDialogState();
}

class _LearnASongDialogState extends State<_LearnASongDialog> {
  final _title = TextEditingController();
  final _artist = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('What are you learning?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                key: const Key('learn_a_song_title'),
                controller: _title,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Song name',
                  helperText: 'Saving to ${widget.roomName}',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('learn_a_song_artist'),
                controller: _artist,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Who wrote it',
                  helperText: 'Optional',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        // Waits for words, like every other name in this app.
        ListenableBuilder(
          listenable: _title,
          builder: (context, _) => FilledButton(
            key: const Key('learn_a_song_next'),
            onPressed: _title.text.trim().isEmpty
                ? null
                : () => Navigator.pop(
                    context, _SongAndArtist(_title.text, _artist.text)),
            child: const Text('Next'),
          ),
        ),
      ],
    );
  }
}

class _RoomChoice {
  const _RoomChoice.room(this.room) : createNew = false;
  const _RoomChoice.create() : room = null, createNew = true;

  final MusicRoom? room;
  final bool createNew;
}

class _RoomPickerSheet extends StatefulWidget {
  const _RoomPickerSheet({required this.controller});

  final MusicBetaController controller;

  @override
  State<_RoomPickerSheet> createState() => _RoomPickerSheetState();
}

class _RoomPickerSheetState extends State<_RoomPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final rooms = widget.controller.rooms.where((room) {
      return NamePolicy.normalized(room.name).contains(NamePolicy.normalized(_query));
    }).toList(growable: false);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Where should this song live?',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 6),
              const Text('Choose a room or create a new one without leaving this flow.'),
              const SizedBox(height: 16),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search rooms',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: rooms.isEmpty
                    ? const Center(child: Text('No rooms match that search.'))
                    : ListView.separated(
                        itemCount: rooms.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final room = rooms[index];
                          return InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => Navigator.pop(context, _RoomChoice.room(room)),
                            child: AppSurface(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      room.name,
                                      style: const TextStyle(
                                        color: AppColors.text,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text('${room.projects.length} ${room.projects.length == 1 ? 'song' : 'songs'}'),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, const _RoomChoice.create()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create a new room'),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
