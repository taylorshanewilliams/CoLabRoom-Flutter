import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/chord_repeats.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Correct a chord once, and everywhere it repeats.
///
/// Every Musician, Same Song, 17 September 2026, slice 36, finishing step 3
/// of "A Second Pair of Ears". A correction used to save at one moment in
/// the song and spread nowhere, so the wrong chord the model heard in every
/// chorus had to be fixed in every chorus. Now the correction is saved where
/// it was made, and one line asks whether it goes in the other choruses too.
/// Declining changes only the one place; nothing is ever guessed across
/// sections that are not repeats of each other; a chord somebody typed by
/// hand in a repeat stays exactly as they typed it.
void main() {
  group('where a correction would also go', () {
    test('the repeats are found from real section data', () {
      final offer = findChordRepeats(
        bundle: _corrected(_song()),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      expect(offer, isNotNull);
      expect(offer!.section.label, 'Chorus');
      expect(offer.chord, 'Am');
      expect(offer.question, 'Also in the other two choruses?');

      // Bar 3 of chorus 2 and bar 3 of chorus 3, replacing the C the model
      // heard in each. The verses have the same wrong C in the same bar and
      // are not choruses, so they are not offered.
      expect(offer.targets.length, 2);
      expect(offer.targets.map((t) => t.section.label), everyElement('Chorus'));
      expect(offer.targets[0].section.startMs, 48000);
      expect(offer.targets[0].startMs, 52000);
      expect(offer.targets[0].endMs, 55900);
      expect(offer.targets[0].replaces?.id, 14);
      expect(offer.targets[1].section.startMs, 72000);
      expect(offer.targets[1].startMs, 76000);
      expect(offer.targets[1].replaces?.id, 19);
    });

    test('a corrected start that drifted off the beat still finds the beat',
        () {
      // The saved start is interpolated from the word it sits over, so it
      // can land a little after the change the model heard. The counterpart
      // is found from where the detected cue was; the new chord lands the
      // same distance into the bar it did at home.
      final offer = findChordRepeats(
        bundle: _corrected(_song(), startMs: 20150, endMs: 24050),
        chord: 'Am',
        startMs: 20150,
        endMs: 24050,
        originalStartMs: 20000,
      );
      expect(offer!.targets.map((t) => t.startMs), <int>[52150, 76150]);
      expect(offer.targets.map((t) => t.replaces?.id), <int>[14, 19]);
    });

    test('a last chorus too short to have that bar is not given it', () {
      final song = _song(lastChorusEndMs: 76000);
      final offer = findChordRepeats(
        bundle: _corrected(song),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      expect(offer!.targets.map((t) => t.section.startMs), <int>[48000]);
      expect(offer.question, 'Also in the other chorus?');
    });

    test('a song with no repeats offers nothing', () {
      final once = _song(
        sections: const <StructureSection>[
          StructureSection(startMs: 0, endMs: 16000, label: 'Intro'),
          StructureSection(startMs: 16000, endMs: 32000, label: 'Chorus'),
          StructureSection(startMs: 32000, endMs: 64000, label: 'Verse'),
          StructureSection(startMs: 64000, endMs: 88000, label: 'Outro'),
        ],
      );
      expect(
        findChordRepeats(
          bundle: _corrected(once),
          chord: 'Am',
          startMs: 20000,
          endMs: 23900,
          originalStartMs: 20000,
        ),
        isNull,
      );

      // No sections at all, and a chord outside every section.
      expect(
        findChordRepeats(
          bundle: _corrected(_song(sections: const <StructureSection>[])),
          chord: 'Am',
          startMs: 20000,
          endMs: 23900,
          originalStartMs: 20000,
        ),
        isNull,
      );
      expect(
        findChordRepeats(
          bundle: _corrected(_song()),
          chord: 'Am',
          startMs: 89000,
          endMs: 89500,
        ),
        isNull,
      );
    });

    test('a hand-typed chord elsewhere is left alone', () {
      // Somebody already went over bar 3 of the last chorus by hand and
      // wrote C7. That is theirs, whatever the model heard.
      final song = _song(
        rewrite: (cue) => cue.id == 19
            ? cue.copyWith(chord: 'C7', source: 'manual')
            : cue,
      );
      final offer = findChordRepeats(
        bundle: _corrected(song),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      expect(offer!.targets.map((t) => t.section.startMs), <int>[48000]);
      expect(offer.question, 'Also in the other chorus?');
    });

    test('a hand-typed chord in another bar of the repeat does not block it',
        () {
      // Bar 1 of the last chorus was typed by hand. Bar 3 was not, and the
      // correction is about bar 3.
      final song = _song(
        rewrite: (cue) => cue.id == 18 ? cue.copyWith(source: 'manual') : cue,
      );
      final offer = findChordRepeats(
        bundle: _corrected(song),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      expect(offer!.targets.map((t) => t.section.startMs), <int>[48000, 72000]);
    });

    test('a repeat that already reads the corrected chord is not touched', () {
      final song = _song(
        rewrite: (cue) => cue.id == 14 ? cue.copyWith(chord: 'Am') : cue,
      );
      final offer = findChordRepeats(
        bundle: _corrected(song),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      expect(offer!.targets.map((t) => t.section.startMs), <int>[72000]);
    });

    test('without a beat grid it is the same distance into the section', () {
      final song = _song(grid: false);
      final offer = findChordRepeats(
        bundle: _corrected(song),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      // A quarter of the way into each chorus, where the model's C is.
      expect(offer!.targets.map((t) => t.startMs), <int>[52000, 76000]);
      expect(offer.targets.map((t) => t.replaces?.id), <int>[14, 19]);
    });

    test('a chord added where nothing was detected is added in the repeats',
        () {
      // Nothing changes at bar 4 of the chorus; the C from bar 3 is still
      // ringing. Adding Am there adds it at bar 4 of the other choruses too,
      // and takes nothing away from them.
      final song = _song();
      final added = song.copyWith(chordCues: <ChordCue>[
        ...song.chordCues,
        const ChordCue(
          id: 90,
          startMs: 22000,
          endMs: 23900,
          chord: 'Am',
          confidence: 1,
          source: 'manual',
        ),
      ]);
      final offer = findChordRepeats(
        bundle: added,
        chord: 'Am',
        startMs: 22000,
        endMs: 23900,
      );
      expect(offer!.targets.map((t) => t.startMs), <int>[54000, 78000]);
      expect(offer.targets.map((t) => t.replaces), everyElement(isNull));
    });

    test('a lettered analysis finds its repeats through the pointer', () {
      // Before the parts were named, every section had its own letter and a
      // repeat pointed at the section it repeated.
      final song = _song(
        sections: const <StructureSection>[
          StructureSection(startMs: 0, endMs: 16000, label: 'A'),
          StructureSection(startMs: 16000, endMs: 32000, label: 'B'),
          StructureSection(
            startMs: 32000,
            endMs: 48000,
            label: 'C',
            repeatsSectionLabel: 'B',
          ),
          StructureSection(startMs: 48000, endMs: 88000, label: 'D'),
        ],
      );
      final offer = findChordRepeats(
        bundle: _corrected(song),
        chord: 'Am',
        startMs: 20000,
        endMs: 23900,
        originalStartMs: 20000,
      );
      expect(offer!.targets.map((t) => t.section.label), <String>['C']);
      expect(offer.targets.single.replaces?.id, 10);
      expect(offer.question, 'Also in the other part called B?');
    });

    test('the question names the part the way the band does', () {
      const chorus = StructureSection(startMs: 0, endMs: 1, label: 'Chorus');
      expect(repeatQuestion(chorus, 1), 'Also in the other chorus?');
      expect(repeatQuestion(chorus, 3), 'Also in the other three choruses?');
      const verse = StructureSection(startMs: 0, endMs: 1, label: 'Verse');
      expect(repeatQuestion(verse, 2), 'Also in the other two verses?');
      // A name the band gave cannot be made plural by a program without
      // reading badly, so it is asked about as the parts called that.
      const named = StructureSection(
        startMs: 0,
        endMs: 1,
        label: 'Chorus',
        customLabel: "Kate's bit",
      );
      expect(
        repeatQuestion(named, 2),
        "Also in the other two parts called Kate's bit?",
      );
      const unknown =
          StructureSection(startMs: 0, endMs: 1, label: 'Pre-chorus');
      expect(
        repeatQuestion(unknown, 1),
        'Also in the other part called Pre-chorus?',
      );
    });
  });

  group('the panel asks, once', () {
    testWidgets('accept changes all, and the chart and the sheet agree',
        (tester) async {
      final (service, latest) = await _correctTheFirstChorus(tester);

      await tester.ensureVisible(
        find.byKey(const Key('repeat_correction_everywhere')),
      );
      await tester.tap(find.byKey(const Key('repeat_correction_everywhere')));
      await tester.pumpAndSettle();

      // The question is answered and gone.
      expect(find.byKey(const Key('repeat_correction_question')), findsNothing);

      // Every chorus reads Am by hand; the verses keep the model's C.
      final manual = service.bundle.chordCues.where((cue) => cue.isManual);
      expect(manual.map((cue) => cue.chord), everyElement('Am'));
      expect(manual.map((cue) => cue.startMs), <int>[20000, 52000, 76000]);
      final cs = service.bundle.chordCues.where((cue) => cue.chord == 'C');
      expect(cs.map((cue) => cue.startMs), <int>[4000, 36000]);
      expect(cs.map((cue) => cue.isManual), everyElement(isFalse));

      // The sheet: three choruses read Am, and the verse line still reads C.
      expect(find.text('Am'), findsNWidgets(3));
      expect(find.text('C'), findsOneWidget);

      // The parent was handed the same bundle, which is what Perform opens
      // with.
      expect(identical(latest.value, service.bundle), isTrue);

      // The chart is rebuilt from the same cues: Am in bar 3 of each chorus
      // and in the bridge, C in bar 3 of each verse.
      await tester.tap(find.text('Chart'));
      await tester.pumpAndSettle();
      expect(find.text('Am'), findsNWidgets(4));
      expect(find.text('C'), findsNWidgets(2));
    });

    testWidgets('decline changes one', (tester) async {
      final (service, _) = await _correctTheFirstChorus(tester);

      await tester.ensureVisible(
        find.byKey(const Key('repeat_correction_here_only')),
      );
      await tester.tap(find.byKey(const Key('repeat_correction_here_only')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('repeat_correction_question')), findsNothing);
      expect(service.applied, 0);
      final manual = service.bundle.chordCues.where((cue) => cue.isManual);
      expect(manual.map((cue) => cue.startMs), <int>[20000]);
      expect(find.text('Am'), findsOneWidget);
      expect(find.text('C'), findsNWidgets(3));
    });

    testWidgets('a song with no repeats asks nothing', (tester) async {
      final (service, _) = await _correctTheFirstChorus(
        tester,
        song: _song(
          sections: const <StructureSection>[
            StructureSection(startMs: 0, endMs: 16000, label: 'Verse'),
            StructureSection(startMs: 16000, endMs: 32000, label: 'Chorus'),
            StructureSection(startMs: 32000, endMs: 88000, label: 'Outro'),
          ],
        ),
        expectQuestion: false,
      );
      expect(find.byKey(const Key('repeat_correction_question')), findsNothing);
      final manual = service.bundle.chordCues.where((cue) => cue.isManual);
      expect(manual.map((cue) => cue.startMs), <int>[20000]);
    });
  });
}

/// Opens the sheet on the song, turns on editing, and corrects the C the
/// model heard in bar 3 of the first chorus to Am. Returns the service that
/// remembered it and the last bundle the panel handed its parent.
Future<(_RememberingAnalysis, ValueNotifier<SongAnalysisBundle?>)>
    _correctTheFirstChorus(
  WidgetTester tester, {
  SongAnalysisBundle? song,
  bool expectQuestion = true,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final service = _RememberingAnalysis(song ?? _song());
  final latest = ValueNotifier<SongAnalysisBundle?>(null);
  addTearDown(latest.dispose);
  // The width the other sheet tests use; the panel's toolbar overflows the
  // test font narrower than this, and that row is not what is on trial here.
  tester.view.physicalSize = const Size(520, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: _Screen(service: service, latest: latest),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();

  await tester.tap(find.byKey(const Key('toggle_chord_editing')));
  await tester.pump();
  await tester.ensureVisible(find.byKey(const Key('edit_chord_6')));
  await tester.tap(find.byKey(const Key('edit_chord_6')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('manual_chord_name')), 'Am');
  await tester.pump();
  await tester.tap(find.byKey(const Key('save_manual_chord')));
  await tester.pumpAndSettle();

  if (expectQuestion) {
    final question = tester.widget<Text>(
      find.byKey(const Key('repeat_correction_question')),
    );
    expect(question.data, 'Also in the other two choruses?');
  }
  return (service, latest);
}

/// The panel's parent, wired the way SongAnalysisScreen wires it: it holds
/// the bundle, and hands every correction straight back into the panel
/// through setState. That echo is what the real screen does, and it is what
/// would have taken the offer away in the same frame it was made had the
/// panel read it as a change — so the harness does it too, rather than
/// quietly watching from outside.
class _Screen extends StatefulWidget {
  const _Screen({required this.service, required this.latest});

  final _RememberingAnalysis service;
  final ValueNotifier<SongAnalysisBundle?> latest;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  late SongAnalysisBundle _bundle = widget.service.bundle;

  @override
  Widget build(BuildContext context) {
    return SongSheetPanel(
      project: _project(),
      bundle: _bundle,
      onReviewLyrics: null,
      onOpenLive: null,
      analysisService: widget.service,
      onAnalysisChanged: (bundle) {
        widget.latest.value = bundle;
        setState(() => _bundle = bundle);
      },
    );
  }
}

/// An analysis service that keeps the cues in memory and does to them what
/// the real one does to the rows.
class _RememberingAnalysis extends SongAnalysisService {
  _RememberingAnalysis(this.bundle) : super(client: null);

  SongAnalysisBundle bundle;
  int applied = 0;
  int _nextId = 100;

  @override
  Future<SongAnalysisBundle> load(String projectId) async => bundle;

  void _remove({int? cueId, int? startMs, String? chord}) {
    bundle = bundle.copyWith(
      chordCues: bundle.chordCues
          .where((cue) => cueId != null
              ? cue.id != cueId
              : !(cue.startMs == startMs && cue.chord == chord))
          .toList(growable: false),
    );
  }

  void _add(String chord, int startMs, int endMs) {
    bundle = bundle.copyWith(
      chordCues: <ChordCue>[
        ...bundle.chordCues,
        ChordCue(
          id: _nextId++,
          startMs: startMs,
          endMs: endMs,
          chord: chord,
          confidence: 1,
          source: 'manual',
        ),
      ]..sort((a, b) => a.startMs.compareTo(b.startMs)),
    );
  }

  @override
  Future<SongAnalysisBundle> saveManualChordCue({
    required String projectId,
    int? cueId,
    int? originalStartMs,
    String? originalChord,
    required String chord,
    required int startMs,
    required int endMs,
  }) async {
    if (cueId != null || (originalStartMs != null && originalChord != null)) {
      _remove(cueId: cueId, startMs: originalStartMs, chord: originalChord);
    }
    _add(chord, startMs, endMs);
    return bundle;
  }

  @override
  Future<SongAnalysisBundle> applyChordToRepeats({
    required String projectId,
    required String chord,
    required List<ChordRepeatTarget> targets,
  }) async {
    applied += 1;
    for (final target in targets) {
      final gone = target.replaces;
      if (gone != null) {
        _remove(cueId: gone.id, startMs: gone.startMs, chord: gone.chord);
      }
    }
    for (final target in targets) {
      _add(chord, target.startMs, target.endMs);
    }
    return bundle;
  }
}

SongProject _project() {
  final now = DateTime(2026, 9, 17);
  return SongProject(
    id: 'song-repeats',
    roomId: 'room',
    accountId: 'account',
    title: 'Hold On',
    createdAt: now,
    updatedAt: now,
  );
}

/// The song after the first chorus's C has been corrected to Am, the way
/// the panel's save leaves it: the detected cue gone, a manual one in its
/// place.
SongAnalysisBundle _corrected(
  SongAnalysisBundle song, {
  int startMs = 20000,
  int endMs = 23900,
}) =>
    song.copyWith(chordCues: <ChordCue>[
      for (final cue in song.chordCues)
        if (cue.id != 6) cue,
      ChordCue(
        id: 99,
        startMs: startMs,
        endMs: endMs,
        chord: 'Am',
        confidence: 1,
        source: 'manual',
      ),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs)));

const List<StructureSection> _form = <StructureSection>[
  StructureSection(startMs: 0, endMs: 16000, label: 'Verse'),
  StructureSection(startMs: 16000, endMs: 32000, label: 'Chorus'),
  StructureSection(startMs: 32000, endMs: 48000, label: 'Verse'),
  StructureSection(startMs: 48000, endMs: 64000, label: 'Chorus'),
  StructureSection(startMs: 64000, endMs: 72000, label: 'Bridge'),
  StructureSection(startMs: 72000, endMs: 88000, label: 'Chorus'),
];

/// A song at 120 in four: a two-second bar, eight bars to a verse and a
/// chorus, four to the bridge. The model heard C in bar 3 of every verse and
/// every chorus. It is Am in the choruses.
///
/// Three chorus lines and one verse line are sung, so the sheet has words
/// for the correction to sit over; the second verse and the bridge are
/// instrumental here and only the chart shows them.
SongAnalysisBundle _song({
  List<StructureSection> sections = _form,
  int lastChorusEndMs = 88000,
  bool grid = true,
  ChordCue Function(ChordCue cue)? rewrite,
}) {
  const bar = 2000;
  final form = <StructureSection>[
    for (final section in sections)
      section.startMs == 72000 && section.label == 'Chorus'
          ? StructureSection(
              startMs: section.startMs,
              endMs: lastChorusEndMs,
              label: section.label,
              groupIndex: section.groupIndex,
              customLabel: section.customLabel,
            )
          : section,
  ];
  ChordCue cue(int id, String chord, int startMs) => ChordCue(
        id: id,
        startMs: startMs,
        endMs: startMs + bar * 2 - 100,
        chord: chord,
        confidence: 0.8,
      );
  List<ChordCue> part(int firstId, int at, List<String> chords) => <ChordCue>[
        for (var i = 0; i < chords.length; i += 1)
          cue(firstId + i, chords[i], at + i * bar * 2),
      ];
  final cues = <ChordCue>[
    ...part(1, 0, <String>['Em', 'C', 'D', 'G']),
    ...part(5, 16000, <String>['G', 'C', 'D', 'G']),
    ...part(9, 32000, <String>['Em', 'C', 'D', 'G']),
    ...part(13, 48000, <String>['G', 'C', 'D', 'G']),
    const ChordCue(
      id: 17,
      startMs: 64000,
      endMs: 71900,
      chord: 'Am',
      confidence: 0.8,
    ),
    ...part(18, 72000, <String>['G', 'C', 'D', 'G']),
  ];
  List<TranscriptWord> line(int at) => <TranscriptWord>[
        TranscriptWord(word: 'hold', startMs: at, endMs: at + 400),
        TranscriptWord(word: 'on', startMs: at + 500, endMs: at + 800),
        TranscriptWord(word: 'tight', startMs: at + 1000, endMs: at + 1600),
      ];
  return SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-repeats',
      fileId: 'file',
      storagePath: 'room/song-repeats/reference.m4a',
      displayName: 'Hold On.m4a',
      state: SongAnalysisState.ready,
      durationMs: 90000,
      musicalKey: 'G',
      bpm: 120,
      beatsPerBar: grid ? 4 : null,
      beatsMs: grid
          ? <int>[for (var ms = 0; ms < 90000; ms += 500) ms]
          : const <int>[],
      downbeatsMs: grid
          ? <int>[for (var ms = 0; ms < 90000; ms += bar) ms]
          : const <int>[],
      structureSections: form,
      transcriptText: 'walking home hold on tight hold on tight hold on tight',
      transcriptWords: <TranscriptWord>[
        const TranscriptWord(word: 'walking', startMs: 4000, endMs: 4400),
        const TranscriptWord(word: 'home', startMs: 4500, endMs: 5000),
        ...line(20000),
        ...line(52000),
        ...line(76000),
      ],
    ),
    lyricCues: const <LyricSyncCue>[],
    chordCues: <ChordCue>[
      for (final cue in cues) rewrite == null ? cue : rewrite(cue),
    ],
  );
}
