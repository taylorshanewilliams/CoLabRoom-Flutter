import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'multitrack.dart';
import 'take_naming.dart';

/// Layers shared with the band, and the local cache that keeps them playable.
///
/// The shape of this follows one economic fact: audio is expensive to move
/// and metadata is not. A layer is uploaded once, ever, and downloaded once
/// per person. Everything after that — muting, volumes, saved versions, "here
/// is the mix I meant" — is rows, and rows are free.
///
/// So the cache is not an optimisation, it is the design. A layer that has
/// been fetched never gets fetched again, because the audio it holds cannot
/// change: a take is immutable once recorded. Re-recording produces a new
/// layer with a new id rather than replacing one, which is also what makes
/// "who played this" answerable months later.
class SongLayerService {
  SongLayerService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  static const String _bucket = 'room-files';

  /// Every layer on a song, oldest first.
  ///
  /// Ordered by when it was recorded, which is the order the parts were
  /// played and therefore the order they make sense in. Two people recording
  /// offline at the same time is not a conflict here — layers are additive,
  /// so both land and both keep their place in the sequence. That is the one
  /// genuinely easy thing about this compared with the lyric editor, where
  /// two people editing one document had to be reconciled.
  Future<List<SharedLayer>> listLayers(String projectId) async {
    final rows = await _client
        .from('song_layers')
        .select()
        .eq('project_id', projectId)
        .order('created_at');
    return (rows as List<dynamic>)
        .map((row) => SharedLayer.fromRow(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  Future<List<SharedVersion>> listVersions(String projectId) async {
    final rows = await _client
        .from('song_layer_versions')
        .select()
        .eq('project_id', projectId)
        .order('created_at', ascending: false);
    return (rows as List<dynamic>)
        .map((row) => SharedVersion.fromRow(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  /// Uploads one recorded take and records it against the song.
  ///
  /// Bytes first, row second, deliberately. A row pointing at audio that
  /// never arrived is a layer everyone can see and nobody can play; an object
  /// with no row is invisible and costs only storage, which the retention
  /// sweep reclaims. Of the two ways this can half-fail, the second is much
  /// the kinder.
  Future<SharedLayer> upload({
    required String projectId,
    required Take take,
  }) async {
    final file = File(take.path);
    final bytes = await file.readAsBytes();
    final extension = take.path.split('.').last;
    final objectId = DateTime.now().microsecondsSinceEpoch.toString();
    final storagePath = '$projectId/layers/$objectId.$extension';

    await _client.storage.from(_bucket).uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(contentType: _mimeFor(extension)),
        );

    final row = await _client
        .from('song_layers')
        .insert(<String, dynamic>{
          'project_id': projectId,
          'storage_path': storagePath,
          'label': take.label,
          'part': take.part.name,
          if (take.performer != null) 'performer': take.performer,
          'duration_ms': take.durationMs,
          'offset_ms': take.offsetMs,
          'gain': take.gain,
          'byte_size': bytes.length,
        })
        .select()
        .single();

    return SharedLayer.fromRow(Map<String, dynamic>.from(row));
  }

  /// The local file for a layer, fetching it only if it is not already here.
  ///
  /// Named by layer id rather than by anything about its contents, because
  /// the id is what makes the cache safe: a layer's audio is immutable, so a
  /// file that exists is correct by definition and never needs revalidating.
  Future<String> ensureLocal(SharedLayer layer) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/layers/${layer.projectId}');
    if (!await directory.exists()) await directory.create(recursive: true);

    final extension = layer.storagePath.split('.').last;
    final path = '${directory.path}/${layer.id}.$extension';
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;

    final bytes = await _client.storage.from(_bucket).download(layer.storagePath);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Records that somebody actually listened, which is what retention reads.
  ///
  /// Best-effort and deliberately unawaited by callers: failing to mark a
  /// layer as used must never stop it playing. The cost of missing one is
  /// that a layer looks staler than it is, and the sweep is generous enough
  /// for that to be survivable.
  Future<void> markOpened(Iterable<String> layerIds) async {
    final ids = layerIds.toList(growable: false);
    if (ids.isEmpty) return;
    try {
      await _client
          .from('song_layers')
          .update(<String, dynamic>{
            'last_opened_at': DateTime.now().toUtc().toIso8601String(),
          })
          .inFilter('id', ids);
    } catch (_) {
      // See above.
    }
  }

  /// Saves which layers are on, and at what, as a named version.
  Future<SharedVersion> saveVersion({
    required String projectId,
    required Iterable<String> layerIds,
    String? name,
  }) async {
    final row = await _client
        .from('song_layer_versions')
        .insert(<String, dynamic>{
          'project_id': projectId,
          'layer_ids': layerIds.toList(growable: false),
          if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        })
        .select()
        .single();
    return SharedVersion.fromRow(Map<String, dynamic>.from(row));
  }

  /// Changes how a layer sits — its volume, or its timing.
  ///
  /// RLS admits this only from the person who recorded it. A bandmate who
  /// disagrees mutes it locally or saves their own version; what everyone
  /// else hears stays what the player chose.
  Future<void> updateLayer(SharedLayer layer, Map<String, dynamic> patch) async {
    await _client.from('song_layers').update(patch).eq('id', layer.id);
  }

  /// Removes a layer and its audio.
  ///
  /// RLS decides whether this is allowed — the recorder, or a room owner —
  /// so a bandmate who should not be doing this gets a refusal from the
  /// database rather than a hidden button. The row goes first: an orphaned
  /// object is reclaimable, an orphaned row is a layer nobody can play.
  Future<void> deleteLayer(SharedLayer layer) async {
    await _client.from('song_layers').delete().eq('id', layer.id);
    try {
      await _client.storage.from(_bucket).remove(<String>[layer.storagePath]);
    } catch (_) {
      // The row is what the app reads. An object that outlives it is the
      // retention sweep's problem, not this call's.
    }
  }

  static String _mimeFor(String extension) => switch (extension.toLowerCase()) {
        'm4a' || 'aac' => 'audio/mp4',
        'wav' => 'audio/wav',
        'ogg' || 'opus' => 'audio/ogg',
        _ => 'application/octet-stream',
      };
}

/// One layer as the band sees it.
class SharedLayer {
  const SharedLayer({
    required this.id,
    required this.projectId,
    required this.recordedBy,
    required this.storagePath,
    required this.label,
    required this.part,
    required this.createdAt,
    this.performer,
    this.durationMs = 0,
    this.offsetMs = 0,
    this.gain = 1.0,
    this.byteSize,
  });

  final String id;
  final String projectId;
  final String recordedBy;
  final String storagePath;
  final String label;
  final TakePart part;
  final String? performer;
  final int durationMs;
  final int offsetMs;
  final double gain;
  final int? byteSize;
  final DateTime createdAt;

  /// The same layer as the mixer understands it, pointed at its local copy.
  ///
  /// [enabled] comes from whichever version is being listened to rather than
  /// from the row, because muting is a local view of a shared set — that is
  /// the whole reason everyone can mute anything without taking a thing away
  /// from the person who played it.
  Take toTake(String localPath, {required bool enabled}) {
    return Take(
      id: id,
      path: localPath,
      label: label,
      recordedAt: createdAt,
      durationMs: durationMs,
      offsetMs: offsetMs,
      gain: gain,
      enabled: enabled,
      part: part,
      performer: performer,
      namedByHand: label.trim().isNotEmpty,
    );
  }

  factory SharedLayer.fromRow(Map<String, dynamic> row) {
    return SharedLayer(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      recordedBy: row['recorded_by'] as String? ?? '',
      storagePath: row['storage_path'] as String? ?? '',
      label: row['label'] as String? ?? '',
      part: TakePart.parse(row['part'] as String?),
      performer: row['performer'] as String?,
      durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
      offsetMs: (row['offset_ms'] as num?)?.toInt() ?? 0,
      gain: (row['gain'] as num?)?.toDouble() ?? 1.0,
      byteSize: (row['byte_size'] as num?)?.toInt(),
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class SharedVersion {
  const SharedVersion({
    required this.id,
    required this.projectId,
    required this.createdBy,
    required this.layerIds,
    required this.createdAt,
    this.name,
  });

  final String id;
  final String projectId;
  final String createdBy;
  final String? name;
  final List<String> layerIds;
  final DateTime createdAt;

  factory SharedVersion.fromRow(Map<String, dynamic> row) {
    return SharedVersion(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      createdBy: row['created_by'] as String? ?? '',
      name: row['name'] as String?,
      layerIds: ((row['layer_ids'] as List<dynamic>?) ?? const <dynamic>[])
          .whereType<String>()
          .toList(growable: false),
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
