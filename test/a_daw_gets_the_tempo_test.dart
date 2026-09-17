import 'package:colabroom/services/midi_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// The MIDI file is checked byte by byte on purpose.
///
/// Nothing about it can be heard from here: it is read by Ableton or Logic on
/// somebody else's laptop, and a header two bytes wrong is a file that simply
/// will not open, with nothing on this end to show for it. The format is
/// small and fixed, so the bytes themselves are the only honest test.

/// Whether [haystack] contains [needle] end to end.
bool _contains(List<int> haystack, List<int> needle) {
  for (var at = 0; at + needle.length <= haystack.length; at += 1) {
    var same = true;
    for (var i = 0; i < needle.length; i += 1) {
      if (haystack[at + i] != needle[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

void main() {
  group('numbers the way MIDI writes them', () {
    test('seven bits a byte, high bit set on all but the last', () {
      // The examples from the standard itself, which is the only reason to
      // trust an encoder nobody can read the output of.
      expect(midiVariableLength(0), <int>[0x00]);
      expect(midiVariableLength(0x40), <int>[0x40]);
      expect(midiVariableLength(0x7f), <int>[0x7f]);
      expect(midiVariableLength(0x80), <int>[0x81, 0x00]);
      expect(midiVariableLength(0x2000), <int>[0xc0, 0x00]);
      expect(midiVariableLength(0x3fff), <int>[0xff, 0x7f]);
      expect(midiVariableLength(0x4000), <int>[0x81, 0x80, 0x00]);
      expect(midiVariableLength(0x100000), <int>[0xc0, 0x80, 0x00]);
      expect(midiVariableLength(0xfffffff), <int>[0xff, 0xff, 0xff, 0x7f]);
    });

    test('a delta cannot be negative, so it is zero instead', () {
      expect(midiVariableLength(-5), <int>[0x00]);
    });
  });

  group('the file a DAW opens', () {
    test('is a type-1 file with one track at 480 ticks a beat', () {
      final bytes = writeTempoMapMidi(map: SongTempoMap.forSong(bpm: 92));

      expect(bytes.sublist(0, 4), 'MThd'.codeUnits);
      // Six bytes of header: format, track count, division.
      expect(bytes.sublist(4, 8), <int>[0x00, 0x00, 0x00, 0x06]);
      expect(bytes.sublist(8, 10), <int>[0x00, 0x01]); // format 1
      expect(bytes.sublist(10, 12), <int>[0x00, 0x01]); // one track
      expect(bytes.sublist(12, 14), <int>[0x01, 0xe0]); // 480
      expect(bytes.sublist(14, 18), 'MTrk'.codeUnits);
    });

    test('ends where it says it ends', () {
      final bytes = writeTempoMapMidi(map: SongTempoMap.forSong(bpm: 92));
      final length = (bytes[18] << 24) | (bytes[19] << 16) | (bytes[20] << 8) | bytes[21];
      expect(bytes.length, 22 + length);
      // End of track, which a reader that trusts the chunk length still looks
      // for and a reader that does not needs.
      expect(bytes.sublist(bytes.length - 4), <int>[0x00, 0xff, 0x2f, 0x00]);
    });

    test('says 92 bpm as the microseconds a beat lasts', () {
      final bytes = writeTempoMapMidi(map: SongTempoMap.forSong(bpm: 92));
      // 60,000,000 / 92 = 652,174 microseconds, which is 0x09F38E.
      expect(_contains(bytes, <int>[0xff, 0x51, 0x03, 0x09, 0xf3, 0x8e]), isTrue);
    });

    test('counts in four unless the song says otherwise', () {
      final four = writeTempoMapMidi(map: SongTempoMap.forSong(bpm: 92));
      expect(_contains(four, <int>[0xff, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]), isTrue);

      final three = writeTempoMapMidi(
        map: SongTempoMap.forSong(
          bpm: 120,
          downbeatsMs: <int>[0, 1500, 3000],
          beatsPerBar: 3,
        ),
      );
      expect(_contains(three, <int>[0xff, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08]), isTrue);
    });

    test('writes the section names as markers', () {
      final bytes = writeTempoMapMidi(
        map: SongTempoMap.forSong(bpm: 120, downbeatsMs: <int>[0, 2000, 4000]),
        markers: const <MidiMarker>[
          MidiMarker(atMs: 0, text: 'Intro'),
          MidiMarker(atMs: 2000, text: 'Chorus'),
        ],
      );
      expect(
        _contains(bytes, <int>[0xff, 0x06, 0x06, ...'Chorus'.codeUnits]),
        isTrue,
      );
      // At 120 bpm a bar of four is two seconds, so the chorus falls on the
      // second bar line: 4 beats × 480 ticks. The delta from the events at
      // tick 0 is 1920, which is 0x8F 0x00 as a variable-length quantity.
      expect(
        _contains(bytes, <int>[0x8f, 0x00, 0xff, 0x06, 0x06, ...'Chorus'.codeUnits]),
        isTrue,
      );
    });

    test('a name with nothing in it is left out rather than written empty', () {
      final bytes = writeTempoMapMidi(
        map: SongTempoMap.forSong(bpm: 120),
        markers: const <MidiMarker>[MidiMarker(atMs: 0, text: '   ')],
      );
      expect(_contains(bytes, <int>[0xff, 0x06]), isFalse);
    });

    test('the song title rides along as the track name', () {
      final bytes = writeTempoMapMidi(
        map: SongTempoMap.forSong(bpm: 120),
        trackName: 'Tonight',
      );
      expect(
        _contains(bytes, <int>[0xff, 0x03, 0x07, ...'Tonight'.codeUnits]),
        isTrue,
      );
    });
  });

  group('where the bars fall', () {
    test('a steady song gets one tempo, not one a bar', () {
      // Four bars of exactly two seconds. One number says all of it, and one
      // number is what a person would type into a DAW.
      final map = SongTempoMap.forSong(
        bpm: 120,
        downbeatsMs: <int>[0, 2000, 4000, 6000, 8000],
      );
      expect(map.segments.length, 1);
      expect(map.statedBpm, closeTo(120, 0.01));
    });

    test('a band that moves gets a tempo for every bar', () {
      final map = SongTempoMap.forSong(
        downbeatsMs: <int>[0, 2000, 3800, 5400, 7400],
      );
      expect(map.segments.length, 4);
      expect(map.segments.first.bpm, closeTo(120, 0.1));
      // 1800 ms for four beats is 450 ms a beat, which is 133 and a third.
      expect(map.segments[1].bpm, closeTo(133.33, 0.1));
    });

    test('the lead-in becomes a pickup so bar one is the first downbeat', () {
      // The trap multitrack.dart already found with the click: a grid that
      // starts at zero when the music does not is wrong for the whole song.
      final map = SongTempoMap.forSong(
        bpm: 120,
        downbeatsMs: <int>[1000, 3000, 5000, 7000],
      );
      // A beat is 500 ms here, so a second of lead-in is two beats.
      expect(map.pickupBeats, 2);
      expect(map.firstDownbeatTick, 960);
      expect(map.tickAt(1000), 960);
      expect(map.tickAt(3000), 960 + 1920);
      // And the pickup is exactly as long as the lead-in really was, which is
      // the only way the first downbeat lands on the bar line.
      expect(map.segments.first.microsecondsPerBeat * 2, closeTo(1000000, 2));
    });

    test('a lead-in too short to be a beat is not made into one', () {
      final map = SongTempoMap.forSong(
        bpm: 120,
        downbeatsMs: <int>[80, 2080, 4080],
      );
      expect(map.pickupBeats, 0);
      expect(map.tickAt(0), 0);
      expect(map.tickAt(80), 0);
    });

    test('nothing known about the bars still gives a tempo from the start', () {
      final map = SongTempoMap.forSong(bpm: 92);
      expect(map.segments.length, 1);
      expect(map.segments.first.startTick, 0);
      expect(map.statedBpm, closeTo(92, 0.01));
    });

    test('no tempo and no bars falls back rather than dividing by nothing', () {
      final map = SongTempoMap.forSong();
      expect(map.statedBpm, closeTo(120, 0.01));
      expect(map.tickAt(500), 480);
    });

    test('downbeats out of order or repeated do not break the grid', () {
      final map = SongTempoMap.forSong(
        bpm: 120,
        downbeatsMs: <int>[4000, 0, 2000, 2000, -50],
      );
      expect(map.pickupBeats, 0);
      expect(map.tickAt(2000), 1920);
    });
  });
}
