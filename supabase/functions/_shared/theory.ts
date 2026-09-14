// The arithmetic behind "what fits here", for the server.
//
// A copy of the rules in lib/services/music_reference.dart, not a new idea:
// given a key, the seven chords that belong to it and the relative key;
// given the chords a song already uses, the ones it has not reached for.
// Deterministic on purpose. The model that answers questions is handed
// these as facts, because "what else fits" has exactly one right answer
// and a language model is a worse version of arithmetic -- right most of
// the time and confidently wrong occasionally, which in front of a
// guitarist ends the feature in one screen.

const SHARP_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const FLAT_NAMES = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'];
const PITCH: Record<string, number> = {
  C: 0, 'C#': 1, Db: 1, D: 2, 'D#': 3, Eb: 3, E: 4, F: 5, 'F#': 6, Gb: 6,
  G: 7, 'G#': 8, Ab: 8, A: 9, 'A#': 10, Bb: 10, B: 11,
};
const MAJOR_STEPS = [0, 2, 4, 5, 7, 9, 11];
const MINOR_STEPS = [0, 2, 3, 5, 7, 8, 10];
const MAJOR_QUALITIES = ['', 'm', 'm', '', '', 'm', 'dim'];
const MINOR_QUALITIES = ['m', 'dim', '', 'm', 'm', '', ''];
const MAJOR_DEGREES = ['I', 'ii', 'iii', 'IV', 'V', 'vi', 'vii°'];
const MINOR_DEGREES = ['i', 'ii°', 'III', 'iv', 'v', 'VI', 'VII'];

export interface KeyFacts {
  /// "D major", as a person says it.
  display: string;
  tonic: string;
  minor: boolean;
  /// The seven chords of the key, in degree order: D, Em, F#m, G, A, Bm, C#dim.
  diatonic: string[];
  /// The relative minor of a major key, or the relative major of a minor one.
  relative: string;
}

function noteName(pitch: number, flats: boolean): string {
  const index = ((pitch % 12) + 12) % 12;
  return flats ? FLAT_NAMES[index] : SHARP_NAMES[index];
}

function prefersFlats(root: string): boolean {
  // F is the one natural that belongs to the flat side of the circle.
  return root.includes('b') || root === 'F';
}

/// The key a label names, or null when it is not one. Accepts the shapes the
/// analyser writes ("D major", "E minor", "Dm", "F# min").
export function describeKey(label: string | null | undefined): KeyFacts | null {
  const raw = (label ?? '').trim();
  const match = /^([A-G][#b]?)\s*(.*)$/.exec(raw);
  if (!match) return null;
  const tonic = match[1];
  const rest = match[2].toLowerCase();
  const tonicPitch = PITCH[tonic];
  if (tonicPitch === undefined) return null;
  const minor = rest.startsWith('min') || rest === 'm' || rest.startsWith('aeolian');
  const flats = prefersFlats(tonic);
  const steps = minor ? MINOR_STEPS : MAJOR_STEPS;
  const qualities = minor ? MINOR_QUALITIES : MAJOR_QUALITIES;
  const scale = steps.map((step) => noteName(tonicPitch + step, flats));
  return {
    display: `${tonic} ${minor ? 'minor' : 'major'}`,
    tonic,
    minor,
    diatonic: scale.map((note, i) => `${note}${qualities[i]}`),
    relative: minor
      ? `${noteName(tonicPitch + 3, flats)} major`
      : `${noteName(tonicPitch + 9, flats)} minor`,
  };
}

/// The note a chord is built on: "F#m7" -> "F#".
export function rootOf(chord: string): string | null {
  const match = /^([A-G][#b]?)/.exec(chord.trim());
  return match ? match[1] : null;
}

function samePitch(a: string, b: string): boolean {
  const pa = PITCH[a];
  const pb = PITCH[b];
  return pa !== undefined && pa === pb;
}

/// The chords of the key that the song has not used yet -- the single most
/// useful thing to tell somebody stuck: seven chords is a list anybody can
/// look up, "here are the three you have not touched" is about their song.
export function untouchedChords(key: KeyFacts, used: string[]): string[] {
  const usedRoots = used.map(rootOf).filter((r): r is string => r !== null);
  return key.diatonic.filter((chord) => {
    const root = rootOf(chord);
    return root !== null && !usedRoots.some((u) => samePitch(u, root));
  });
}

/// Where a chord sits in the key -- "the IV" -- or null when it is from
/// outside it. Null is a real answer: a borrowed chord is a thing musicians
/// do on purpose, and calling it the iii when it is not is worse than nothing.
export function degreeOf(key: KeyFacts, chord: string): string | null {
  const root = rootOf(chord);
  if (root === null) return null;
  const at = key.diatonic.findIndex((name) => {
    const r = rootOf(name);
    return r !== null && samePitch(r, root);
  });
  if (at < 0) return null;
  return (key.minor ? MINOR_DEGREES : MAJOR_DEGREES)[at];
}

// Harte shorthand as a musician writes it, mirroring lib/services/chord_names.dart.
const QUALITY_NAMES: Record<string, string> = {
  maj: '', min: 'm', dim: '°', aug: '+', '7': '7', maj7: 'maj7', min7: 'm7',
  dim7: '°7', hdim7: 'm7♭5', minmaj7: 'mMaj7', maj6: '6', min6: 'm6', '6': '6',
  '9': '9', maj9: 'maj9', min9: 'm9', '11': '11', '13': '13', sus2: 'sus2', sus4: 'sus4',
};
const DEGREE_SEMITONES: Record<string, number> = {
  '1': 0, b2: 1, '2': 2, '#2': 3, b3: 3, '3': 4, '4': 5, '#4': 6, b5: 6, '5': 7,
  '#5': 8, b6: 8, '6': 9, b7: 10, '7': 11, b9: 1, '9': 2, '11': 5, '#11': 6, '13': 9,
};

/// A chord label as a musician writes it: `A:min7` -> `Am7`, `D:maj/5` -> `D/A`.
///
/// ChordMini stores Harte notation, which is exact and not what anybody puts
/// on a music stand -- and not what a model should be shown either, since
/// it will echo "A:min7" back into an answer somebody reads aloud. Anything
/// without a colon is passed through: chords a person typed are already
/// spelled the way they want them. `N` (no chord) becomes an empty string.
export function displayChord(label: string): string {
  const raw = label.trim();
  if (raw === '' || raw === 'N' || raw === 'X') return '';
  const colon = raw.indexOf(':');
  if (colon <= 0) return raw;
  const root = raw.slice(0, colon);
  let quality = raw.slice(colon + 1);
  let bass = '';
  const slash = quality.indexOf('/');
  if (slash >= 0) {
    bass = quality.slice(slash + 1);
    quality = quality.slice(0, slash);
  }
  const written = QUALITY_NAMES[quality] ?? quality;
  return `${root}${written}${bassSuffix(root, bass)}`;
}

function bassSuffix(root: string, bass: string): string {
  if (bass === '') return '';
  if (PITCH[bass] !== undefined) return `/${bass}`;
  const degree = DEGREE_SEMITONES[bass];
  const rootValue = PITCH[root];
  if (degree === undefined || rootValue === undefined) return `/${bass}`;
  return `/${noteName(rootValue + degree, prefersFlats(root))}`;
}
