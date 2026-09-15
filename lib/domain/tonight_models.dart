/// What the server hands the Tonight card (see features/songs/tonight.dart).

/// A prompt from the table, for today: a first line to record, or a
/// practice challenge.
class TonightPrompt {
  const TonightPrompt({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.cta,
  });

  final int id;

  /// `first_line` or `challenge`.
  final String kind;
  final String title;
  final String body;
  final String cta;
}

/// One of your songs the server picked, with what it knows about it.
class TonightSong {
  const TonightSong({
    required this.projectId,
    required this.title,
    required this.key,
    required this.chords,
  });

  final String projectId;
  final String title;
  final String key;

  /// Chord labels as the analyser stored them (Harte or typed).
  final List<String> chords;
}

/// A release the app can announce, written at merge time from the pull
/// request title.
class ReleaseNote {
  const ReleaseNote({
    required this.sha,
    required this.title,
    required this.body,
    required this.mergedAt,
  });

  final String sha;
  final String title;
  final String body;
  final DateTime mergedAt;
}

/// Today's prompt and song together, as the one call returns them.
class Tonight {
  const Tonight({this.prompt, this.song});

  final TonightPrompt? prompt;
  final TonightSong? song;
}
