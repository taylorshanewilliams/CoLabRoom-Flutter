import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/music_models.dart';
import '../domain/song_analysis_models.dart';

/// A song kept on this phone, read back from disk: its words and its sheet.
///
/// The recording and the stems are files beside these two and are found
/// through [KeptSongs.audioPath], by the storage path the sheet names.
class KeptSong {
  const KeptSong({required this.project, required this.sheet});

  final SongProject project;
  final SongAnalysisBundle sheet;
}

/// Songs kept on this phone, so Perform works where there is no signal.
///
/// Basements, stages and vans have no signal, and until now nothing about a
/// song lived on the phone for longer than the OS chose to keep a temporary
/// file: the recording was fetched into the temp directory, and the sheet
/// (words, chords, beats, sections) was read from the server every time
/// Perform opened (Every Musician, Same Song, 17 September 2026, slice 18).
///
/// This follows the pattern the takes already use. A take, once fetched,
/// sits under the app's documents directory named by its id and is never
/// fetched again, because the audio it holds cannot change. A reference
/// recording and a stem are the same kind of thing: each is one storage
/// object at one path, written once and never rewritten (re-recording makes
/// a new path), so a kept file that exists is correct by definition.
///
/// Nothing here is shared. Keeping a song is a convenience of this phone,
/// like the key it is read in; the room is told nothing, Follow me carries
/// nothing, and the only things ever written here are things this person's
/// own session could already download. The privacy check is the storage
/// policy that answers that download, exactly as it is when the song plays
/// online, and a kept copy of a song this person can no longer open is
/// dropped the next time the library loads (see MusicBetaController).
class KeptSongs {
  KeptSongs({
    Future<Directory> Function()? root,
    Future<Uint8List> Function(String storagePath)? download,
    String? Function()? owner,
  })  : _root = root ?? getApplicationDocumentsDirectory,
        _download = download ?? _fromRoomFiles,
        _owner = owner ?? _signedInAccount;

  /// Where the app's own files live. The documents directory in production;
  /// a test hands in a temporary one.
  final Future<Directory> Function() _root;

  /// One object from the room-files bucket, through this person's own
  /// session, which is what makes anything kept here something they were
  /// allowed to hear.
  final Future<Uint8List> Function(String storagePath) _download;

  /// Whose kept songs these are: the account signed in on this phone, or
  /// null when nobody is.
  ///
  /// Everything is kept under the account that kept it, and nothing is
  /// answered to anybody else. Take files need no such rule, because a take
  /// on disk is only ever reached through a row the server just handed
  /// over. A kept song is reached with no server at all -- that is the
  /// point of it -- so on a phone two people sign in to, the second would
  /// otherwise be offered the first one's songs. The session is restored
  /// from the phone without a network, so this answers in the van too.
  final String? Function() _owner;

  static Future<Uint8List> _fromRoomFiles(String storagePath) =>
      Supabase.instance.client.storage.from('room-files').download(storagePath);

  static String? _signedInAccount() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      // No Supabase at all: a preview, or a widget test. Nobody's songs.
      return null;
    }
  }

  /// A browser has no filesystem to keep anything in, and `path_provider`
  /// does not degrade there: it throws. Everything below answers "nothing
  /// kept" on the web rather than asking.
  static bool get supported => !kIsWeb;

  /// What Perform says when it was opened with no connection on a song that
  /// is not here.
  static const String notKeptOffline =
      'No connection, and this song is not kept on this phone. '
      'The words are here; the recording and its sheet are not.';

  /// What Perform says when the sheet could not be fetched for some other
  /// reason and there is no copy here to fall back on.
  static const String sheetNotLoaded =
      'The song sheet could not be loaded. '
      'The words are here; the recording and its sheet are not.';

  static const String _songFile = 'song.json';
  static const String _sheetFile = 'sheet.json';

  /// This account's folder, or null when nobody is signed in -- asked
  /// before the filesystem is, so a signed-out phone touches nothing.
  Future<Directory?> _keptRoot() async {
    final owner = _owner();
    if (owner == null || owner.isEmpty) return null;
    return Directory('${(await _root()).path}/kept/${_fileNameFor(owner)}');
  }

  Future<Directory?> _songDirectory(String projectId) async {
    final root = await _keptRoot();
    return root == null ? null : Directory('${root.path}/${_fileNameFor(projectId)}');
  }

  /// The file a storage object is kept under: its path made safe for a
  /// filesystem, inside the song's own folder.
  ///
  /// Named by the storage path rather than by role ("reference", "vocals")
  /// so that a re-recorded song whose sheet now names a different object
  /// cannot be answered with the old one. The name is long; it is also
  /// unambiguous.
  static String _fileNameFor(String storagePath) =>
      storagePath.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// The kept copy of one storage object, or null when it is not here.
  ///
  /// This is what the audio loaders ask first, before the temp cache and
  /// long before the network, and it is why Perform plays a kept song with
  /// no code of its own about being offline.
  Future<String?> audioPath(String projectId, String storagePath) async {
    if (!supported) return null;
    try {
      final directory = await _songDirectory(projectId);
      if (directory == null) return null;
      final file = File('${directory.path}/${_fileNameFor(storagePath)}');
      if (await file.exists() && await file.length() > 0) return file.path;
    } catch (_) {
      // A filesystem that will not answer is a song that is not kept.
    }
    return null;
  }

  /// Whether the whole song is here: its words, its sheet, and every
  /// recording the sheet names.
  ///
  /// The recording is the part that can be missing. A download cut off
  /// half-way leaves the words and the sheet and no audio, which is a song
  /// that would open in Perform and then fail to play, so it is not "kept"
  /// and the menu offers to keep it again — which fetches only what is
  /// missing.
  Future<bool> isKept(String projectId) async {
    final kept = await load(projectId);
    if (kept == null) return false;
    for (final path in _audioNamedBy(kept.sheet)) {
      if (await audioPath(projectId, path) == null) return false;
    }
    return true;
  }

  /// Every song with words kept here, by title.
  ///
  /// Only the words are read, which is a small file per song; the sheet is
  /// read when the song is opened.
  Future<List<SongProject>> list() async {
    if (!supported) return const <SongProject>[];
    final songs = <SongProject>[];
    try {
      final root = await _keptRoot();
      if (root == null || !await root.exists()) return const <SongProject>[];
      await for (final entry in root.list()) {
        if (entry is! Directory) continue;
        final project = await _readProject(entry);
        if (project != null) songs.add(project);
      }
    } catch (_) {
      // Whatever was read before the filesystem stopped answering.
    }
    songs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return songs;
  }

  /// The ids of every song with words kept here. Read from the kept words
  /// rather than from folder names, so an id is exactly what the server
  /// calls the song.
  Future<Set<String>> keptIds() async =>
      <String>{for (final song in await list()) song.id};

  /// The kept words and sheet for one song, or null when it is not here or
  /// what is here cannot be read.
  Future<KeptSong?> load(String projectId) async {
    if (!supported) return null;
    try {
      final directory = await _songDirectory(projectId);
      if (directory == null) return null;
      final project = await _readProject(directory);
      if (project == null) return null;
      final sheetFile = File('${directory.path}/$_sheetFile');
      if (!await sheetFile.exists()) return null;
      final sheet = _bundleFromJson(
        projectId,
        Map<String, dynamic>.from(jsonDecode(await sheetFile.readAsString()) as Map),
      );
      return KeptSong(project: project, sheet: sheet);
    } catch (_) {
      return null;
    }
  }

  Future<SongProject?> _readProject(Directory directory) async {
    final file = File('${directory.path}/$_songFile');
    if (!await file.exists()) return null;
    try {
      return _projectFromJson(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  /// Keeps a song here: its recording and stems first, then its words and
  /// sheet.
  ///
  /// Audio first, deliberately, the way a take is uploaded bytes first and
  /// row second. The sheet's presence is what says the song is kept, so it
  /// is written last: a keep cut off half-way leaves audio nobody reads,
  /// never a sheet whose recording is missing. Each file is downloaded to
  /// a `.part` name and renamed when whole, so a file that exists is a file
  /// that finished. [onProgress] is told what is being fetched, in words.
  Future<void> keep(
    SongProject project,
    SongAnalysisBundle sheet, {
    void Function(String stage)? onProgress,
  }) async {
    if (!supported) throw UnsupportedError('A browser has nowhere to keep a song.');
    final directory = await _songDirectory(project.id);
    if (directory == null) throw StateError('Sign in to keep a song on this phone.');
    if (!await directory.exists()) await directory.create(recursive: true);

    final reference = sheet.reference;
    if (reference != null) {
      await _fetchIfMissing(directory, reference.storagePath,
          what: 'the recording', onProgress: onProgress);
    }
    for (final stem in sheet.stems) {
      await _fetchIfMissing(directory, stem.storagePath,
          what: 'the ${stem.kind.label.toLowerCase()}', onProgress: onProgress);
    }
    await _dropAudioNotNamedBy(directory, sheet);

    await File('${directory.path}/$_songFile')
        .writeAsString(jsonEncode(_projectToJson(project)), flush: true);
    await File('${directory.path}/$_sheetFile')
        .writeAsString(jsonEncode(_bundleToJson(sheet)), flush: true);
  }

  /// Brings a kept song up to date with what the server just said, and
  /// does nothing for a song that is not kept.
  ///
  /// A kept copy that quietly went stale would be a trap: chords corrected
  /// on the sheet yesterday and the old ones on stage tonight. So whenever
  /// Perform opens a kept song with the network answering, the copy follows.
  /// Quiet on failure — the song on screen is the fresh one either way.
  Future<void> refresh(SongProject project, SongAnalysisBundle sheet) async {
    try {
      if (await load(project.id) == null) return;
      await keep(project, sheet);
    } catch (_) {
      // Next time.
    }
  }

  /// Takes a song off this phone.
  ///
  /// Tried a few times, because a file Perform is reading at that instant
  /// (or that Windows is still closing) refuses to be deleted for a moment,
  /// and a copy half taken off is worse than one still here: its words are
  /// listed and its sheet is gone.
  Future<void> remove(String projectId) async {
    if (!supported) return;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final directory = await _songDirectory(projectId);
        if (directory != null && await directory.exists()) {
          await directory.delete(recursive: true);
        }
        return;
      } catch (_) {
        if (attempt == 3) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// Takes every song this account kept off this phone. For an account
  /// being deleted; never for a sign-out, which keeps them for next time.
  Future<void> removeAll() async {
    if (!supported) return;
    try {
      final root = await _keptRoot();
      if (root != null && await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // An account that is gone must not be held up by a folder that will
      // not delete. Nobody else on this phone is ever shown what is in it.
    }
  }

  Future<void> _fetchIfMissing(
    Directory directory,
    String storagePath, {
    required String what,
    void Function(String stage)? onProgress,
  }) async {
    final file = File('${directory.path}/${_fileNameFor(storagePath)}');
    if (await file.exists() && await file.length() > 0) return;
    onProgress?.call('Fetching $what…');
    final bytes = await _download(storagePath);
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
  }

  /// What the mixer writes beside any compressed file it has decoded (see
  /// Multitrack.samplesFor). Beside a kept recording it is worth keeping:
  /// "my part forward" in the van would otherwise decode the whole song
  /// again every time. It belongs to its source, and goes when that goes.
  static const String _decodedSuffix = '.pcm.wav';

  /// Audio the sheet no longer names — a recording replaced since the song
  /// was kept — goes, and its decoded copy with it, so a kept song is never
  /// bigger than the song.
  Future<void> _dropAudioNotNamedBy(Directory directory, SongAnalysisBundle sheet) async {
    final wanted = _audioNamedBy(sheet).map(_fileNameFor).toSet();
    await for (final entry in directory.list()) {
      if (entry is! File) continue;
      final name = entry.path.split(Platform.pathSeparator).last.split('/').last;
      if (name == _songFile || name == _sheetFile || wanted.contains(name)) continue;
      if (name.endsWith(_decodedSuffix) &&
          wanted.contains(name.substring(0, name.length - _decodedSuffix.length))) {
        continue;
      }
      try {
        await entry.delete();
      } catch (_) {
        // Left for next time.
      }
    }
  }

  static Iterable<String> _audioNamedBy(SongAnalysisBundle sheet) sync* {
    final reference = sheet.reference;
    if (reference != null) yield reference.storagePath;
    for (final stem in sheet.stems) {
      yield stem.storagePath;
    }
  }

  // The kept shapes. Written and read only here, so they cannot drift from
  // each other, and named the way the database names the same things so a
  // kept sheet reads like a row to anybody debugging one.

  static Map<String, dynamic> _projectToJson(SongProject project) => <String, dynamic>{
        'id': project.id,
        'room_id': project.roomId,
        'account_id': project.accountId,
        'title': project.title,
        'description': project.description,
        'status': project.status.name,
        'created_at': project.createdAt.toIso8601String(),
        'updated_at': project.updatedAt.toIso8601String(),
        'sort_order': project.sortOrder,
        'has_audio_reference': project.hasAudioReference,
        'analysis_state': project.analysisState?.name,
        'created_by': project.createdBy,
        'song_origin': project.songOrigin?.wireName,
        'key_override': project.keyOverride,
        // A line's voice note is somebody talking, which Perform never
        // plays, so it is the one thing on a line that is not kept.
        'contributions': <Map<String, dynamic>>[
          for (final line in project.contributions)
            <String, dynamic>{
              'id': line.id,
              'project_id': line.projectId,
              'author_id': line.authorId,
              'author_name': line.authorName,
              'body': line.body,
              'color_value': line.colorValue,
              'created_at': line.createdAt.toIso8601String(),
              'position': line.position,
              'kind': line.kind.name,
              'revision': line.revision,
            },
        ],
      };

  static SongProject _projectFromJson(Map<String, dynamic> json) {
    final analysisState = json['analysis_state'] as String?;
    return SongProject(
      id: json['id'] as String,
      roomId: json['room_id'] as String? ?? '',
      accountId: json['account_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      status: SongStatus.values.byName(json['status'] as String? ?? SongStatus.active.name),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
      sortOrder: (json['sort_order'] as num?)?.toDouble() ?? 0,
      hasAudioReference: json['has_audio_reference'] as bool? ?? false,
      analysisState: analysisState == null ? null : SongAnalysisState.values.byName(analysisState),
      createdBy: json['created_by'] as String?,
      songOrigin: SongOrigin.fromWireName(json['song_origin'] as String?),
      keyOverride: json['key_override'] as String?,
      contributions: <Contribution>[
        for (final value in json['contributions'] as List<dynamic>? ?? const <dynamic>[])
          _lineFromJson(Map<String, dynamic>.from(value as Map)),
      ],
    );
  }

  static Contribution _lineFromJson(Map<String, dynamic> json) => Contribution(
        id: json['id'] as String,
        projectId: json['project_id'] as String? ?? '',
        authorId: json['author_id'] as String? ?? '',
        authorName: json['author_name'] as String? ?? '',
        body: json['body'] as String? ?? '',
        colorValue: (json['color_value'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
        position: (json['position'] as num?)?.toDouble() ?? 0,
        kind: ContributionKind.values.byName(json['kind'] as String? ?? ContributionKind.lyric.name),
        revision: (json['revision'] as num?)?.toInt() ?? 1,
      );

  static Map<String, dynamic> _bundleToJson(SongAnalysisBundle sheet) {
    final reference = sheet.reference;
    return <String, dynamic>{
      'reference': reference == null
          ? null
          : <String, dynamic>{
              'file_id': reference.fileId,
              'storage_path': reference.storagePath,
              'display_name': reference.displayName,
              'analysis_state': reference.state.name,
              'duration_ms': reference.durationMs,
              'musical_key': reference.musicalKey,
              'lyric_confidence': reference.lyricConfidence,
              'chord_confidence': reference.chordConfidence,
              'chord_coverage': reference.chordCoverage,
              'beats_ms': reference.beatsMs,
              'downbeats_ms': reference.downbeatsMs,
              'beats_per_bar': reference.beatsPerBar,
              'transcript_text': reference.transcriptText,
              'transcript_words': <Map<String, dynamic>>[
                for (final word in reference.transcriptWords) word.toJson(),
              ],
              'analysis_warning': reference.analysisWarning,
              'last_error': reference.lastError,
              'bpm': reference.bpm,
              'structure_sections': <Map<String, dynamic>>[
                for (final section in reference.structureSections) section.toJson(),
              ],
              'instruments': reference.instruments?.toJson(),
              'melody': reference.melody?.toJson(),
            },
      'lyric_cues': <Map<String, dynamic>>[
        for (final cue in sheet.lyricCues)
          <String, dynamic>{
            'contribution_id': cue.contributionId,
            'start_ms': cue.startMs,
            'end_ms': cue.endMs,
            'confidence': cue.confidence,
            'source': cue.source,
          },
      ],
      'chord_cues': <Map<String, dynamic>>[
        for (final cue in sheet.chordCues)
          <String, dynamic>{
            'id': cue.id,
            'start_ms': cue.startMs,
            'end_ms': cue.endMs,
            'chord': cue.chord,
            'confidence': cue.confidence,
            'source': cue.source,
          },
      ],
      'stems': <Map<String, dynamic>>[
        for (final stem in sheet.stems)
          <String, dynamic>{
            'stem': stem.kind.name,
            'storage_path': stem.storagePath,
            'byte_size': stem.byteSize,
          },
      ],
    };
  }

  static SongAnalysisBundle _bundleFromJson(String projectId, Map<String, dynamic> json) {
    final referenceJson = json['reference'];
    ReferenceTrack? reference;
    if (referenceJson is Map) {
      final row = Map<String, dynamic>.from(referenceJson);
      reference = ReferenceTrack(
        projectId: projectId,
        fileId: row['file_id'] as String,
        storagePath: row['storage_path'] as String,
        displayName: row['display_name'] as String? ?? 'Reference track',
        state: SongAnalysisState.values
            .byName(row['analysis_state'] as String? ?? SongAnalysisState.uploaded.name),
        durationMs: (row['duration_ms'] as num?)?.toInt(),
        musicalKey: row['musical_key'] as String?,
        lyricConfidence: (row['lyric_confidence'] as num?)?.toDouble(),
        chordConfidence: (row['chord_confidence'] as num?)?.toDouble(),
        chordCoverage: (row['chord_coverage'] as num?)?.toDouble(),
        beatsMs: _msList(row['beats_ms']),
        downbeatsMs: _msList(row['downbeats_ms']),
        beatsPerBar: (row['beats_per_bar'] as num?)?.toInt(),
        transcriptText: row['transcript_text'] as String?,
        transcriptWords: <TranscriptWord>[
          for (final value in row['transcript_words'] as List<dynamic>? ?? const <dynamic>[])
            TranscriptWord.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
        analysisWarning: row['analysis_warning'] as String?,
        lastError: row['last_error'] as String?,
        bpm: (row['bpm'] as num?)?.toDouble(),
        structureSections: <StructureSection>[
          for (final value in row['structure_sections'] as List<dynamic>? ?? const <dynamic>[])
            StructureSection.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
        instruments: row['instruments'] is Map
            ? InstrumentSummary.fromJson(Map<String, dynamic>.from(row['instruments'] as Map))
            : null,
        melody: row['melody'] is Map
            ? Melody.fromJson(Map<String, dynamic>.from(row['melody'] as Map))
            : null,
      );
    }
    return SongAnalysisBundle(
      reference: reference,
      lyricCues: <LyricSyncCue>[
        for (final value in json['lyric_cues'] as List<dynamic>? ?? const <dynamic>[])
          LyricSyncCue(
            contributionId: (value as Map)['contribution_id'] as String,
            startMs: (value['start_ms'] as num).toInt(),
            endMs: (value['end_ms'] as num).toInt(),
            confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
            source: value['source'] as String? ?? 'automatic',
          ),
      ],
      chordCues: <ChordCue>[
        for (final value in json['chord_cues'] as List<dynamic>? ?? const <dynamic>[])
          ChordCue(
            id: ((value as Map)['id'] as num?)?.toInt(),
            startMs: (value['start_ms'] as num).toInt(),
            endMs: (value['end_ms'] as num).toInt(),
            chord: value['chord'] as String,
            confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
            source: value['source'] as String? ?? 'automatic',
          ),
      ],
      stems: <SongStem>[
        for (final value in json['stems'] as List<dynamic>? ?? const <dynamic>[])
          SongStem(
            projectId: projectId,
            kind: StemKind.values.byName((value as Map)['stem'] as String),
            storagePath: value['storage_path'] as String,
            byteSize: (value['byte_size'] as num?)?.toInt(),
          ),
      ],
    );
  }

  static List<int> _msList(dynamic value) {
    if (value is! List) return const <int>[];
    return value.whereType<num>().map((n) => n.round()).toList(growable: false);
  }
}
