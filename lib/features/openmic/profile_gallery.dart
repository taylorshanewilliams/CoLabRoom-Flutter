import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/picture_for_upload.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/note_that_fits.dart';
import '../../widgets/play_button.dart';
import 'report_sheet.dart';

/// Pictures on somebody's profile.
///
/// Taylor asked on 19 September 2026 whether a profile could hold a gallery.
/// This is the thin version of the four answers the session gave: up to eight
/// photographs, each with an optional line of the owner's own words, and each
/// optionally tied to one of their own songs that is already on the Open Mic,
/// so a photograph of a gig plays the song from that night.
///
/// What it deliberately does not have: likes, views, counts, ordering by
/// anything except the order the owner put them in, and hosted video. Video
/// is the one thing refused out loud, using 0059's own reason — storage is the
/// line on this bill paid again every month on everything ever uploaded, and a
/// video library is a cost that grows forever on things almost nobody watches.
///
/// The door is the row at the bottom of this section, which is on your own
/// page whether you have pictures or not: an empty gallery is not a reason to
/// hide the way to fill it.
class ProfileGallery extends StatefulWidget {
  const ProfileGallery({
    required this.repository,
    required this.pictures,
    required this.isMe,
    required this.ownerName,
    required this.onChanged,
    super.key,
  });

  final MusicRepository repository;

  /// Null while they are still coming.
  final List<GalleryPicture>? pictures;

  final bool isMe;

  /// Whose page this is, for the bar at the bottom when a picture plays.
  final String ownerName;

  /// Something was added or taken off, so the page should read them again.
  final Future<void> Function() onChanged;

  @override
  State<ProfileGallery> createState() => _ProfileGalleryState();
}

class _ProfileGalleryState extends State<ProfileGallery> {
  /// The images themselves, once each has arrived. Held here rather than in
  /// each tile so that a rebuild of the page does not start eight downloads
  /// over again.
  final Map<String, Uint8List> _images = <String, Uint8List>{};
  final Set<String> _asked = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fetchMissing();
  }

  @override
  void didUpdateWidget(ProfileGallery old) {
    super.didUpdateWidget(old);
    _fetchMissing();
  }

  void _fetchMissing() {
    for (final picture in widget.pictures ?? const <GalleryPicture>[]) {
      if (_asked.add(picture.storagePath)) {
        unawaited(_fetch(picture.storagePath));
      }
    }
  }

  Future<void> _fetch(String path) async {
    try {
      final bytes = await widget.repository.loadGalleryImage(path);
      if (!mounted) return;
      setState(() => _images[path] = bytes);
    } catch (_) {
      // A picture that will not load leaves an empty frame, which is a
      // perfectly good frame. Putting an error on a profile because one
      // image 404'd would be the tail wagging the dog.
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showNote(message);
  }

  Future<void> _add() async {
    if (_busy) return;
    final pictures = widget.pictures ?? const <GalleryPicture>[];
    if (pictures.length >= 8) {
      // The door stays; what it says changes. Opening a picker to refuse the
      // picture afterwards would waste somebody's time to say the same thing.
      _say('You can show up to 8 pictures. Take one off to add another.');
      return;
    }
    // Held across the picker as well as the upload. The picker is the
    // platform's own window rather than a route, so nothing else stops a
    // second press opening a second one.
    setState(() => _busy = true);
    try {
      final file = await FilePicker.pickFile(type: FileType.image);
      if (file == null || !mounted) return;
      final raw = await file.readAsBytes();
      if (!mounted) return;
      if (raw.isEmpty) {
        _say('That file was empty.');
        return;
      }

      final Uint8List bytes;
      try {
        // Shrunk and re-encoded before it goes anywhere, which is also what
        // leaves the EXIF behind. See PictureForUpload.forGallery.
        bytes = await PictureForUpload.forGallery(raw);
      } on PictureThisPhoneCannotRead catch (error) {
        if (mounted) _say(error.toString());
        return;
      }
      if (!mounted) return;

      final added = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.deepNavy,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: _AddPictureSheet(
            repository: widget.repository,
            bytes: bytes,
          ),
        ),
      );
      if (added != true || !mounted) return;
      await widget.onChanged();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(GalleryPicture picture) async {
    final outcome = await showDialog<_PictureOutcome>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _PictureFullScreen(
        repository: widget.repository,
        picture: picture,
        image: _images[picture.storagePath],
        isMine: widget.isMe,
        ownerName: widget.ownerName,
      ),
    );
    if (!mounted) return;
    switch (outcome) {
      case _PictureOutcome.removed:
        await widget.onChanged();
      case _PictureOutcome.reported:
        // Said from the page, after the picture has closed. A note shown
        // while the full-screen dialog is still up is drawn by the Scaffold
        // underneath it, behind a near-black barrier — so somebody who had
        // just reported a photograph saw the photograph, unchanged, and no
        // acknowledgement at all.
        _say('Report sent. Thank you — somebody reads every one of these.');
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pictures = widget.pictures;
    final waiting =
        (pictures ?? const <GalleryPicture>[]).any((each) => each.waiting);

    // Nobody else's empty gallery is worth a heading: a stranger's page with
    // "no pictures yet" on it says nothing except that the app expected more
    // of them.
    if (!widget.isMe && (pictures == null || pictures.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 28),
        // The same heading the rest of the page uses, on purpose: a gallery
        // is one more section of a profile, not a feature announcing itself.
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            const Flexible(
              child: Text(
                'PICTURES',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.3,
                ),
              ),
            ),
            if (widget.isMe) ...<Widget>[
              const SizedBox(width: 8),
              const Flexible(
                child: Text(
                  'up to eight',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.muted, fontSize: 10.5),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 9),
        if (pictures != null && pictures.isNotEmpty) ...<Widget>[
          // Wrapped rather than a strip that scrolls sideways. Two reasons,
          // and they point the same way: eight pictures fit in three rows on
          // any phone, so nothing is hidden behind a sideways swipe nobody is
          // told about — and a scrolling row inside this page would put a
          // second Scrollable in the tree, which is a nested scroll gesture
          // for a person and an ambiguous one for anything looking for the
          // page's own list.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final picture in pictures)
                _PictureTile(
                  picture: picture,
                  image: _images[picture.storagePath],
                  onTap: () => unawaited(_open(picture)),
                ),
            ],
          ),
          if (waiting) ...<Widget>[
            const SizedBox(height: 7),
            const Text(
              'A picture is looked at before anybody else can see it. Anything '
              'dimmed is still waiting.',
              key: Key('gallery_waiting_note'),
              style: TextStyle(
                  color: AppColors.muted, fontSize: 12, height: 1.45),
            ),
          ],
        ] else if (widget.isMe) ...<Widget>[
          const Text(
            'A photo from a gig, your pedalboard, the band in 2019. Tie one '
            'to a song of yours and tapping it plays the song.',
            style: TextStyle(
                color: AppColors.muted, fontSize: 12.5, height: 1.45),
          ),
        ],
        if (widget.isMe) ...<Widget>[
          const SizedBox(height: 6),
          // Always here, full or empty. A door that only exists once there is
          // already something behind it is one nobody finds the first time.
          TextButton.icon(
            key: const Key('add_gallery_pictures'),
            onPressed: _busy ? null : () => unawaited(_add()),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.cyan,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 40),
              alignment: Alignment.centerLeft,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text(
              'Add pictures',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ],
    );
  }
}

/// One picture on the wall.
class _PictureTile extends StatelessWidget {
  const _PictureTile({
    required this.picture,
    required this.image,
    required this.onTap,
  });

  final GalleryPicture picture;
  final Uint8List? image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bytes = image;
    final caption = picture.caption.trim();
    return Semantics(
      button: true,
      // The words are the only thing a screen reader can be told about a
      // photograph, so they are said rather than left as decoration.
      label: caption.isEmpty ? 'A picture' : 'A picture: $caption',
      child: Opacity(
        // Dimmed while it is still waiting to be looked at, which is the
        // difference between "yours to see" and "everybody's".
        opacity: picture.waiting ? 0.45 : 1,
        child: Material(
          color: AppColors.raised,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.line),
          ),
          child: InkWell(
            key: Key('gallery_picture_${picture.id}'),
            onTap: onTap,
            child: SizedBox(
              // Small enough that three fit across the narrowest phone this
              // app draws on, so eight pictures are three rows and not four.
              width: 96,
              height: 96,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (bytes != null)
                    Image.memory(bytes, fit: BoxFit.cover)
                  else
                    const Center(
                      child: Icon(Icons.image_outlined,
                          size: 22, color: AppColors.muted),
                    ),
                  if (picture.playsASong)
                    const Positioned(
                      right: 6,
                      bottom: 6,
                      child: _PlaysASongMark(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The mark that says this one makes a sound when you open it.
class _PlaysASongMark extends StatelessWidget {
  const _PlaysASongMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.72),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.music_note_rounded,
          size: 13, color: AppColors.cyan),
    );
  }
}

/// What happened while a picture was open, if anything did.
enum _PictureOutcome { removed, reported }

/// A picture, the size of the screen, with whatever belongs to it.
class _PictureFullScreen extends StatefulWidget {
  const _PictureFullScreen({
    required this.repository,
    required this.picture,
    required this.image,
    required this.isMine,
    required this.ownerName,
  });

  final MusicRepository repository;
  final GalleryPicture picture;
  final Uint8List? image;
  final bool isMine;
  final String ownerName;

  @override
  State<_PictureFullScreen> createState() => _PictureFullScreenState();
}

class _PictureFullScreenState extends State<_PictureFullScreen> {
  /// Shown here rather than in a note. A snackbar raised from inside this
  /// dialog belongs to the page underneath it and is drawn behind the
  /// barrier, where it is as good as invisible.
  String? _problem;

  Future<void> _remove() async {
    try {
      await widget.repository.removeGalleryPicture(widget.picture.id);
      if (mounted) Navigator.pop(context, _PictureOutcome.removed);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _problem = reportAndDescribe(
          error,
          service: 'app',
          stage: 'remove_gallery_picture',
          route: 'Profile',
        );
      });
    }
  }

  Future<void> _report() async {
    final sent = await showReportSheet(
      context,
      repository: widget.repository,
      kind: 'gallery_picture',
      about: 'this picture',
      pictureId: widget.picture.id,
    );
    // Closed, so the page can say so where it can be read.
    if (sent && mounted) Navigator.pop(context, _PictureOutcome.reported);
  }

  @override
  Widget build(BuildContext context) {
    final picture = widget.picture;
    final isMine = widget.isMine;
    final bytes = widget.image;
    final caption = picture.caption.trim();
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: AppColors.deepNavy,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.contain)
                      : const SizedBox(
                          height: 180,
                          child: Center(
                            child: Icon(Icons.image_outlined,
                                size: 28, color: AppColors.muted),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (caption.isNotEmpty)
                      Text(
                        caption,
                        key: const Key('gallery_caption'),
                        style: const TextStyle(
                            color: AppColors.text, fontSize: 14.5, height: 1.45),
                      ),
                    if (picture.playsASong) ...<Widget>[
                      if (caption.isNotEmpty) const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          PlayButton(
                            key: Key('gallery_play_${picture.id}'),
                            storagePath: picture.songStoragePath,
                            durationMs: picture.songDurationMs,
                            title: picture.songTitle,
                            byline: widget.ownerName,
                            songId: picture.songId,
                            size: 38,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              picture.songTitle ?? 'A song',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (picture.waiting) ...<Widget>[
                      const SizedBox(height: 12),
                      const Text(
                        'Only you can see this one yet. Every picture is '
                        'looked at first.',
                        style: TextStyle(
                            color: AppColors.muted, fontSize: 12.5, height: 1.45),
                      ),
                    ],
                    if (_problem != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        _problem!,
                        key: const Key('gallery_picture_problem'),
                        style: const TextStyle(
                            color: AppColors.orange, fontSize: 12.5, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Row(
                  children: <Widget>[
                    if (isMine)
                      TextButton.icon(
                        key: const Key('remove_gallery_picture'),
                        onPressed: () => unawaited(_remove()),
                        icon: const Icon(Icons.delete_outline_rounded, size: 17),
                        label: const Text('Take it off'),
                        style:
                            TextButton.styleFrom(foregroundColor: AppColors.muted),
                      )
                    else
                      TextButton.icon(
                        key: const Key('report_gallery_picture'),
                        onPressed: () => unawaited(_report()),
                        icon: const Icon(Icons.flag_outlined, size: 17),
                        label: const Text('Report'),
                        style:
                            TextButton.styleFrom(foregroundColor: AppColors.muted),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                          foregroundColor: AppColors.text),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a picture is, before it goes up: words, and maybe a song.
class _AddPictureSheet extends StatefulWidget {
  const _AddPictureSheet({required this.repository, required this.bytes});

  final MusicRepository repository;
  final Uint8List bytes;

  @override
  State<_AddPictureSheet> createState() => _AddPictureSheetState();
}

class _AddPictureSheetState extends State<_AddPictureSheet> {
  final TextEditingController _caption = TextEditingController();
  List<OpenMicSong>? _songs;
  String? _songId;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSongs());
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  /// Your own songs that are already out in the open.
  ///
  /// Only those: the server refuses anything else, because a picture that
  /// plays a song in a private room would be a way into a room nobody was
  /// let into (0171).
  Future<void> _loadSongs() async {
    try {
      final mine = widget.repository.currentUserId;
      final songs = await widget.repository.songsBy(mine);
      if (!mounted) return;
      setState(() => _songs = <OpenMicSong>[
            for (final song in songs)
              if (song.ownerId == mine) song,
          ]);
    } catch (_) {
      if (mounted) setState(() => _songs = const <OpenMicSong>[]);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.repository.addGalleryPicture(
        bytes: widget.bytes,
        caption: _caption.text.trim(),
        songId: _songId,
      );
      if (mounted) Navigator.pop(context, true);
    } on PictureRefused catch (refusal) {
      // A picture that was looked at and turned down. Without this the sheet
      // closed like a success and the picture was simply not on the page: a
      // classifier will sometimes refuse an innocent photograph of a gig, and
      // somebody told nothing tries the same one again, leaving another
      // stored object behind each time.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = refusal.toString();
      });
    } catch (error) {
      if (!mounted) return;
      // The cap is raised with the same code a full Room uses, so without
      // this the ninth picture would be refused with "That Room is full."
      const whenFull = 'You can show up to 8 pictures.';
      setState(() {
        _busy = false;
        _problem = isRefusal(error)
            ? describeForUser(error, whenFull: whenFull)
            : reportAndDescribe(
                error,
                service: 'app',
                stage: 'add_gallery_picture',
                route: 'Profile',
                whenFull: whenFull,
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Put this on your profile',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: Image.memory(widget.bytes, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('gallery_caption_field'),
                controller: _caption,
                maxLength: 140,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'A line about it (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'PLAYS A SONG',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              if (songs == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (songs.isEmpty)
                const Text(
                  'A picture can play one of your own songs once it is on the '
                  'Open Mic. None of yours is yet.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                )
              else
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: <Widget>[
                    ChoiceChip(
                      label: const Text('No song'),
                      selected: _songId == null,
                      onSelected: (_) => setState(() => _songId = null),
                    ),
                    for (final song in songs)
                      ChoiceChip(
                        key: Key('gallery_song_${song.id}'),
                        label: Text(song.title),
                        selected: _songId == song.id,
                        onSelected: (_) => setState(() => _songId = song.id),
                      ),
                  ],
                ),
              if (_problem != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  _problem!,
                  style: const TextStyle(
                      color: AppColors.orange, fontSize: 12.5, height: 1.4),
                ),
              ],
              const SizedBox(height: 14),
              FilledButton(
                key: const Key('gallery_add_confirm'),
                onPressed: _busy ? null : () => unawaited(_submit()),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                ),
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.ink),
                      )
                    : const Text('Add it'),
              ),
              const SizedBox(height: 6),
              // Said before it goes, not after. Somebody putting a photograph
              // on a page strangers read wants to know what happens to it.
              const Text(
                'Every picture is looked at before anybody else sees it.',
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
