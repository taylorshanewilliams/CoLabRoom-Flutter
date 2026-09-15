import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';

/// Something you can now do.
///
/// The seventh kind of Tonight: unlocked by use rather than by time, and
/// shown once. The first song sheet unlocks asking the app about it and
/// practising to it; words with no recording unlock singing them; a room of
/// one unlocks inviting somebody; a band unlocks asking it for a part and
/// saying something in its thread. Nothing here is a lesson and nothing
/// here nags: each is a door that has just opened, named once, and then
/// left alone.
///
/// Pure, over what the app already holds, so the rule can be tested.
enum FirstGo { openSong, record, messages, openMic }

class First {
  const First({
    required this.id,
    required this.title,
    required this.body,
    required this.cta,
    required this.go,
    this.projectId,
  });

  /// Stable, so "not now" closes exactly this door: `first-ask-app`,
  /// `first-invite`, and so on. One per kind, not per song.
  final String id;
  final String title;
  final String body;
  final String cta;
  final FirstGo go;
  final String? projectId;
}

List<First> firstsFor({
  required String me,
  required List<MusicRoom> rooms,
  required List<ThreadSummary> threads,
}) {
  final firsts = <First>[];
  final songs = <SongProject>[for (final room in rooms) ...room.projects];

  // A sheet: the app now knows the song, so it can be asked, and played to.
  final withSheet = songs.cast<SongProject?>().firstWhere(
        (s) => s!.analysisState == SongAnalysisState.ready,
        orElse: () => null,
      );
  if (withSheet != null) {
    firsts.add(First(
      id: 'first-ask-app',
      title: 'Ask it about ${withSheet.title}',
      body: 'The app knows the key, the chords and the words now. Ask what '
          'fits, what a harmony could sing, where a bridge could go.',
      cta: 'Open ${withSheet.title}',
      go: FirstGo.openSong,
      projectId: withSheet.id,
    ));
    firsts.add(First(
      id: 'first-practise',
      title: 'Practise to ${withSheet.title}',
      body: 'Loop a section, slow it down, mute your own part and play over '
          'the rest. The sheet follows the recording.',
      cta: 'Open ${withSheet.title}',
      go: FirstGo.openSong,
      projectId: withSheet.id,
    ));
  }

  // Words with no recording yet: the sheet is one take away.
  final wordsOnly = songs.cast<SongProject?>().firstWhere(
        (s) => !s!.hasAudioReference && s.contributions.isNotEmpty,
        orElse: () => null,
      );
  if (wordsOnly != null && withSheet == null) {
    firsts.add(First(
      id: 'first-sing-it',
      title: 'Sing ${wordsOnly.title} once',
      body: 'One pass into the phone and the app writes the key and the '
          'chords over the words you already have.',
      cta: 'Record',
      go: FirstGo.record,
      projectId: wordsOnly.id,
    ));
  }

  // A band, or not yet one.
  final bands = rooms.where((room) => room.members.length > 1).toList();
  if (bands.isEmpty) {
    final mine = rooms.cast<MusicRoom?>().firstWhere(
          (room) => room!.members.any((m) => m.userId == me),
          orElse: () => null,
        );
    if (mine != null) {
      firsts.add(First(
        id: 'first-invite',
        title: 'Bring somebody into ${mine.name}',
        body: 'A room with two people in it is a band. Invite by email, or '
            'send the link; they get every song in it and its thread.',
        cta: 'Open Messages',
        go: FirstGo.messages,
      ));
    }
  } else {
    final band = bands.first;
    final songInBand = band.projects.cast<SongProject?>().firstWhere(
          (s) => s!.hasAudioReference,
          orElse: () => null,
        );
    if (songInBand != null) {
      firsts.add(First(
        id: 'first-ask-room',
        title: 'Ask ${band.name} for a part',
        body: 'Every song has an ask on it: name the part, or say you do not '
            'know what it needs. Somebody answers with a take.',
        cta: 'Open ${songInBand.title}',
        go: FirstGo.openSong,
        projectId: songInBand.id,
      ));
    }
    final quiet = threads.any((t) =>
        t.kind == ThreadKind.room && t.targetId == band.id && t.lastAt == null);
    if (quiet) {
      firsts.add(First(
        id: 'first-say-something',
        title: 'Say something in ${band.name}',
        body: 'The room has a thread now, and nobody has used it. The band '
            'hears about it the moment you do.',
        cta: 'Open Messages',
        go: FirstGo.messages,
      ));
    }
  }

  return firsts;
}
