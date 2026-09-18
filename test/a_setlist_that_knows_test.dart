import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/data/music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/features/rooms/setlist_pack.dart';
import 'package:colabroom/features/workspace/chord_sheet_export.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A setlist that knows each song.
///
/// Every Musician, Same Song, 17 September 2026: a set stored titles and an
/// order, and a gigging band needs what to do with each song — the key it is
/// done in, the tempo, the count-in, the form, how it ends, and a note. Read
/// from the analysis where it exists, overridable by the band on the set and
/// never on the song. And a stand-in's pack: the running order with a chord
/// chart per song, in the keys the set does them in, as one file.
///
/// Three things have to hold. The pack carries a chart per song in the set's
/// key. The fields save, and an empty one means what the song says. And a
/// set is its owner's: somebody else's set refuses the change.

final DateTime _when = DateTime(2026, 9, 18);

SongProject _song(String id, String title, {List<Contribution> lines = const <Contribution>[]}) =>
    SongProject(
      id: id,
      roomId: 'room-1',
      accountId: 'account-1',
      title: title,
      createdAt: _when,
      updatedAt: _when,
      songOrigin: SongOrigin.ours,
      contributions: lines,
    );

Contribution _line(String id, String body, {ContributionKind kind = ContributionKind.lyric}) =>
    Contribution(
      id: id,
      projectId: 'song-1',
      authorId: 'user-1',
      authorName: 'Taylor',
      body: body,
      kind: kind,
      colorValue: 0xFFFF8A4C,
      createdAt: _when,
      position: 1,
    );

/// A recording the analysis heard a key, a beat and two chords in.
SongAnalysisBundle _analysis(
  String id, {
  String? key = 'G',
  double? bpm = 96,
  List<StructureSection> sections = const <StructureSection>[],
}) =>
    SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file-$id',
        storagePath: 'room/$id/reference.wav',
        displayName: 'reference.wav',
        state: SongAnalysisState.ready,
        durationMs: 2400,
        musicalKey: key,
        bpm: bpm,
        beatsPerBar: 4,
        downbeatsMs: const <int>[0, 2500],
        structureSections: sections,
        transcriptWords: const <TranscriptWord>[
          TranscriptWord(word: 'Streetlights', startMs: 0, endMs: 600),
          TranscriptWord(word: 'blur', startMs: 600, endMs: 1200),
          TranscriptWord(word: 'like', startMs: 1200, endMs: 1800),
          TranscriptWord(word: 'rain', startMs: 1800, endMs: 2400),
        ],
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[
        ChordCue(startMs: 0, endMs: 1200, chord: 'G:maj', confidence: 0.9),
        ChordCue(startMs: 1200, endMs: 2400, chord: 'C:maj', confidence: 0.9),
      ],
    );

Setlist _set(List<SetlistSong> songs) => Setlist(
      id: 'set-1',
      ownerId: 'preview-user',
      name: 'Saturday at the Anchor',
      createdAt: _when,
      updatedAt: _when,
      songs: songs,
    );

/// Every chord on a song's chart, as the pack would print it.
List<String> _chartChords(SetlistPackSong song) => <String>[
      for (final line in song.lines)
        ...ChordSheetExport.textLine(
          line,
          transpose: song.facts.transpose,
          musicalKey: song.facts.songKey,
        ).chords.trim().split(RegExp(r'\s+')),
    ].where((chord) => chord.isNotEmpty).toList(growable: false);

void main() {
  group('what the set says, and what the song says when it does not', () {
    test('a blank entry reads the song: its key, its tempo, its bar, its shape', () {
      final facts = setSongFacts(
        const SetlistSong(projectId: 'song-1'),
        _song('song-1', 'Midnight Signal'),
        _analysis('song-1', sections: const <StructureSection>[
          StructureSection(startMs: 0, endMs: 1200, label: 'Verse'),
          StructureSection(startMs: 1200, endMs: 2400, label: 'Chorus'),
        ]),
      );

      expect(facts.key, 'G');
      expect(facts.bpm, 96);
      expect(facts.countIn, 'One bar of 4');
      expect(facts.form, 'Verse · Chorus');
      expect(facts.ending, isNull);
      expect(facts.note, isNull);
      expect(facts.transpose, 0);
      expect(facts.line, 'G · 96 bpm · One bar of 4');
    });

    test('the band\'s key on the song stands in front of the detected one', () {
      final facts = setSongFacts(
        null,
        _song('song-1', 'Midnight Signal').copyWith(keyOverride: 'D major'),
        _analysis('song-1', key: 'G'),
      );
      expect(facts.key, 'D major');
      expect(facts.songKey, 'D major');
    });

    test('what the band wrote on the set stands in front of all of it', () {
      final facts = setSongFacts(
        const SetlistSong(
          projectId: 'song-1',
          key: 'A major',
          bpm: 104,
          countIn: 'Drums, two bars',
          form: 'V · Ch · V · Ch · Br · Ch',
          ending: 'Cold',
          note: 'Straight into the next one',
        ),
        _song('song-1', 'Midnight Signal'),
        _analysis('song-1'),
      );

      expect(facts.key, 'A major');
      expect(facts.bpm, 104);
      expect(facts.countIn, 'Drums, two bars');
      expect(facts.form, 'V · Ch · V · Ch · Br · Ch');
      expect(facts.line, 'A major · 104 bpm · Drums, two bars · Ending: Cold');
      // G up to A is two semitones, which is what the chart moves by. The
      // song's own key is untouched: the set is about the occasion.
      expect(facts.songKey, 'G');
      expect(facts.transpose, 2);
    });

    test('a song with no recording says nothing it does not know', () {
      final facts = setSongFacts(null, _song('song-1', 'Midnight Signal'), null);
      expect(facts.key, isNull);
      expect(facts.bpm, isNull);
      expect(facts.countIn, isNull);
      expect(facts.form, isNull);
      expect(facts.line, isEmpty);
    });

    test('the count-in is not guessed from a recording with no beat', () {
      final facts = setSongFacts(
        null,
        _song('song-1', 'Midnight Signal'),
        _analysis('song-1', bpm: null),
      );
      expect(facts.countIn, isNull);
    });

    test('a set key on a song with no key of its own names the key and moves nothing', () {
      // Chords in an unknown key cannot be moved anywhere honestly; the list
      // still says what key the set does it in.
      final facts = setSongFacts(
        const SetlistSong(projectId: 'song-1', key: 'Bb major'),
        _song('song-1', 'Midnight Signal'),
        _analysis('song-1', key: null),
      );
      expect(facts.key, 'Bb major');
      expect(facts.songKey, isNull);
      expect(facts.transpose, 0);
    });

    test('the form is the sections the band typed before the ones the analysis heard', () {
      final typed = _song('song-1', 'Midnight Signal', lines: <Contribution>[
        _line('s1', 'Intro', kind: ContributionKind.section),
        _line('l1', 'Streetlights blur'),
        _line('s2', '[Chorus]'),
        _line('l2', 'Hold on'),
      ]);
      const heard = <StructureSection>[
        StructureSection(startMs: 0, endMs: 1200, label: 'Verse'),
        StructureSection(startMs: 1200, endMs: 2400, label: 'Chorus', customLabel: 'The big one'),
      ];

      expect(songForm(typed, _analysis('song-1', sections: heard).reference), 'Intro · Chorus');
      expect(songForm(_song('song-1', 'Midnight Signal'), _analysis('song-1', sections: heard).reference),
          'Verse · The big one');
    });

    test('semitones between keys in the same mode count their roots, upward', () {
      expect(semitonesBetweenKeys('G', 'A major'), 2);
      expect(semitonesBetweenKeys('A minor', 'C minor'), 3);
      expect(semitonesBetweenKeys('G major', 'F'), 10);
      expect(semitonesBetweenKeys('A# major', 'Bb'), 0);
      expect(semitonesBetweenKeys(null, 'Bb'), 0);
      expect(semitonesBetweenKeys('G', null), 0);
      expect(semitonesBetweenKeys('Raag Yaman', 'G'), 0);
    });

    test('a key in the other mode is the same chords named another way', () {
      // The relative: the usual way the analyser and a band disagree about a
      // key, and the one the key sheet already names.
      expect(semitonesBetweenKeys('A minor', 'C major'), 0);
      expect(semitonesBetweenKeys('G major', 'E minor'), 0);
      expect(semitonesBetweenKeys('G', 'E minor'), 0);
      // The parallel: the band correcting the mode, not asking for a move.
      expect(semitonesBetweenKeys('A minor', 'A major'), 0);
      expect(semitonesBetweenKeys('G', 'G minor'), 0);
      // Anything else counts a minor key from its relative major, the rule
      // the numbers follow: A minor is C, so D major is up two from it.
      expect(semitonesBetweenKeys('A minor', 'D major'), 2);
      expect(semitonesBetweenKeys('G major', 'Bb minor'), 6);
    });

    test('a set key that is the relative of the song\'s key moves no chords', () {
      final songs = SetlistPack.songs(
        setlist: _set(const <SetlistSong>[SetlistSong(projectId: 'song-1', key: 'E minor')]),
        projects: <SongProject>[_song('song-1', 'Midnight Signal')],
        analyses: <String, SongAnalysisBundle?>{'song-1': _analysis('song-1', key: 'G')},
      );

      expect(songs.single.facts.key, 'E minor');
      expect(songs.single.facts.transpose, 0);
      expect(_chartChords(songs.single), <String>['G', 'C']);
    });

    test('a key the analyser wrote in sharps reads in flats on the set', () {
      final facts = setSongFacts(
        null,
        _song('song-1', 'Midnight Signal'),
        _analysis('song-1', key: 'A# major'),
      );
      expect(facts.key, 'Bb major');
      expect(facts.songKey, 'Bb major');
      expect(facts.line, startsWith('Bb major · '));
    });
  });

  group('the pack has a chart per song, in the set\'s keys', () {
    final projects = <SongProject>[
      _song('song-1', 'Midnight Signal'),
      _song('song-2', 'Weathervane'),
      _song('song-3', 'Not Recorded Yet'),
    ];
    final analyses = <String, SongAnalysisBundle?>{
      'song-1': _analysis('song-1'),
      'song-2': _analysis('song-2'),
      'song-3': null,
    };
    final setlist = _set(const <SetlistSong>[
      SetlistSong(projectId: 'song-1', key: 'A major', note: 'Straight into the next one'),
      SetlistSong(projectId: 'song-2'),
      SetlistSong(projectId: 'song-3', ending: 'Cold'),
    ]);

    test('every song is on the list, and every recorded one has a chart', () {
      final songs = SetlistPack.songs(setlist: setlist, projects: projects, analyses: analyses);

      expect(songs.map((song) => song.project.title),
          <String>['Midnight Signal', 'Weathervane', 'Not Recorded Yet']);
      expect(songs.map((song) => song.hasChart), <bool>[true, true, false]);
    });

    test('the chart is moved into the key the set does the song in', () {
      final songs = SetlistPack.songs(setlist: setlist, projects: projects, analyses: analyses);

      // G and C, up two to A and D, on the song the set does in A.
      expect(_chartChords(songs[0]), <String>['A', 'D']);
      // And left alone on the one the set says nothing about.
      expect(_chartChords(songs[1]), <String>['G', 'C']);
    });

    test('the chart is headed with the key the set does the song in, as written', () {
      // A song heard in G, done in E minor: no chord moves, and the header
      // has to say what the running order says rather than "Key of G".
      expect(
        ChordSheetExport.chartFacts(transpose: 0, musicalKey: 'G', keyLabel: 'E minor', bpm: 96),
        <String>['Key of E minor', '96 bpm'],
      );
      // The song's own print still names the moved key.
      expect(
        ChordSheetExport.chartFacts(transpose: 2, musicalKey: 'G'),
        <String>['Key of A'],
      );
      // A blank label is no label.
      expect(
        ChordSheetExport.chartFacts(transpose: 0, musicalKey: 'G', keyLabel: ' '),
        <String>['Key of G'],
      );
    });

    test('the file is the running order, then one chart per song', () async {
      final songs = SetlistPack.songs(setlist: setlist, projects: projects, analyses: analyses);
      final document = SetlistPack.document(setlist, songs);

      expect(await document.save(), isNotEmpty);
      // One page of running order, and a chart for each of the two songs
      // that have one. The third is on the list and nowhere else.
      expect(document.document.pdfPageList.pages.length, 3);
    });

    test('the text a dep gets by message carries the facts', () {
      final songs = SetlistPack.songs(setlist: setlist, projects: projects, analyses: analyses);
      final text = SetlistPack.text(setlist, songs);

      expect(text, startsWith('Saturday at the Anchor\n'));
      expect(text, contains('1. Midnight Signal — A major · 96 bpm · One bar of 4\n'
          '   Straight into the next one\n'));
      expect(text, contains('2. Weathervane — G · 96 bpm · One bar of 4\n'));
      expect(text, contains('3. Not Recorded Yet — Ending: Cold'));
      expect(text, isNot(contains('Form:')), reason: 'no song here has a shape to print');
    });

    test('a set of songs with nothing on their sheets still prints', () async {
      final bare = SetlistPack.songs(
        setlist: _set(const <SetlistSong>[SetlistSong(projectId: 'song-3')]),
        projects: <SongProject>[projects[2]],
        analyses: const <String, SongAnalysisBundle?>{},
      );
      final document = SetlistPack.document(_set(const <SetlistSong>[]), bare);
      expect(await document.save(), isNotEmpty);
      expect(document.document.pdfPageList.pages.length, 1);
    });
  });

  group('the fields save', () {
    test('what the band wrote comes back, and an empty field means the song', () async {
      final repository = InMemoryMusicRepository.seeded();
      final set = await repository.createSetlist('Saturday');
      await repository.addProjectsToSetlist(set, <String>['song-1']);
      final held = (await repository.loadSetlists()).single;
      expect(held.songFor('song-1')!.isBlank, isTrue, reason: 'a song arrives saying nothing');

      await repository.saveSetlistSong(
        held,
        const SetlistSong(
          projectId: 'song-1',
          key: ' Bb major ',
          bpm: 92,
          countIn: '  Drums,  two bars ',
          form: '',
          ending: 'Cold',
          note: '   ',
        ),
      );

      final saved = (await repository.loadSetlists()).single.songFor('song-1')!;
      expect(saved.key, 'Bb major');
      expect(saved.bpm, 92);
      expect(saved.countIn, 'Drums, two bars');
      expect(saved.form, isNull, reason: 'empty means what the song says');
      expect(saved.ending, 'Cold');
      expect(saved.note, isNull, reason: 'blank means what the song says');

      // Adding again and reordering keep what was said.
      final current = (await repository.loadSetlists()).single;
      await repository.addProjectsToSetlist(current, <String>['song-1']);
      final again = (await repository.loadSetlists()).single;
      await repository.reorderSetlistProjects(again, again.projectIds.reversed.toList());
      expect((await repository.loadSetlists()).single.songFor('song-1')!.key, 'Bb major');
    });

    test('a key nothing can read, or a tempo nothing can count at, is refused', () {
      const entry = SetlistSong(projectId: 'song-1');
      expect(() => entry.copyWith(key: 'Mixolydian').cleaned(), throwsArgumentError);
      expect(() => entry.copyWith(key: 'H major').cleaned(), throwsArgumentError);
      expect(() => entry.copyWith(bpm: 300.0).cleaned(), throwsArgumentError);
      expect(() => entry.copyWith(bpm: 12.0).cleaned(), throwsArgumentError);
      expect(() => entry.copyWith(note: 'x' * 201).cleaned(), throwsArgumentError);
      // The shapes 0157 accepts.
      for (final key in <String>['G', 'Bb', 'F# minor', 'Eb major']) {
        expect(entry.copyWith(key: key).cleaned().key, key);
      }
    });

    test('the controller saves through the repository and reloads', () async {
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final set = await controller.createSetlist('Saturday');
      await controller.addProjectsToSetlist(set, <String>['song-1']);

      await controller.saveSetlistSong(
        controller.setlistById(set.id)!,
        const SetlistSong(projectId: 'song-1', key: 'A major', note: 'Straight into the next one'),
      );

      final saved = controller.setlistById(set.id)!.songFor('song-1')!;
      expect(saved.key, 'A major');
      expect(saved.note, 'Straight into the next one');
    });
  });

  group('a set is its owner\'s', () {
    test('somebody else\'s set refuses the change, with a sentence', () async {
      final repository = InMemoryMusicRepository.seeded();
      final theirs = Setlist(
        id: 'set-theirs',
        ownerId: 'somebody-else',
        name: 'Their Saturday',
        createdAt: _when,
        updatedAt: _when,
        songs: const <SetlistSong>[SetlistSong(projectId: 'song-1')],
      );

      await expectLater(
        repository.saveSetlistSong(theirs, const SetlistSong(projectId: 'song-1', note: 'Faster')),
        throwsA(isA<StateError>().having((error) => error.message, 'message', MusicRepository.notYourSet)),
      );
    });

    test('a song that is not in the set cannot be written to it', () async {
      final repository = InMemoryMusicRepository.seeded();
      final set = await repository.createSetlist('Saturday');
      await expectLater(
        repository.saveSetlistSong(set, const SetlistSong(projectId: 'song-1', note: 'Faster')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('on the page', () {
    Future<(MusicBetaController, String)> open(WidgetTester tester) async {
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final set = await controller.createSetlist('Saturday at the Anchor');
      await controller.addProjectsToSetlist(set, <String>['song-1']);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SetlistDetailScreen(
            setlistId: set.id,
            loadAnalysis: (projectId) async => _analysis(projectId),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (controller, set.id);
    }

    testWidgets('each song says what the band does with it, from the recording first',
        (tester) async {
      await open(tester);

      expect(find.text('G · 96 bpm · One bar of 4'), findsOneWidget);
      expect(find.byKey(const Key('set_song_song-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picking a key and writing a note lands on the set, not the song',
        (tester) async {
      final (controller, id) = await open(tester);

      await tester.tap(find.byKey(const Key('set_song_song-1')));
      await tester.pumpAndSettle();
      // The hints say what the song says.
      expect(find.text("The song's key is G."), findsOneWidget);
      await tester.tap(find.byKey(const Key('set_key_Bb')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('set_song_note')));
      await tester.enterText(find.byKey(const Key('set_song_note')), 'Straight into the next one');
      await tester.ensureVisible(find.byKey(const Key('set_song_save')));
      await tester.tap(find.byKey(const Key('set_song_save')));
      await tester.pumpAndSettle();

      final saved = controller.setlistById(id)!.songFor('song-1')!;
      expect(saved.key, 'Bb major');
      expect(saved.note, 'Straight into the next one');
      expect(controller.projectById('song-1')!.keyOverride, isNull,
          reason: 'the set is about the occasion; the song keeps its key');
      expect(find.text('Bb major · 96 bpm · One bar of 4'), findsOneWidget);
      expect(find.text('Straight into the next one'), findsOneWidget);
    });

    testWidgets('saying only "minor" starts from the song\'s own root', (tester) async {
      final (controller, id) = await open(tester);

      await tester.tap(find.byKey(const Key('set_song_song-1')));
      await tester.pumpAndSettle();
      // The song is in G. Minor before any root is G minor, not C minor.
      await tester.tap(find.byKey(const Key('set_key_minor')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('set_song_save')));
      await tester.tap(find.byKey(const Key('set_song_save')));
      await tester.pumpAndSettle();

      expect(controller.setlistById(id)!.songFor('song-1')!.key, 'G minor');
      // The parallel of the song's key: the chart is not moved by it.
      expect(find.text('G minor · 96 bpm · One bar of 4'), findsOneWidget);
    });

    testWidgets('a tempo that is not a number is refused on the sheet', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const Key('set_song_song-1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('set_song_bpm')));
      await tester.enterText(find.byKey(const Key('set_song_bpm')), 'fast');
      await tester.ensureVisible(find.byKey(const Key('set_song_save')));
      await tester.tap(find.byKey(const Key('set_song_save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('set_song_refused')), findsOneWidget);
      expect(find.byKey(const Key('set_song_save')), findsOneWidget, reason: 'the sheet stays open');
    });

    testWidgets('the menu offers the printer and the PDF', (tester) async {
      await open(tester);

      await tester.tap(find.byTooltip('Setlist options'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print_set')), findsOneWidget);
      expect(find.byKey(const Key('share_set_pdf')), findsOneWidget);
    });
  });
}
