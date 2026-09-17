import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/moment_note.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/moment_notes.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/timeline_ruler.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A note pinned to a moment in a recording (0141).
///
/// Every Musician, Same Song, 17 September 2026. Until now a comment could
/// only attach to a lyric line, so the one thing anybody says about a
/// recording — "breathe before mio", "you rushed into the turnaround" — had
/// nowhere to say *where*.
///
/// The rules worth holding, and what breaks if they slip:
///
/// - The moment is decided by the playhead before anybody types. A note box
///   that asks for a time is a form, and nobody fills it in.
/// - Tapping a note plays from three seconds before it. A note about a breath
///   is unhearable from the breath.
/// - Nobody is offered the chance to pin a note on somebody else's unshared
///   take. The database refuses it (0057 says only its recorder can hear it),
///   so offering the action would be offering a failure.

/// The song's takes, as the screen asks for them.
class _Takes extends SongLayerService {
  _Takes(this.layers) : super(client: null);

  final List<SharedLayer> layers;

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async => layers;

  @override
  Future<String> ensureLocal(SharedLayer layer) async => '/tmp/${layer.id}.m4a';

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _NoAnalysis extends SongAnalysisService {
  _NoAnalysis() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
}

/// An inbox with one note notification in it.
class _ToldAboutANote extends InMemoryMusicRepository {
  _ToldAboutANote() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<AppNotification>> loadNotifications() async => <AppNotification>[
        AppNotification(
          id: 'notif-note',
          type: NotificationType.momentNote,
          title: 'Jess left a note at 1:48',
          body: 'breathe before mio',
          createdAt: DateTime.now(),
          roomId: 'room-1',
          projectId: 'song-1',
          actorId: 'preview-jess',
        ),
      ];
}

/// A song somebody else has already pinned notes on.
///
/// [InMemoryMusicRepository.addMomentNote] always signs the note with whoever
/// is signed in, which is the only honest thing it can do — so a note from
/// Jess is seeded rather than written.
class _NotesAlreadyThere extends InMemoryMusicRepository {
  _NotesAlreadyThere(this.alreadyThere)
      : super.from(InMemoryMusicRepository.seeded());

  final List<MomentNote> alreadyThere;

  @override
  Future<List<MomentNote>> loadMomentNotes(String projectId) async {
    return <MomentNote>[
      for (final note in alreadyThere)
        if (note.projectId == projectId) note,
      ...await super.loadMomentNotes(projectId),
    ]..sort((a, b) => a.atMs.compareTo(b.atMs));
  }
}

MomentNote _note({
  required String id,
  required int atMs,
  required String body,
  String authorId = 'preview-jess',
  String? authorName = 'Jess',
  String? layerId = 'layer-sent',
  bool onSharedTake = true,
  DateTime? createdAt,
}) {
  return MomentNote(
    id: id,
    projectId: 'song-1',
    layerId: layerId,
    atMs: atMs,
    body: body,
    authorId: authorId,
    authorName: authorName,
    onSharedTake: onSharedTake,
    createdAt: createdAt ?? DateTime(2026, 9, 17),
  );
}

SharedLayer _layer({
  required String id,
  required String label,
  required String recordedBy,
  bool shared = true,
}) {
  return SharedLayer(
    id: id,
    projectId: 'song-1',
    recordedBy: recordedBy,
    storagePath: 'room-1/song-1/layers/$id.m4a',
    label: label,
    part: TakePart.other,
    durationMs: 200000,
    createdAt: DateTime(2026, 9, 17),
    sharedAt: shared ? DateTime(2026, 9, 17) : null,
  );
}

Future<MusicBetaController> _openTakes(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  required List<SharedLayer> layers,
  NoteToOpen? openNote,
  bool sideways = false,
}) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize =
      sideways ? const Size(1000, 460) : const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongLayersScreen(
        roomId: 'room-1',
        projectId: 'song-1',
        songTitle: 'Caro mio ben',
        layerService: _Takes(layers),
        analysisService: _NoAnalysis(),
        openNote: openNote,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('the moment a note is about', () {
    test('plays from three seconds before it, and loops the moment', () {
      final note = MomentNote(
        id: 'n',
        projectId: 'song-1',
        atMs: 108000,
        body: 'breathe before mio',
        authorId: 'preview-jess',
        createdAt: DateTime(2026, 9, 17),
      );
      expect(note.clock, '1:48');
      expect(note.playFromMs, 105000, reason: 'a note at 1:48 plays from 1:45');
      expect(note.loopEndMs, 116000, reason: '1:45 to 1:56, as the plan says');
      expect(note.isRange, isFalse);
    });

    test('a note near the top plays from the top rather than before it', () {
      final note = MomentNote(
        id: 'n',
        projectId: 'song-1',
        atMs: 900,
        body: 'count it in',
        authorId: 'preview-user',
        createdAt: DateTime(2026, 9, 17),
      );
      expect(note.playFromMs, 0);
      expect(note.clock, '0:00');
    });

    test('a range loops to its own end', () {
      final note = MomentNote(
        id: 'n',
        projectId: 'song-1',
        atMs: 21000,
        endMs: 27000,
        body: 'legato through here',
        authorId: 'preview-user',
        createdAt: DateTime(2026, 9, 17),
      );
      expect(note.isRange, isTrue);
      expect(note.playFromMs, 18000);
      expect(note.loopEndMs, 27000);
    });
  });

  group('finding the note a notification was about', () {
    final jess = _note(
      id: 'from-jess',
      atMs: 108000,
      body: 'breathe before mio',
      createdAt: DateTime(2026, 9, 17, 10),
    );
    final sam = _note(
      id: 'from-sam',
      atMs: 12000,
      body: 'the piano is loud here',
      authorId: 'preview-sam',
      authorName: 'Sam',
      createdAt: DateTime(2026, 9, 17, 11),
    );
    final mine = _note(
      id: 'from-me',
      atMs: 1000,
      body: 'my own words',
      authorId: 'preview-user',
      authorName: 'Taylor',
      createdAt: DateTime(2026, 9, 17, 12),
    );
    final notes = <MomentNote>[jess, sam, mine];

    test('is the one the card named, not the newest one', () {
      const card = NoteToOpen(
        authorId: 'preview-jess',
        bodyStart: 'breathe before mio',
      );
      expect(card.findIn(notes, exceptAuthor: 'preview-user')?.id, jess.id);
    });

    test('is never your own', () {
      const card = NoteToOpen(authorId: 'preview-user');
      expect(card.findIn(<MomentNote>[mine], exceptAuthor: 'preview-user'),
          isNull);
    });

    test('falls back to the newest by that person when the words are gone',
        () {
      // A note taken back between the notification and the tap, or words the
      // card truncated somewhere this does not reach. Landing near it beats
      // landing nowhere: the person tapped a card that said somebody left
      // them a note.
      const card = NoteToOpen(
        authorId: 'preview-jess',
        bodyStart: 'something else entirely',
      );
      expect(card.findIn(notes, exceptAuthor: 'preview-user')?.id, jess.id);
    });

    test('falls back to the newest of anybody when the person is gone', () {
      const card = NoteToOpen(authorId: 'preview-nobody');
      expect(card.findIn(notes, exceptAuthor: 'preview-user')?.id, sam.id);
    });
  });

  group('the notes on a song', () {
    test('come back in the order they happen, not the order they were typed',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.addMomentNote(
        projectId: 'song-1',
        layerId: 'layer-sent',
        atMs: 108000,
        body: 'breathe before mio',
      );
      await repository.addMomentNote(
        projectId: 'song-1',
        layerId: 'layer-sent',
        atMs: 4000,
        body: 'the bridge fell apart',
      );

      final notes = await repository.loadMomentNotes('song-1');
      expect(notes.map((note) => note.atMs), <int>[4000, 108000]);
    });

    test('a note on one song is not a note on another', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.addMomentNote(
        projectId: 'song-1',
        atMs: 1000,
        body: 'here',
      );
      expect(await repository.loadMomentNotes('song-2'), isEmpty);
    });

    test('the author can take their own words back', () async {
      final repository = InMemoryMusicRepository.seeded();
      final note = await repository.addMomentNote(
        projectId: 'song-1',
        atMs: 1000,
        body: 'said too much',
      );
      await repository.deleteMomentNote(note);
      expect(await repository.loadMomentNotes('song-1'), isEmpty);
    });
  });

  group('pinning one', () {
    testWidgets('the button says where it will land', (tester) async {
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      // The playhead has not moved, so the note would land at the top. The
      // label is the moment: an unlabelled note button at 2:40 looks exactly
      // like one at 0:00, which is the same argument the record button makes.
      expect(find.text('Note at 0:00'), findsOneWidget);
    });

    testWidgets('typing one puts it on the song and in the list',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await _openTakes(
        tester,
        repository,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      await tester.tap(find.byKey(const Key('pin_moment_note')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('moment_note_body')), 'breathe before mio');
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      final notes = await repository.loadMomentNotes('song-1');
      expect(notes, hasLength(1));
      expect(notes.single.body, 'breathe before mio');
      expect(notes.single.layerId, 'layer-sent',
          reason: 'a note has to be about one recording');
      expect(find.text('breathe before mio'), findsOneWidget,
          reason: 'the note joins the list under the takes');
    });

    testWidgets('an empty note is not a note', (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      await _openTakes(
        tester,
        repository,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      await tester.tap(find.byKey(const Key('pin_moment_note')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      expect(await repository.loadMomentNotes('song-1'), isEmpty);
    });

    testWidgets('there is nothing to pin on somebody else\'s draft',
        (tester) async {
      // 0057: an unshared take is heard by whoever recorded it and by nobody
      // else, so there is nobody to say anything to about it and the insert
      // policy would refuse the row. The action is not offered rather than
      // offered and then failed.
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(
            id: 'layer-draft',
            label: 'Draft',
            recordedBy: 'preview-jess',
            shared: false,
          ),
        ],
      );

      expect(find.byKey(const Key('pin_moment_note')), findsNothing);
      expect(find.textContaining('Note at'), findsNothing);
    });

    testWidgets('a draft of your own can be noted on', (tester) async {
      // Marking your own second verse is the same object as a teacher
      // answering a take, and nobody else can read it either way.
      //
      // Sideways, which is the console. Not for the console's sake: a lane
      // for your own unshared take overflows its 104-pixel header by 52
      // pixels — three buttons, "only you" and Share do not fit and never
      // have — which is a layout bug this slice did not cause and is not the
      // place to fix. The bottom bar, where the note button lives, is the
      // same in both orientations.
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        sideways: true,
        layers: <SharedLayer>[
          _layer(
            id: 'layer-mine',
            label: 'Mine',
            recordedBy: 'preview-user',
            shared: false,
          ),
        ],
      );

      expect(find.byKey(const Key('pin_moment_note')), findsOneWidget);
    });

    testWidgets('and the sheet says who will ever read it', (tester) async {
      // The promise has to be made before the words are typed, because it
      // cannot be taken back afterwards. A note on a take nobody has heard is
      // its author's alone — and stays theirs when they share the take, or
      // pressing Share would hand the room every private note on that
      // recording at once (0141's on_shared_take).
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        // Sideways, to dodge the same pre-existing lane overflow the test
        // above explains.
        sideways: true,
        layers: <SharedLayer>[
          _layer(
            id: 'layer-mine',
            label: 'Mine',
            recordedBy: 'preview-user',
            shared: false,
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('pin_moment_note')));
      await tester.pumpAndSettle();

      expect(
        find.text('Only you can read this one, even after you share the take.'),
        findsOneWidget,
      );
    });

    testWidgets('a note on a draft says so in the list', (tester) async {
      final repository = InMemoryMusicRepository.seeded()
        ..draftLayerIds.add('layer-mine');
      await _openTakes(
        tester,
        repository,
        sideways: true,
        layers: <SharedLayer>[
          _layer(
            id: 'layer-mine',
            label: 'Mine',
            recordedBy: 'preview-user',
            shared: false,
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('pin_moment_note')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('moment_note_body')), 'came in flat, redo it');
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      expect(find.text('came in flat, redo it'), findsOneWidget);
      // Otherwise a note you wrote to yourself sits in the list looking
      // exactly like one the band can read.
      expect(find.textContaining('only you'), findsWidgets);
    });

    testWidgets('the sheet offers the recordings you can be heard on, only',
        (tester) async {
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
          _layer(id: 'layer-heard', label: 'Heard', recordedBy: 'preview-user'),
          _layer(
            id: 'layer-draft',
            label: 'Draft',
            recordedBy: 'preview-jess',
            shared: false,
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('pin_moment_note')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ChoiceChip, 'Sent'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Heard'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Draft'), findsNothing,
          reason: 'nobody else can hear it, so there is nobody to tell');
    });
  });

  group('sideways, at the faders', () {
    testWidgets('the notes come too', (tester) async {
      // A teacher turns the phone to reach the faders while a student's take
      // plays. Pinning already worked here, because the button is in the
      // bottom bar -- but until the list came with it there was no way to
      // read a note back, hear its moment again, or take one back.
      await _openTakes(
        tester,
        _NotesAlreadyThere(<MomentNote>[
          _note(id: 'from-jess', atMs: 108000, body: 'breathe before mio'),
        ]),
        sideways: true,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      expect(find.text('breathe before mio'), findsOneWidget);

      await tester.tap(find.byKey(const Key('moment_note_from-jess')));
      await tester.pumpAndSettle();

      expect(find.text('Note at 1:45'), findsOneWidget,
          reason: 'tapping a note sideways moves to its moment too');
    });
  });

  group('playing one', () {
    testWidgets('tapping a note moves the playhead to three seconds before it',
        (tester) async {
      final repository = InMemoryMusicRepository.seeded();
      final note = await repository.addMomentNote(
        projectId: 'song-1',
        layerId: 'layer-sent',
        atMs: 108000,
        body: 'breathe before mio',
      );
      await _openTakes(
        tester,
        repository,
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      expect(find.text('breathe before mio'), findsOneWidget);
      await tester.tap(find.byKey(Key('moment_note_${note.id}')));
      await tester.pumpAndSettle();

      // There is no audio device in a test, so what is asserted is the thing
      // the screen shows: the playhead is at 1:45, which is where the note's
      // loop begins and where the next press of play starts.
      expect(find.text('Note at 1:45'), findsOneWidget);
    });

    testWidgets('the notification opens the takes at the note', (tester) async {
      final repository = _ToldAboutANote();
      final controller = MusicBetaController(repository);
      await controller.load();
      addTearDown(controller.dispose);

      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final pushed = <String?>[];
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          navigatorObservers: <NavigatorObserver>[_Watch(pushed)],
          home: const NotificationsScreen(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 120));

      await tester.tap(find.text('Jess left a note at 1:48'));
      await tester.pumpAndSettle();

      expect(pushed, contains('/song/song-1/takes'),
          reason: 'the note is on a recording, so the takes are where it is');
      expect(find.byType(SongLayersScreen), findsOneWidget);
      // And on the song it is about, not on whichever song was open, carrying
      // the address of the note itself: who left it and what they said.
      final opened =
          tester.widget<SongLayersScreen>(find.byType(SongLayersScreen)).openNote;
      expect(opened?.authorId, 'preview-jess');
      expect(opened?.bodyStart, 'breathe before mio');
    });

    testWidgets('and lands on that note, not on whichever was newest',
        (tester) async {
      // Two people pin on the same song in the same minute. The card says who
      // and what, which is enough to tell them apart -- `notifications` has no
      // column for the thing it is about, so this is the whole address there
      // is.
      await _openTakes(
        tester,
        _NotesAlreadyThere(<MomentNote>[
          _note(
            id: 'from-jess',
            atMs: 108000,
            body: 'breathe before mio',
            createdAt: DateTime(2026, 9, 17, 10),
          ),
          // Newer, and by somebody else again: the one the old rule would
          // have opened on.
          _note(
            id: 'from-sam',
            atMs: 12000,
            body: 'the piano is loud here',
            authorId: 'preview-sam',
            authorName: 'Sam',
            createdAt: DateTime(2026, 9, 17, 11),
          ),
        ]),
        openNote: const NoteToOpen(
          authorId: 'preview-jess',
          bodyStart: 'breathe before mio',
        ),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      expect(find.text('Note at 1:45'), findsOneWidget,
          reason: 'the note the card was about, not the newest on the song');
    });

    testWidgets('and stays where you go next', (tester) async {
      // Arriving is a one-off. Every pin and every delete reloads the notes,
      // and without a latch each reload would drag the playhead back to the
      // note the notification was about -- you answer at 0:59, press Pin it,
      // and the screen throws you back to 1:45.
      await _openTakes(
        tester,
        _NotesAlreadyThere(<MomentNote>[
          _note(id: 'from-jess', atMs: 108000, body: 'breathe before mio'),
        ]),
        openNote: const NoteToOpen(
          authorId: 'preview-jess',
          bodyStart: 'breathe before mio',
        ),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );
      expect(find.text('Note at 1:45'), findsOneWidget);

      // Somewhere else in the song, which is what a person does before they
      // answer.
      await tester.tap(find.byType(TimelineRuler));
      await tester.pumpAndSettle();
      expect(find.text('Note at 1:45'), findsNothing);

      await tester.tap(find.byKey(const Key('pin_moment_note')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('moment_note_body')), 'yes, I hear it');
      await tester.tap(find.byKey(const Key('moment_note_pin')));
      await tester.pumpAndSettle();

      expect(find.text('yes, I hear it'), findsOneWidget);
      expect(find.text('Note at 1:45'), findsNothing,
          reason: 'pinning a reply does not throw you back to the first note');
    });
  });

  group('N, where there is a keyboard', () {
    testWidgets('pins at the playhead', (tester) async {
      var pinned = 0;
      await tester.pumpWidget(MaterialApp(
        home: PinAtPlayheadKey(
          onKeyboard: true,
          onPin: () => pinned += 1,
          child: const SizedBox.expand(),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();

      expect(pinned, 1);
    });

    testWidgets('and leaves a phone alone', (tester) async {
      var pinned = 0;
      await tester.pumpWidget(MaterialApp(
        home: PinAtPlayheadKey(
          onKeyboard: false,
          onPin: () => pinned += 1,
          child: const SizedBox.expand(),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();

      expect(pinned, 0);
    });

    testWidgets('the takes screen binds it to the note sheet', (tester) async {
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', label: 'Sent', recordedBy: 'preview-jess'),
        ],
      );

      // The binding itself, rather than the platform test in front of it: a
      // widget test runs as a phone, where N is deliberately nothing.
      tester.widget<PinAtPlayheadKey>(find.byType(PinAtPlayheadKey)).onPin();
      await tester.pumpAndSettle();

      expect(find.text('Note at 0:00'), findsWidgets);
      expect(find.byKey(const Key('moment_note_body')), findsOneWidget);
    });
  });
}

class _Watch extends NavigatorObserver {
  _Watch(this.pushed);

  final List<String?> pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
  }
}
