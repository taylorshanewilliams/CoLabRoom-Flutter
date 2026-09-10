/// What would work here — for this chord, in this song, on your instrument.
///
/// Taylor: "what if someone is stuck, and wants to know quickly, what cords
/// would go with this progression, what key or box would a lead work in. what
/// notes would harmony be... a help feature for any instrument or user."
///
/// The app already had most of the arithmetic. `music_reference.dart` derives
/// the scale, the degrees, the diatonic chords and the pentatonic from a key,
/// and `chordReference` derives tones, shapes and root patterns from a chord.
/// What neither of them had was **the song**: tapping a chord told you what a
/// C is, not that it is the IV here, not what this song has not used yet, and
/// not what to sing over it.
///
/// That is the whole of this file. It adds no new theory; it asks the theory
/// that already exists the questions somebody stuck actually has.
///
/// Nothing here reads the network or the database. It is arithmetic on note
/// names, which is why it can be tested on a machine with no device — and why
/// it costs nothing to answer, which matters: this is the purest example the
/// product has of something that should be free forever.
///
/// **Deterministic on purpose.** Given a key and a chord, "what else fits" has
/// exactly one right answer, and a language model would be a worse version of
/// arithmetic — right most of the time and confidently wrong occasionally.
/// Being wrong about a chord in front of a guitarist ends the feature in one
/// screen; they catch it instantly.
library;

import '../domain/musical_roles.dart';
import 'music_reference.dart';

/// One answer, in a sentence somebody can act on.
class Suggestion {
  const Suggestion({
    required this.heading,
    required this.detail,
    this.notes = const <String>[],
    this.chords = const <String>[],
  });

  final String heading;
  final String detail;

  /// Note names to show as chips, when the answer is notes.
  final List<String> notes;

  /// Chord names to show as chips, when the answer is chords.
  final List<String> chords;
}

/// Everything worth saying about one chord in one song.
class WhatWorksHere {
  const WhatWorksHere({
    required this.chord,
    required this.degree,
    required this.suggestions,
  });

  /// The chord as asked about.
  final String chord;

  /// Where it sits in the key — "the IV" — or null when the song has no key
  /// or this chord is from outside it.
  ///
  /// Null is a real answer and is never guessed at. A chord borrowed from
  /// somewhere else is a thing musicians do on purpose, and telling somebody
  /// it is the iii when it is not is worse than saying nothing.
  final String? degree;

  final List<Suggestion> suggestions;
}

/// Roman numerals, given how far the root sits above the tonic.
const List<String> _majorDegreeNames = <String>[
  'I', 'ii', 'iii', 'IV', 'V', 'vi', 'vii°',
];
const List<String> _minorDegreeNames = <String>[
  'i', 'ii°', 'III', 'iv', 'v', 'VI', 'VII',
];

/// Work out what to say about [chordLabel] in a song in [keyLabel].
///
/// [used] is every chord the song already contains, so the answer can be
/// about this song rather than about music in general — "you have not used
/// the vi yet" is worth more than a list of seven chords somebody could have
/// looked up.
///
/// [roles] is what the person plays, and only changes the **order**. A singer
/// is shown the harmony note first and a bass player the root movement, but
/// nobody is prevented from seeing the rest: people play more than one thing,
/// and a guitarist asking about harmony is a guitarist arranging a backing
/// vocal.
WhatWorksHere? whatWorksHere({
  required String chordLabel,
  String? keyLabel,
  List<String> used = const <String>[],
  Set<String> roles = const <String>{},
}) {
  final chord = chordReference(chordLabel);
  if (chord == null) return null;
  final key = keyLabel == null ? null : keyReference(keyLabel);

  final suggestions = <Suggestion>[];
  String? degree;

  if (key != null) {
    final at = key.diatonic.indexWhere(
      (name) => _sameRoot(name, chord.display),
    );
    if (at >= 0) {
      degree = (key.minor ? _minorDegreeNames : _majorDegreeNames)[at];
    }

    // What this song has not reached for yet.
    //
    // The single most useful thing this file says. Seven diatonic chords is a
    // list anybody can look up; "your song uses four of them and here are the
    // three it has not touched" is about their song.
    final usedRoots = used.map(_rootOf).whereType<String>().toSet();
    final untouched = <String>[
      for (final name in key.diatonic)
        if (!usedRoots.contains(_rootOf(name))) name,
    ];
    if (untouched.isNotEmpty) {
      suggestions.add(Suggestion(
        heading: 'Not in the song yet',
        detail: 'These belong to ${key.display} and you have not used them. '
            'They will fit without anything else changing.',
        chords: untouched,
      ));
    }

    // Where this chord wants to go, when it is one of the two that want
    // anything. Everything else is a matter of taste and is left alone.
    if (degree == 'V') {
      suggestions.add(Suggestion(
        heading: 'It wants to land',
        detail: 'The V pulls home. ${key.diatonic.first} after this is the '
            'ending everybody hears coming, and ${key.relative} is the one '
            'they do not.',
        chords: <String>[key.diatonic.first, key.relative],
      ));
    } else if (degree == 'IV') {
      suggestions.add(Suggestion(
        heading: 'The usual next step',
        detail: 'From the IV, the V lifts and the I settles.',
        chords: <String>[key.diatonic[4], key.diatonic.first],
      ));
    }
  }

  // Lead. The five notes that sit over this chord, and the key's own
  // pentatonic for playing across the whole song rather than chord by chord.
  suggestions.add(Suggestion(
    heading: 'To play over it',
    detail: key == null
        ? 'These five sit over this chord wherever it appears.'
        : 'These five sit over this chord. Across the whole song, '
            '${key.pentatonic.first} ${key.minor ? 'minor' : 'major'} '
            'pentatonic works everywhere.',
    notes: chord.pentatonic,
  ));

  // Harmony, from the chord rather than from the melody.
  //
  // Honest about where it comes from: the app has lyrics with timing and
  // chords with timing, and no pitch line at all. A third above inside the
  // chord is a real backing vocal and it is not the same thing as harmonising
  // the tune somebody actually sang.
  final third = chord.tones.length > 1 ? chord.tones[1].note : null;
  final fifth = chord.tones.length > 2 ? chord.tones[2].note : null;
  if (third != null && fifth != null) {
    suggestions.add(Suggestion(
      heading: 'To sing against it',
      detail: 'Notes from the chord itself, so they will not clash. Above the '
          'root, ${third} is the close one and ${fifth} is the open one. '
          'This is from the chords, not from the tune — the app does not '
          'know what you sang.',
      notes: <String>[for (final tone in chord.tones) tone.note],
    ));
  }

  if (chord.bassMoves.isNotEmpty) {
    suggestions.add(Suggestion(
      heading: 'Under it',
      detail: 'Where the root can move without leaving the chord.',
      notes: <String>[for (final move in chord.bassMoves) move.$2],
    ));
  }

  return WhatWorksHere(
    chord: chord.display,
    degree: degree,
    suggestions: _ordered(suggestions, roles),
  );
}

/// Puts the thing you play first.
///
/// Order only. Hiding the rest would be the app deciding a bass player has no
/// business knowing what the harmony is, which is both wrong and rude.
List<Suggestion> _ordered(List<Suggestion> all, Set<String> roles) {
  if (roles.isEmpty) return all;
  String? wanted;
  if (roles.any(_isVoice)) {
    wanted = 'To sing against it';
  } else if (roles.contains(MusicalRole.bass.name)) {
    wanted = 'Under it';
  } else if (roles.contains(MusicalRole.lead.name)) {
    wanted = 'To play over it';
  }
  if (wanted == null) return all;

  final first = all.where((s) => s.heading == wanted).toList(growable: false);
  if (first.isEmpty) return all;
  return <Suggestion>[
    ...first,
    ...all.where((s) => s.heading != wanted),
  ];
}

bool _isVoice(String role) =>
    role == MusicalRole.vocal.name ||
    role == MusicalRole.harmony.name ||
    role == MusicalRole.topline.name;

/// The root of a chord name, ignoring quality and any slash bass.
String? _rootOf(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return null;
  final head = trimmed.split('/').first;
  if (head.length >= 2 && (head[1] == '#' || head[1] == 'b')) {
    return head.substring(0, 2);
  }
  return head.substring(0, 1);
}

bool _sameRoot(String a, String b) {
  final ra = _rootOf(a);
  final rb = _rootOf(b);
  if (ra == null || rb == null) return false;
  // Compared as pitches rather than as text, so Bb and A# are the same chord
  // — which they are, and a chart that used one spelling and a key that used
  // the other would otherwise never match.
  return samePitch(ra, rb);
}
