import 'package:flutter/material.dart';

import 'toolbox_models.dart';

/// Static, curated reference content bundled with the app — not
/// user-editable or synced, just a shipped library. New categories start
/// with no sheets (shown as "More coming soon") until they're written.
const toolboxCategories = <ToolboxCategory>[
  ToolboxCategory(
    id: 'guitar',
    name: 'Guitar',
    icon: Icons.music_note_rounded,
    tagline: 'Open chords, capo math, and scale formulas',
    sheets: _guitarSheets,
  ),
  ToolboxCategory(
    id: 'bass',
    name: 'Bass',
    icon: Icons.graphic_eq_rounded,
    tagline: 'Tuning, scale formulas, and root-note patterns',
    sheets: _bassSheets,
  ),
  ToolboxCategory(
    id: 'piano',
    name: 'Piano / Keys',
    icon: Icons.piano_rounded,
    tagline: 'Coming soon',
  ),
  ToolboxCategory(
    id: 'percussion',
    name: 'Percussion',
    icon: Icons.graphic_eq_rounded,
    tagline: 'Coming soon',
  ),
  ToolboxCategory(
    id: 'vocals',
    name: 'Vocalist',
    icon: Icons.mic_rounded,
    tagline: 'Coming soon',
  ),
  ToolboxCategory(
    id: 'mixing',
    name: 'Mixing',
    icon: Icons.tune_rounded,
    tagline: 'Coming soon',
  ),
  ToolboxCategory(
    id: 'recording',
    name: 'Recording',
    icon: Icons.fiber_manual_record_rounded,
    tagline: 'Coming soon',
  ),
];

const _guitarSheets = <CheatSheet>[
  CheatSheet(
    id: 'open_chords',
    title: 'Open Chord Shapes',
    icon: Icons.grid_view_rounded,
    kind: CheatSheetKind.chordDiagrams,
    chords: <ChordDiagramData>[
      ChordDiagramData(name: 'E', frets: <int>[0, 2, 2, 1, 0, 0]),
      ChordDiagramData(name: 'Em', frets: <int>[0, 2, 2, 0, 0, 0]),
      ChordDiagramData(name: 'E7', frets: <int>[0, 2, 0, 1, 0, 0]),
      ChordDiagramData(name: 'A', frets: <int>[-1, 0, 2, 2, 2, 0]),
      ChordDiagramData(name: 'Am', frets: <int>[-1, 0, 2, 2, 1, 0]),
      ChordDiagramData(name: 'A7', frets: <int>[-1, 0, 2, 0, 2, 0]),
      ChordDiagramData(name: 'D', frets: <int>[-1, -1, 0, 2, 3, 2]),
      ChordDiagramData(name: 'Dm', frets: <int>[-1, -1, 0, 2, 3, 1]),
      ChordDiagramData(name: 'D7', frets: <int>[-1, -1, 0, 2, 1, 2]),
      ChordDiagramData(name: 'G', frets: <int>[3, 2, 0, 0, 0, 3]),
      ChordDiagramData(name: 'G7', frets: <int>[3, 2, 0, 0, 0, 1]),
      ChordDiagramData(name: 'C', frets: <int>[-1, 3, 2, 0, 1, 0]),
    ],
  ),
  CheatSheet(
    id: 'capo_chart',
    title: 'Capo Chart',
    icon: Icons.straighten_rounded,
    kind: CheatSheetKind.text,
    sections: <CheatSheetSection>[
      CheatSheetSection(
        heading: 'What a C shape actually sounds like, by capo fret',
        rows: <CheatSheetRow>[
          CheatSheetRow('Capo 1', 'C shape → C#  ·  G shape → G#  ·  D shape → D#'),
          CheatSheetRow('Capo 2', 'C shape → D  ·  G shape → A  ·  D shape → E'),
          CheatSheetRow('Capo 3', 'C shape → D#  ·  G shape → A#  ·  D shape → F'),
          CheatSheetRow('Capo 4', 'C shape → E  ·  G shape → B  ·  D shape → F#'),
          CheatSheetRow('Capo 5', 'C shape → F  ·  G shape → C  ·  D shape → G'),
          CheatSheetRow('Capo 7', 'C shape → G  ·  G shape → D  ·  D shape → A'),
        ],
      ),
      CheatSheetSection(
        heading: 'Reading it',
        rows: <CheatSheetRow>[
          CheatSheetRow('Rule', 'Count up that many half-steps from the shape\'s open-chord name.'),
        ],
      ),
    ],
  ),
  CheatSheet(
    id: 'scale_formulas',
    title: 'Scale Formulas',
    icon: Icons.stacked_line_chart_rounded,
    kind: CheatSheetKind.text,
    sections: <CheatSheetSection>[
      CheatSheetSection(
        heading: 'Formulas (W = whole step, H = half step)',
        rows: <CheatSheetRow>[
          CheatSheetRow('Major', 'W W H W W W H'),
          CheatSheetRow('Natural minor', 'W H W W H W W'),
          CheatSheetRow('Major pentatonic', 'W W W+H W W+H'),
          CheatSheetRow('Minor pentatonic', 'W+H W W W+H W'),
        ],
      ),
      CheatSheetSection(
        heading: 'C major / A minor (no sharps or flats — easiest reference key)',
        rows: <CheatSheetRow>[
          CheatSheetRow('C major', 'C D E F G A B C'),
          CheatSheetRow('A natural minor', 'A B C D E F G A'),
          CheatSheetRow('A minor pentatonic', 'A C D E G A'),
        ],
      ),
      CheatSheetSection(
        heading: 'G major / E minor (one sharp)',
        rows: <CheatSheetRow>[
          CheatSheetRow('G major', 'G A B C D E F# G'),
          CheatSheetRow('E natural minor', 'E F# G A B C D E'),
        ],
      ),
    ],
  ),
];

const _bassSheets = <CheatSheet>[
  CheatSheet(
    id: 'standard_tuning',
    title: 'Standard Tuning',
    icon: Icons.straighten_rounded,
    kind: CheatSheetKind.text,
    sections: <CheatSheetSection>[
      CheatSheetSection(
        heading: 'Open strings (4-string bass, low to high)',
        rows: <CheatSheetRow>[
          CheatSheetRow('4th string', 'E — lowest, thickest string'),
          CheatSheetRow('3rd string', 'A'),
          CheatSheetRow('2nd string', 'D'),
          CheatSheetRow('1st string', 'G — highest, thinnest string'),
        ],
      ),
      CheatSheetSection(
        heading: '5-string basses add',
        rows: <CheatSheetRow>[
          CheatSheetRow('5th string', 'B — below the E string'),
        ],
      ),
    ],
  ),
  CheatSheet(
    id: 'scale_formulas',
    title: 'Scale Formulas',
    icon: Icons.stacked_line_chart_rounded,
    kind: CheatSheetKind.text,
    sections: <CheatSheetSection>[
      CheatSheetSection(
        heading: 'Formulas (W = whole step, H = half step)',
        rows: <CheatSheetRow>[
          CheatSheetRow('Major', 'W W H W W W H'),
          CheatSheetRow('Natural minor', 'W H W W H W W'),
          CheatSheetRow('Major pentatonic', 'W W W+H W W+H'),
          CheatSheetRow('Minor pentatonic', 'W+H W W W+H W'),
        ],
      ),
      CheatSheetSection(
        heading: 'E minor pentatonic (open-string friendly — great starting scale)',
        rows: <CheatSheetRow>[
          CheatSheetRow('Notes', 'E G A B D E'),
        ],
      ),
    ],
  ),
  CheatSheet(
    id: 'root_patterns',
    title: 'Root-Note Patterns',
    icon: Icons.timeline_rounded,
    kind: CheatSheetKind.text,
    sections: <CheatSheetSection>[
      CheatSheetSection(
        heading: 'Common groove patterns, relative to the chord\'s root note',
        rows: <CheatSheetRow>[
          CheatSheetRow('Root-fifth', 'Root, then the 5th (7 half-steps up) — the most common bass move'),
          CheatSheetRow('Root-octave', 'Root, then the same note an octave up, for a driving feel'),
          CheatSheetRow('Walking (major)', 'Root, 3rd, 5th, 6th — walks smoothly into the next chord\'s root'),
          CheatSheetRow('Walking (minor)', 'Root, b3rd, 4th, 5th'),
        ],
      ),
    ],
  ),
];
