import 'dart:typed_data';

/// A standard MIDI file holding nothing but the song's tempo and its section
/// names.
///
/// The bridge to a DAW, not a DAW (Every Musician, Same Song, 17 September
/// 2026, rule 9). Nobody wants CoLabRoom to arrange their record; they want
/// the four takes they played to land in Ableton or Logic already at the
/// right tempo, with "Chorus" written above the bar it starts on. That is a
/// few hundred bytes of meta events and it saves the twenty minutes of
/// tapping tempo that otherwise stands between a phone recording and a
/// session.
///
/// Pure Dart on purpose: no `dart:io`, no plugins, no audio. It is arithmetic
/// over integers, so it runs the same in a browser as on a phone and can be
/// checked byte by byte in a test rather than by ear.

/// One stretch of the song at one tempo.
///
/// [startMs] and [startTick] are the same instant said two ways — where the
/// stretch begins in the recording, and where it begins on the DAW's grid.
/// Holding both is what lets a section name recorded at 1.847 seconds be
/// placed on the bar line it actually fell on.
class TempoSegment {
  const TempoSegment({
    required this.startMs,
    required this.startTick,
    required this.microsecondsPerBeat,
  });

  final int startMs;
  final int startTick;

  /// Microseconds per quarter note, which is how a MIDI file spells tempo.
  final int microsecondsPerBeat;

  double get bpm => 60000000 / microsecondsPerBeat;
}

/// One name written above a bar: "Verse", "Chorus", "Kate's bit".
class MidiMarker {
  const MidiMarker({required this.atMs, required this.text});

  final int atMs;
  final String text;
}

/// How the recording's milliseconds line up with a DAW's bars and beats.
///
/// **The lead-in is the whole problem.** A song's first downbeat is almost
/// never at zero — an intro, a count-in, half a second of room — and
/// multitrack.dart already learned this the hard way with the click: a grid
/// that starts at zero is then wrong against the record for its whole length,
/// at every tempo, and getting the bpm right does not fix it. So the stretch
/// before the first downbeat becomes a pickup bar of its own, with its own
/// tempo chosen to make it exactly as long as it really was. The first
/// downbeat then lands on a bar line, and every bar line after it lands on a
/// downbeat.
class SongTempoMap {
  const SongTempoMap._({
    required this.ticksPerBeat,
    required this.beatsPerBar,
    required this.pickupBeats,
    required this.segments,
    required this.statedBpm,
  });

  /// 480 is the usual division: divisible by 2, 3, 4, 5 and 8, so triplets
  /// and sixteenths are whole numbers rather than rounding errors.
  static const int defaultTicksPerBeat = 480;

  /// Used when there is neither a bpm nor a beat grid to work from. Not shown
  /// to anyone — a file with no tempo at all is read as 120 by every DAW
  /// anyway, so writing it down changes nothing except that it is explicit.
  static const double _fallbackBpm = 120;

  final int ticksPerBeat;
  final int beatsPerBar;

  /// How many beats sit in front of the first downbeat. Zero when the song
  /// starts on one, or when nothing is known about where the bars are.
  final int pickupBeats;

  final List<TempoSegment> segments;

  /// The tempo a person would type in, for the times a DAW is quicker to set
  /// by hand than to import a file into. The song's own tempo, never the
  /// pickup's.
  final double statedBpm;

  int get firstDownbeatTick => pickupBeats * ticksPerBeat;

  /// Reads the song's tempo from what the analysis found.
  ///
  /// [bpm] is the analysis's single answer and is used whenever the bars are
  /// steady, because one tempo is what a person would type into a DAW. A
  /// tempo written per bar is only worth the clutter when the band actually
  /// moved, which is what [downbeatsMs] shows and a single number cannot.
  static SongTempoMap forSong({
    double? bpm,
    List<int> downbeatsMs = const <int>[],
    int? beatsPerBar,
    int ticksPerBeat = defaultTicksPerBeat,
  }) {
    final beats = (beatsPerBar == null || beatsPerBar < 1 || beatsPerBar > 16)
        ? 4
        : beatsPerBar;
    final ticks = ticksPerBeat < 24 ? defaultTicksPerBeat : ticksPerBeat;
    final downbeats = _cleanDownbeats(downbeatsMs);
    final stated = _microsFor(bpm);

    // One bar is not a bar length, and no bars is no grid. Either way the
    // best that can be said is the tempo, from the start.
    if (downbeats.length < 2) {
      final micros = stated ?? _microsFor(_fallbackBpm)!;
      return SongTempoMap._(
        ticksPerBeat: ticks,
        beatsPerBar: beats,
        pickupBeats: 0,
        statedBpm: 60000000 / micros,
        segments: <TempoSegment>[
          TempoSegment(startMs: 0, startTick: 0, microsecondsPerBeat: micros),
        ],
      );
    }

    final bars = <int>[
      for (var i = 0; i + 1 < downbeats.length; i += 1)
        downbeats[i + 1] - downbeats[i],
    ];
    final typical = _median(bars);
    // Two per cent of a bar is a few milliseconds at the top of a bar and
    // well inside what a downbeat detector can tell apart. Past it, the band
    // is moving and saying so is more useful than pretending otherwise.
    final varies = bars.any((bar) => (bar - typical).abs() > typical * 0.02);
    final measured = _clampMicros((typical * 1000 / beats).round());
    final bodyMicros = varies ? null : (stated ?? measured);

    final leadInMs = downbeats.first;
    final beatMs = typical / beats;
    final pickup = leadInMs <= 0 ? 0 : (leadInMs / beatMs).round();
    final segments = <TempoSegment>[];

    if (leadInMs > 0) {
      // The pickup's own tempo, set so the pickup lasts exactly as long as
      // the lead-in did. It differs a little from the song's tempo because
      // the beat count was rounded, which is honest: a count-in rarely sits
      // perfectly in time either.
      final micros = pickup > 0
          ? _clampMicros((leadInMs * 1000 / pickup).round())
          : (bodyMicros ?? _clampMicros((bars.first * 1000 / beats).round()));
      segments.add(TempoSegment(
        startMs: 0,
        startTick: 0,
        microsecondsPerBeat: micros,
      ));
    }

    final firstTick = pickup * ticks;
    if (bodyMicros != null) {
      segments.add(TempoSegment(
        startMs: downbeats.first,
        startTick: firstTick,
        microsecondsPerBeat: bodyMicros,
      ));
    } else {
      for (var i = 0; i < bars.length; i += 1) {
        segments.add(TempoSegment(
          startMs: downbeats[i],
          startTick: firstTick + i * beats * ticks,
          microsecondsPerBeat: _clampMicros((bars[i] * 1000 / beats).round()),
        ));
      }
      // Whatever runs past the last downbeat keeps the tempo of the bar
      // before it. There is no measurement for it, so inventing one would
      // only be a guess with a number on it.
    }

    return SongTempoMap._(
      ticksPerBeat: ticks,
      beatsPerBar: beats,
      pickupBeats: pickup,
      statedBpm: 60000000 / (bodyMicros ?? measured),
      segments: segments,
    );
  }

  /// Where [ms] falls on the grid.
  ///
  /// Clamped to the next segment's start, so rounding inside one stretch can
  /// never push a marker past the bar line the next stretch begins on. That
  /// also handles a lead-in too short to be worth a beat: it is a stretch
  /// with no ticks in it, and everything inside it lands on tick zero.
  int tickAt(int ms) {
    if (segments.isEmpty) return 0;
    var index = 0;
    for (var i = 0; i < segments.length; i += 1) {
      if (segments[i].startMs > ms) break;
      index = i;
    }
    final segment = segments[index];
    final elapsed = ms - segment.startMs;
    if (elapsed <= 0) return segment.startTick;
    var tick = segment.startTick +
        (elapsed * 1000 * ticksPerBeat / segment.microsecondsPerBeat).round();
    if (index + 1 < segments.length) {
      final next = segments[index + 1].startTick;
      if (tick > next) tick = next;
    }
    return tick < 0 ? 0 : tick;
  }

  static List<int> _cleanDownbeats(List<int> input) {
    final sorted = <int>[
      for (final ms in input)
        if (ms >= 0) ms,
    ]..sort();
    final out = <int>[];
    for (final ms in sorted) {
      if (out.isNotEmpty && ms <= out.last) continue;
      out.add(ms);
    }
    return out;
  }

  static int _median(List<int> values) {
    final sorted = List<int>.of(values)..sort();
    final middle = sorted[sorted.length ~/ 2];
    return middle <= 0 ? 1 : middle;
  }

  /// Null rather than a guess when the bpm is missing or outside what a song
  /// can be, so the caller falls back to what it measured.
  static int? _microsFor(double? bpm) {
    if (bpm == null || !bpm.isFinite || bpm < 20 || bpm > 400) return null;
    return _clampMicros((60000000 / bpm).round());
  }

  /// A MIDI tempo is three bytes, so it cannot be zero and cannot exceed
  /// 0xFFFFFF — about 3.6 bpm at the slow end.
  static int _clampMicros(int micros) {
    if (micros < 1) return 1;
    if (micros > 0xffffff) return 0xffffff;
    return micros;
  }
}

/// A number as MIDI writes it: seven bits a byte, high bit set on every byte
/// but the last.
///
/// Public because it is the one piece of this format that is easy to get
/// subtly wrong and worth a test of its own.
List<int> midiVariableLength(int value) {
  if (value <= 0) return <int>[0];
  final out = <int>[value & 0x7f];
  var rest = value >> 7;
  while (rest > 0) {
    out.insert(0, (rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  return out;
}

/// The whole file: a type-1 MIDI with one conductor track carrying the time
/// signature, the tempo map and a marker for each section.
///
/// Type 1 rather than type 0 because type 1's first track *is* the tempo map
/// by definition, which is what every DAW looks for when it offers to import
/// tempo from a MIDI file. One track is all this needs — there are no notes
/// here, and generating any would be inventing music nobody played.
Uint8List writeTempoMapMidi({
  required SongTempoMap map,
  List<MidiMarker> markers = const <MidiMarker>[],
  String? trackName,
}) {
  // (tick, rank, bytes). The rank keeps events at the same tick in the order
  // a reader expects: what the track is, then how it is counted, then how
  // fast, then what is happening.
  final events = <(int, int, int, List<int>)>[];

  final name = _asciiText(trackName ?? '');
  if (name.isNotEmpty) {
    events.add((0, 0, 0x03, name.codeUnits));
  }

  final pickup = map.pickupBeats;
  if (pickup > 0) {
    events.add((0, 1, 0x58, _timeSignature(pickup)));
    if (pickup != map.beatsPerBar) {
      events.add((map.firstDownbeatTick, 1, 0x58, _timeSignature(map.beatsPerBar)));
    }
  } else {
    events.add((0, 1, 0x58, _timeSignature(map.beatsPerBar)));
  }

  var previousMicros = -1;
  for (final segment in map.segments) {
    if (segment.microsecondsPerBeat == previousMicros) continue;
    previousMicros = segment.microsecondsPerBeat;
    events.add((
      segment.startTick,
      2,
      0x51,
      <int>[
        (segment.microsecondsPerBeat >> 16) & 0xff,
        (segment.microsecondsPerBeat >> 8) & 0xff,
        segment.microsecondsPerBeat & 0xff,
      ],
    ));
  }

  for (final marker in markers) {
    final text = _asciiText(marker.text);
    if (text.isEmpty) continue;
    events.add((map.tickAt(marker.atMs), 3, 0x06, text.codeUnits));
  }

  events.sort((a, b) {
    final byTick = a.$1.compareTo(b.$1);
    return byTick != 0 ? byTick : a.$2.compareTo(b.$2);
  });

  final track = <int>[];
  var at = 0;
  for (final event in events) {
    track
      ..addAll(midiVariableLength(event.$1 - at))
      ..add(0xff)
      ..add(event.$3)
      ..addAll(midiVariableLength(event.$4.length))
      ..addAll(event.$4);
    at = event.$1;
  }
  track.addAll(<int>[0x00, 0xff, 0x2f, 0x00]);

  final out = <int>[]
    ..addAll('MThd'.codeUnits)
    ..addAll(_uint32(6))
    ..addAll(_uint16(1)) // format 1
    ..addAll(_uint16(1)) // one track, the conductor track
    ..addAll(_uint16(map.ticksPerBeat))
    ..addAll('MTrk'.codeUnits)
    ..addAll(_uint32(track.length))
    ..addAll(track);
  return Uint8List.fromList(out);
}

/// nn dd cc bb: the count, the beat as a power of two, MIDI clocks to the
/// metronome click, and 32nd notes to the quarter. Everything here is
/// counted in quarters, so the denominator is always four.
List<int> _timeSignature(int beats) =>
    <int>[beats.clamp(1, 255), 2, 24, 8];

/// MIDI text is bytes with no stated encoding, and readers disagree about
/// anything above 127. Section names are the band's own words, so the two
/// characters that actually turn up in music — the sharp and flat signs —
/// are spelled out, and anything else beyond ASCII is dropped rather than
/// written as a byte some DAW will draw as a box.
String _asciiText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x266f) {
      buffer.write('#');
    } else if (rune == 0x266d) {
      buffer.write('b');
    } else if (rune >= 0x20 && rune <= 0x7e) {
      buffer.writeCharCode(rune);
    }
  }
  final text = buffer.toString().trim();
  // Meta lengths here are written as variable-length quantities, so a long
  // name is legal; it is just unreadable in a DAW's ruler.
  return text.length <= 120 ? text : text.substring(0, 120);
}

List<int> _uint16(int value) => <int>[(value >> 8) & 0xff, value & 0xff];

List<int> _uint32(int value) => <int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
