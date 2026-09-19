import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/deep_link.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/app/routes.dart';
import 'package:colabroom/app/workspace_shell.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/a_moment_from_a_link.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/layers/timeline_ruler.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/incoming_addresses.dart';
import 'package:colabroom/services/moment_link.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A link to one moment of one recording.
///
/// Every Musician, Same Song, 17 September 2026 (schools, item 1): "listen to
/// bar 33" is the sentence a teacher says most, and until now there was no
/// way to say it in writing. A student pastes this into Canvas and a bandmate
/// texts it, and it opens the song at that moment of that take.
///
/// The rules worth holding, and what breaks if they slip:
///
/// - The address is opaque. No title, no name, no room: a link travels
///   through a class list and a group chat, and the only thing it may tell
///   somebody who cannot open it is that they cannot open it.
/// - Membership decides, and there is no third answer. A public page for
///   something inside a room is the thing 0096 exists to prevent, and a
///   preview is a public page with an apology on it.
/// - It lands three seconds early, the way a moment note does. A bar is
///   unhearable from its downbeat; you have to arrive at it.

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

SharedLayer _layer({
  required String id,
  required String recordedBy,
  bool shared = true,
  int durationMs = 200000,
}) {
  return SharedLayer(
    id: id,
    projectId: 'song-1',
    recordedBy: recordedBy,
    storagePath: 'room-1/song-1/layers/$id.m4a',
    label: 'Take',
    part: TakePart.other,
    durationMs: durationMs,
    createdAt: DateTime(2026, 9, 17),
    sharedAt: shared ? DateTime(2026, 9, 17) : null,
  );
}

/// Whatever the app put on the clipboard, and a clipboard that accepts it.
List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map<dynamic, dynamic>)['text'] as String);
    }
    return null;
  });
  addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

Future<MusicBetaController> _openTakes(
  WidgetTester tester,
  InMemoryMusicRepository repository, {
  required List<SharedLayer> layers,
  MomentAddress? openAt,
}) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(420, 1000);
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
        openAt: openAt,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return controller;
}

Future<MusicBetaController> _follow(
  WidgetTester tester,
  MomentAddress at,
) async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: MomentFromALink(at: at),
    ),
  ));
  await tester.pump();
  return controller;
}

void main() {
  group('the address', () {
    test('reads back as the moment it named', () {
      const at = MomentAddress(
        roomId: 'room-1',
        projectId: 'song-1',
        takeId: 'layer-sent',
        atMs: 108000,
      );
      expect(at.path, '/r/room-1/s/song-1?take=layer-sent&at=108000');
      expect(AppRoutes.match(at.path),
          const RouteTarget(RoutePlace.moment, 'song-1', at));
    });

    test('names no take for the song\'s own recording', () {
      const at = MomentAddress(
        roomId: 'room-1',
        projectId: 'song-1',
        atMs: 4000,
      );
      expect(at.path, '/r/room-1/s/song-1?at=4000');
      expect(AppRoutes.match(at.path)?.at, at,
          reason: 'no take is the song itself, the same null a moment note '
              'carries for it');
    });

    test('survives the whole link, the way a phone hands one over', () {
      // App Links give Flutter the address in full. The web gives it a bare
      // path. Both have to read as the same moment.
      final link = momentLink(
        roomId: 'room-1',
        projectId: 'song-1',
        takeId: 'layer-sent',
        atMs: 108000,
      );
      expect(link, 'https://app.colabroom.com/r/room-1/s/song-1'
          '?take=layer-sent&at=108000');
      expect(AppRoutes.match(link)?.at?.atMs, 108000);
      expect(AppRoutes.match(link)?.at?.roomId, 'room-1');
    });

    test('carries nothing but where it points', () {
      final link = momentLink(
        roomId: 'room-1',
        projectId: 'song-1',
        takeId: 'layer-sent',
        atMs: 108000,
      );
      // The song is called Midnight Signal and the room is After Hours
      // Studio. A link that said so would be telling somebody who cannot
      // open it what is inside a room they are not in.
      expect(link.toLowerCase(), isNot(contains('midnight')));
      expect(link.toLowerCase(), isNot(contains('hours')));
      expect(link.toLowerCase(), isNot(contains('taylor')));
    });

    test('a half-typed one names nothing at all', () {
      expect(AppRoutes.match('/r/room-1'), isNull);
      expect(AppRoutes.match('/r/room-1/s'), isNull);
      expect(AppRoutes.match('/r/room-1/songs/song-1'), isNull);
      expect(AppRoutes.match('/r/room-1/s/song-1/take-3'), isNull);
      // A moment with no moment on it is the top of the song, not a refusal
      // to open: a link somebody trimmed still opens the song.
      expect(AppRoutes.match('/r/room-1/s/song-1')?.at?.atMs, 0);
      expect(AppRoutes.match('/r/room-1/s/song-1?at=beetroot')?.at?.atMs, 0);
      expect(AppRoutes.match('/r/room-1/s/song-1?at=-4')?.at?.atMs, 0);
    });

    test('is a route the app can build', () {
      final route = DeepLink.routeFor(
        '/r/room-1/s/song-1?take=layer-sent&at=108000',
        repository: InMemoryMusicRepository.seeded(),
      );
      expect(route, isNotNull);
      expect(route!.settings.name, '/r/room-1/s/song-1?take=layer-sent&at=108000',
          reason: 'the address bar has to keep the moment, or refreshing the '
              'page loses the bar somebody was sent to');
    });
  });

  group('opening one', () {
    testWidgets('lands on the take, three seconds before the moment',
        (tester) async {
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', recordedBy: 'preview-jess'),
        ],
        openAt: const MomentAddress(
          roomId: 'room-1',
          projectId: 'song-1',
          takeId: 'layer-sent',
          atMs: 108000,
        ),
      );

      // There is no audio device in a test, so what is asserted is what the
      // screen shows: the playhead is at 1:45, which is where a note at 1:48
      // starts too, and where the next press of play begins.
      expect(find.text('Note at 1:45'), findsOneWidget);
    });

    testWidgets('and stays there once you have moved on', (tester) async {
      // The takes are read again on a pull, a share and a delete. None of
      // those is somebody asking to go back to the bar they arrived at.
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', recordedBy: 'preview-jess'),
        ],
        openAt: const MomentAddress(
          roomId: 'room-1',
          projectId: 'song-1',
          takeId: 'layer-sent',
          atMs: 108000,
        ),
      );
      expect(find.text('Note at 1:45'), findsOneWidget);

      // Somewhere else in the song, which is what a person does the moment
      // they have heard the bar they were sent.
      await tester.tap(find.byType(TimelineRuler));
      await tester.pumpAndSettle();
      expect(find.text('Note at 1:45'), findsNothing);

      // And the takes are read again: a pull, a share, a take put away.
      await tester.drag(find.byType(RefreshIndicator), const Offset(0, 320));
      await tester.pumpAndSettle();

      expect(find.text('Note at 1:45'), findsNothing,
          reason: 'the playhead is where the person left it; a reload that '
              'drags it back to 1:45 is the link firing twice');
    });

    testWidgets('a member lands in the song itself', (tester) async {
      await _follow(
        tester,
        const MomentAddress(
          roomId: 'room-1',
          projectId: 'song-1',
          takeId: 'layer-sent',
          atMs: 108000,
        ),
      );

      final takes =
          tester.widget<SongLayersScreen>(find.byType(SongLayersScreen));
      expect(takes.projectId, 'song-1');
      expect(takes.openAt?.atMs, 108000);
      expect(takes.openAt?.takeId, 'layer-sent');
    });

    testWidgets('and so does one tapped while the app is already open',
        (tester) async {
      // Exactly what a phone pushes at a running app. The moment rides in
      // the query, and the shell used to read `Uri.path`, which drops it:
      // the link opened the song at the top instead of at the bar it named.
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
          MaterialApp(home: WorkspaceShell(controller: controller)));
      await tester.pump(const Duration(milliseconds: 200));

      await IncomingAddresses().didPushRouteInformation(RouteInformation(
        uri: Uri.parse('https://app.colabroom.com/r/room-1/s/song-1'
            '?take=layer-sent&at=108000'),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final takes =
          tester.widget<SongLayersScreen>(find.byType(SongLayersScreen));
      expect(takes.openAt?.atMs, 108000);
      expect(takes.openAt?.takeId, 'layer-sent');
    });

    testWidgets('somebody who is not in the room is told only that',
        (tester) async {
      await _follow(
        tester,
        const MomentAddress(
          roomId: 'room-elsewhere',
          projectId: 'song-elsewhere',
          atMs: 108000,
        ),
      );

      expect(find.text('This is inside a room you are not in.'), findsOneWidget);
      expect(find.byType(SongLayersScreen), findsNothing,
          reason: 'no preview: there is no public page for anything inside a '
              'room (0096)');
      // Not even the address read back at them. The ids are the only facts a
      // stranger's copy of this screen has, and they are facts about a room
      // this person is not in.
      expect(find.textContaining('song-elsewhere'), findsNothing);
      expect(find.textContaining('room-elsewhere'), findsNothing);
    });

    testWidgets('and so is a link that names the wrong room', (tester) async {
      // A song this person can open, under a room it is not in. Letting the
      // address answer anyway would make the room in it decoration.
      await _follow(
        tester,
        const MomentAddress(
          roomId: 'room-2',
          projectId: 'song-1',
          atMs: 1000,
        ),
      );

      expect(find.text('This is inside a room you are not in.'), findsOneWidget);
      expect(find.byType(SongLayersScreen), findsNothing);
    });
  });

  group('making one', () {
    testWidgets('at the playhead, naming the take you are hearing',
        (tester) async {
      final copied = _clipboard(tester);
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-sent', recordedBy: 'preview-jess'),
        ],
        openAt: const MomentAddress(
          roomId: 'room-1',
          projectId: 'song-1',
          takeId: 'layer-sent',
          atMs: 108000,
        ),
      );

      await tester.tap(find.byKey(const Key('copy_link_to_playhead')));
      await tester.pumpAndSettle();

      expect(copied, <String>[
        'https://app.colabroom.com/r/room-1/s/song-1'
            '?take=layer-sent&at=105000',
      ]);
      expect(find.text('Link copied. It opens for people in this room.'),
          findsOneWidget);
    });

    testWidgets('never naming a take the room cannot hear', (tester) async {
      // A take of your own that nobody has been sent is audible to you alone
      // (0057). A link naming it would open on a lane that is not there.
      final copied = _clipboard(tester);
      await _openTakes(
        tester,
        InMemoryMusicRepository.seeded(),
        layers: <SharedLayer>[
          _layer(id: 'layer-mine', recordedBy: 'preview-user', shared: false),
        ],
        openAt: const MomentAddress(
          roomId: 'room-1',
          projectId: 'song-1',
          atMs: 20000,
        ),
      );

      await tester.tap(find.byKey(const Key('copy_link_to_playhead')));
      await tester.pumpAndSettle();

      expect(copied.single, isNot(contains('take=')));
      expect(copied.single, contains('at=17000'));
    });

    testWidgets('and the button fits a small phone', (tester) async {
      // The row where a moment's other two buttons live had half a pixel to
      // spare at 360 wide -- a_sealed_take measures exactly that -- so this
      // one is a line of its own rather than a third button on that row.
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SongLayersScreen(
            roomId: 'room-1',
            projectId: 'song-1',
            songTitle: 'Caro mio ben',
            layerService: _Takes(<SharedLayer>[
              _layer(id: 'layer-sent', recordedBy: 'preview-jess'),
            ]),
            analysisService: _NoAnalysis(),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('copy_link_to_playhead')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('in Perform, where the song is now', (tester) async {
      // No take: what plays in Perform is the song, the recording everybody
      // in the room hears, and the moment is a moment of it.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final copied = _clipboard(tester);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: SongProject(
            id: 'song-bars',
            roomId: 'room-1',
            accountId: 'preview-user',
            title: 'Weathervane',
            createdAt: DateTime(2026, 9, 17),
            updatedAt: DateTime(2026, 9, 17),
            contributions: <Contribution>[
              Contribution(
                id: 'line-1',
                projectId: 'song-bars',
                authorId: 'preview-jess',
                authorName: 'Jess',
                body: 'Turning in the wind',
                colorValue: 0xFFFF8A4C,
                createdAt: DateTime(2026, 9, 17),
                position: 1,
              ),
            ],
          ),
          analysis: const SongAnalysisBundle(
            reference: ReferenceTrack(
              projectId: 'song-bars',
              fileId: 'file',
              storagePath: 'room-1/song-bars/reference.m4a',
              displayName: 'Weathervane.m4a',
              state: SongAnalysisState.ready,
              durationMs: 6000,
              transcriptText: 'turning in the wind',
              transcriptWords: <TranscriptWord>[
                TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
                TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
              ],
            ),
            lyricCues: <LyricSyncCue>[],
            chordCues: <ChordCue>[],
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(find.byKey(const Key('live_copy_moment')));
      await tester.tap(find.byKey(const Key('live_copy_moment')));
      await tester.pumpAndSettle();

      expect(copied, <String>['https://app.colabroom.com/r/room-1/s/song-bars?at=0']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a note, at the moment the note is about', (tester) async {
      final copied = _clipboard(tester);
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
          _layer(id: 'layer-sent', recordedBy: 'preview-jess'),
        ],
      );

      expect(find.text('breathe before mio'), findsOneWidget);
      await tester.tap(find.byKey(Key('copy_link_to_note_${note.id}')));
      await tester.pumpAndSettle();

      expect(copied, <String>[
        'https://app.colabroom.com/r/room-1/s/song-1'
            '?take=layer-sent&at=108000',
      ], reason: 'the note\'s own moment, not the playhead\'s');
    });
  });

  // The half that is not Dart talking to Dart: what has to be true before an
  // address the app writes ever reaches the app at all.
  group('reaching the app', () {
    setUp(IncomingAddresses.reset);
    tearDown(IncomingAddresses.reset);

    const at = MomentAddress(
      roomId: 'room-1',
      projectId: 'song-1',
      takeId: 'layer-sent',
      atMs: 108000,
    );

    test('in a browser, read off the address bar and not the hash', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      // The web build uses Flutter's default hash URL strategy, so the
      // engine reports whatever follows `#` -- and a link somebody was sent
      // has no `#` in it. Asked only the engine, the app opened Home.
      expect(
        DeepLink.initialRoute(
          WidgetsBinding.instance,
          onWeb: true,
          browserAddress: Uri.parse('https://app.colabroom.com${at.path}'),
        ),
        at.path,
      );
    });

    test('and the root is still the root, query and all', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      // Where a password reset, a confirmed account and ?deleteAccount=1 all
      // land. None of them is a place, and reading one as a path would open
      // a screen instead of doing the thing.
      for (final address in <String>[
        'https://app.colabroom.com/',
        'https://app.colabroom.com/?deleteAccount=1',
        'https://app.colabroom.com/?code=abc123',
      ]) {
        expect(
          DeepLink.initialRoute(WidgetsBinding.instance,
              onWeb: true, browserAddress: Uri.parse(address)),
          '/',
        );
      }
    });

    test('and a link that was waiting still goes first', () async {
      final waiting = Uri.parse('https://app.colabroom.com${at.path}');
      await IncomingAddresses()
          .didPushRouteInformation(RouteInformation(uri: waiting));

      expect(
        DeepLink.initialRoute(
          WidgetsBinding.instance,
          onWeb: true,
          browserAddress: Uri.parse('https://app.colabroom.com/song/other'),
        ),
        waiting.toString(),
        reason: 'the address somebody just tapped is newer than the page they '
            'happened to be on',
      );
    });

    testWidgets('and the whole stack is built from it', (tester) async {
      final stack = DeepLink.stackFor(
        path: at.path,
        shell: (tab) => const SizedBox(),
        repository: InMemoryMusicRepository.seeded(),
        onWeb: true,
      );
      expect(stack.length, 2, reason: 'the moment on top of the shell');
    });

    test('a browser is never asked to start the audio itself', () {
      // No gesture on a page opened from a pasted link, so every browser
      // refuses play() -- and the refusal would reach somebody as "could not
      // play" when they did nothing wrong.
      expect(DeepLink.playsOnArrival(onWeb: true), isFalse);
      expect(DeepLink.playsOnArrival(onWeb: false), isTrue);
      expect(
        DeepLink.playsOnArrival(nothingUnderneath: false, onWeb: false),
        isFalse,
        reason: 'something already open may be playing, and nothing here '
            'stops it',
      );
    });

    testWidgets('one that lands on top of an open screen does not play',
        (tester) async {
      // Somebody who has used the app before, so the welcome is not sitting
      // over the shell: what is being measured here is whether *this* link
      // put a screen underneath, and any other page would do as well.
      SharedPreferences.setMockInitialValues(
          <String, Object>{'welcome_flow_seen_v2': true});
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
          MaterialApp(home: WorkspaceShell(controller: controller)));
      await tester.pump(const Duration(milliseconds: 200));

      final link = Uri.parse('https://app.colabroom.com${at.path}');
      Future<void> tap() async {
        await IncomingAddresses()
            .didPushRouteInformation(RouteInformation(uri: link));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      // Nothing but the shell underneath, so it plays: that is what a link
      // to a moment is for.
      await tap();
      expect(
        tester
            .widget<SongLayersScreen>(find.byType(SongLayersScreen))
            .openAtPlays,
        isTrue,
      );

      // And now there is a screen under it, which nothing here stops.
      await tap();
      expect(
          tester.widgetList<SongLayersScreen>(
              find.byType(SongLayersScreen, skipOffstage: false)),
          hasLength(2));
      expect(
        tester
            .widget<SongLayersScreen>(find.byType(SongLayersScreen))
            .openAtPlays,
        isFalse,
        reason: 'a second player over the first is two recordings at once',
      );
    });

    test('the phone claims the address, or none of this runs on a phone', () {
      // What the manifest and the Universal Links file have to say is
      // checked in a_link_opens_the_app_test.dart, against every prefix and
      // every link the app writes. This is the sentence that connects them:
      // the address written here is under a claimed prefix.
      expect(
        momentLink(
            roomId: at.roomId,
            projectId: at.projectId,
            takeId: at.takeId,
            atMs: at.atMs),
        startsWith('https://${IncomingAddresses.host}/r/'),
      );
    });
  });
}
