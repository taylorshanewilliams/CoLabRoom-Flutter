import 'multitrack.dart';

/// What a layer is, in the words a band actually uses.
///
/// A short closed list rather than free text, because it is picked in the
/// second after a take ends — when nobody wants to type — and because names
/// that come from a list can be composed into sentences later. Anything that
/// does not fit is [other], which keeps its own free-text label.
enum TakePart {
  rhythm,
  lead,
  vocal,
  harmony,
  bass,
  drums,
  keys,
  percussion,
  other;

  String get label {
    switch (this) {
      case TakePart.rhythm:
        return 'rhythm';
      case TakePart.lead:
        return 'lead';
      case TakePart.vocal:
        return 'vocal';
      case TakePart.harmony:
        return 'harmony';
      case TakePart.bass:
        return 'bass';
      case TakePart.drums:
        return 'drums';
      case TakePart.keys:
        return 'keys';
      case TakePart.percussion:
        return 'percussion';
      case TakePart.other:
        return 'part';
    }
  }

  static TakePart parse(String? value) {
    for (final part in TakePart.values) {
      if (part.name == value) return part;
    }
    return TakePart.other;
  }
}

/// A named combination of layers.
///
/// The thing a band argues about is not a take, it is a *set* of takes: the
/// one with Dylan's lead against the one without it. Both are worth keeping
/// and neither is a different recording — a version is metadata over audio
/// that already exists, so saving one costs nothing and switching back is
/// instant.
class TakeVersion {
  const TakeVersion({
    required this.id,
    required this.enabledTakeIds,
    required this.createdAt,
    this.name,
    this.createdBy,
  });

  final String id;

  /// Null means "no one has named this", and the name shown is composed from
  /// the layers instead. Kept nullable rather than defaulted so a chosen name
  /// is distinguishable from a generated one — a generated name should follow
  /// the layers when they change, and a chosen one must not.
  final String? name;

  final Set<String> enabledTakeIds;
  final DateTime createdAt;
  final String? createdBy;

  TakeVersion copyWith({String? name, Set<String>? enabledTakeIds}) {
    return TakeVersion(
      id: id,
      name: name ?? this.name,
      enabledTakeIds: enabledTakeIds ?? this.enabledTakeIds,
      createdAt: createdAt,
      createdBy: createdBy,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name,
        'takes': enabledTakeIds.toList(growable: false),
        'created_at': createdAt.toIso8601String(),
        if (createdBy != null) 'created_by': createdBy,
      };

  factory TakeVersion.fromJson(Map<String, dynamic> json) {
    return TakeVersion(
      id: json['id'] as String? ?? '',
      name: json['name'] as String?,
      enabledTakeIds: ((json['takes'] as List<dynamic>?) ?? const <dynamic>[])
          .whereType<String>()
          .toSet(),
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
      createdBy: json['created_by'] as String?,
    );
  }
}

/// Turns takes and versions into words.
///
/// The app knows who recorded a layer, when, what they called the part, and
/// which layers a version has switched on. That is enough to name almost
/// everything without anyone typing — and a name that appears on its own is
/// worth more than a field somebody meant to fill in later, because the
/// moment for typing is exactly the moment nobody wants to.
///
/// Everything here is a suggestion. A name a person chose always wins.
class TakeNaming {
  const TakeNaming._();

  /// One layer, described: "Dylan's lead", "lead", or whatever it was called.
  static String describe(Take take) {
    final label = take.label.trim();
    final performer = take.performer?.trim();
    final part = take.part;

    // A name somebody typed beats anything composed.
    if (take.namedByHand && label.isNotEmpty) return label;

    if (part == TakePart.other) {
      return label.isNotEmpty ? label : 'part';
    }
    if (performer == null || performer.isEmpty) return part.label;
    // Possessive without assuming anything about the name's ending beyond
    // English's own rule for one already ending in s.
    final possessive = performer.endsWith('s') ? "$performer'" : "$performer's";
    return '$possessive ${part.label}';
  }

  /// A whole version, described by what is switched on inside it.
  ///
  /// Caps at three layers and counts the rest. A list of six is not a name,
  /// it is an inventory, and nobody reads it in a picker.
  static String autoName(List<Take> takes, Set<String> enabled) {
    final chosen = takes.where((take) => enabled.contains(take.id)).toList();
    if (chosen.isEmpty) return 'Empty';
    final described = chosen.map(describe).toList(growable: false);
    if (described.length <= 3) return described.join(' + ');
    final rest = described.length - 2;
    return '${described.take(2).join(' + ')} + $rest more';
  }

  /// How this version differs from [baseline], as a phrase.
  ///
  /// This is the one that produces the names a band says out loud. Two
  /// versions that differ by a single layer do not need describing from
  /// scratch — "with Dylan's lead" says everything, and it says it in the
  /// words somebody would have used anyway.
  ///
  /// Null when the difference is not a single layer, because "with Dylan's
  /// lead and Kate's harmony but without the scratch vocal" is not a name and
  /// pretending otherwise produces the sort of label people stop reading.
  static String? differenceFrom({
    required List<Take> takes,
    required Set<String> baseline,
    required Set<String> version,
  }) {
    final added = version.difference(baseline);
    final removed = baseline.difference(version);
    if (added.length == 1 && removed.isEmpty) {
      final take = _find(takes, added.first);
      return take == null ? null : 'with ${describe(take)}';
    }
    if (removed.length == 1 && added.isEmpty) {
      final take = _find(takes, removed.first);
      return take == null ? null : 'without ${describe(take)}';
    }
    return null;
  }

  /// What to show for [version], preferring in order: the name somebody gave
  /// it, how it differs from [baseline] in one layer, then its contents.
  static String display(
    TakeVersion version,
    List<Take> takes, {
    Set<String>? baseline,
    String? songTitle,
  }) {
    final chosen = version.name?.trim();
    if (chosen != null && chosen.isNotEmpty) return chosen;

    if (baseline != null) {
      final difference = differenceFrom(
        takes: takes,
        baseline: baseline,
        version: version.enabledTakeIds,
      );
      if (difference != null) {
        // "Mountains with Dylan's lead" when the song has a title, and just
        // "with Dylan's lead" when it does not — a version of an untitled
        // sketch should not be called "Untitled with Dylan's lead".
        final title = songTitle?.trim();
        return title == null || title.isEmpty ? difference : '$title $difference';
      }
    }
    return autoName(takes, version.enabledTakeIds);
  }

  /// A label for a freshly recorded take, before anyone has said anything
  /// about it. Numbered per part, so a second attempt at the same thing reads
  /// as a second attempt rather than as a different instrument.
  static String nextLabel(List<Take> existing, TakePart part, String? performer) {
    final sameParts = existing.where((take) => take.part == part).length;
    final base = TakeNaming.describe(Take(
      id: '',
      path: '',
      label: '',
      recordedAt: DateTime.now(),
      part: part,
      performer: performer,
    ));
    final capitalised = base.isEmpty
        ? 'Take'
        : base[0].toUpperCase() + base.substring(1);
    return sameParts == 0 ? capitalised : '$capitalised ${sameParts + 1}';
  }

  static Take? _find(List<Take> takes, String id) {
    for (final take in takes) {
      if (take.id == id) return take;
    }
    return null;
  }
}
