import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:colabroom/widgets/profile_face.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The last three places the largest text was still cut off.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. The clamp went, and the app was walked at a text
/// scale of 2.0 — but a render walk only catches the failures that *throw*,
/// and two of these three do not. A fixed box does not overflow; it clips,
/// silently, and a screenshot of it looks like a design decision.
///
/// So each of the three is asserted the way it actually fails:
///
/// - the pin-a-note button really does overflow, so the exception is enough;
/// - the chip rows are measured against the height their own label needs,
///   because the label inside a fixed box reports the box's height rather
///   than its own — which is exactly why nothing complained;
/// - the initials in a profile face are asserted not to grow at all, since
///   they are a drawing of a person inside a circle of a fixed size.
///
/// Heights come from the render object rather than from `getSize`. A Text
/// squeezed into a box too short for it is *constrained* to that box, so
/// `getSize` reports the box and the test would pass over the bug;
/// `getMaxIntrinsicHeight` reports the height the line actually wants.

/// The takes a song has, as the Takes screen asks for them.
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

SharedLayer _layer({required String id, required String label}) {
  return SharedLayer(
    id: id,
    projectId: 'song-1',
    recordedBy: 'preview-user',
    storagePath: 'room-1/song-1/layers/$id.m4a',
    label: label,
    part: TakePart.other,
    durationMs: 200000,
    createdAt: DateTime(2026, 9, 17),
    sharedAt: DateTime(2026, 9, 17),
  );
}

/// A phone of a given size with its text set to [textScale].
///
/// On the view and the dispatcher rather than in a MediaQuery wrapped around
/// what is pumped: MaterialApp builds its own MediaQuery from the test
/// window, so anything outside it is discarded and the case runs at 1.0.
void _phone(
  WidgetTester tester, {
  required double textScale,
  required Size size,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// The height one line of [label] actually wants, wherever it is drawn.
double _heightWanted(WidgetTester tester, Finder label) {
  final paragraph = tester.renderObject<RenderParagraph>(label);
  return paragraph.getMaxIntrinsicHeight(double.infinity);
}

/// How tall the chip carrying [label] is drawn.
double _chipHeight(WidgetTester tester, String label) {
  return tester
      .getSize(
        find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
      )
      .height;
}

/// The Takes screen on a 360-wide phone, and everything Flutter complained
/// about while it drew.
///
/// The complaints are collected rather than left to `takeException` so that
/// one row can be asked about on its own: a widget test hands back the first
/// exception of many, and "multiple exceptions were detected" names none of
/// them.
Future<List<FlutterErrorDetails>> _openTakes(
  WidgetTester tester, {
  required double textScale,
}) async {
  final complaints = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    complaints.add(details);
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);

  _phone(tester, textScale: textScale, size: const Size(360, 1000));

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
          _layer(id: 'layer-one', label: 'Guitar'),
        ]),
        analysisService: _NoAnalysis(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return complaints;
}

Future<void> _openSongs(
  WidgetTester tester, {
  required double textScale,
  String query = '',
}) async {
  _phone(tester, textScale: textScale, size: const Size(390, 1200));

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: SongsScreen(
          displayName: 'Taylor',
          onOpenAccount: () {},
          onOpenNotifications: () {},
          analysisService: _NoAnalysis(),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 250));

  if (query.isNotEmpty) {
    await tester.enterText(find.byKey(const Key('songs_search_field')), query);
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  testWidgets(
      'the button that pins a note holds beside the one that says it',
      (tester) async {
    // 360 wide at 1.3, which is a common Android phone one step up rather
    // than an accessibility size. The pin button and the hold-to-say button
    // share one row; the say button sized itself to its own label and took
    // 280 of the 328 there are, which left the pin button eighteen pixels
    // to draw an icon, a gap and "Note at 0:00" in. Its label wrapped to one
    // character per line — a 230-pixel tower — and the button overflowed by
    // six.
    final complaints = await _openTakes(tester, textScale: 1.3);

    expect(
      find.byKey(const Key('pin_moment_note')),
      findsOneWidget,
      reason: 'there is no way to pin a note, so nothing was measured',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'the row holding the pin button overflowed at 1.3',
    );
    expect(complaints, isEmpty, reason: 'this screen complained at 1.3');
  });

  testWidgets('the same row holds at the largest text size', (tester) async {
    final complaints = await _openTakes(tester, textScale: 2.0);

    // Only this row's complaints, not the screen's.
    //
    // Two other things on the Takes screen overflow at 2.0 and did so before
    // this change — the timeline ruler's Column (timeline_ruler.dart:34) and
    // a take lane's (take_lane.dart:133), both fixed heights holding text
    // that now grows. They are somebody else's slice; swallowing them with a
    // bare `takeException` would have made this assertion meaningless either
    // way, so the row is named instead.
    expect(
      complaints.where((detail) {
        final text = detail.toString();
        return text.contains('pin_moment_note') ||
            text.contains('moment_notes.dart');
      }),
      isEmpty,
      reason: 'the pin-and-say row overflowed at 2.0',
    );
    tester.takeException();

    // Both buttons got a real share of the row rather than one taking it all.
    final pin = tester.getSize(find.byKey(const Key('pin_moment_note')));
    final say = tester.getSize(find.byKey(const Key('say_moment_note')));
    expect(pin.width, greaterThan(100), reason: 'the pin button was squeezed');
    expect(say.width, greaterThan(100), reason: 'the say button was squeezed');

    // And the pin button is still something a finger can find. Material pads
    // the tap target of a text button out to 48; shrinking that to stop the
    // overflow would trade a clipped word for a button nobody can hit.
    expect(
      pin.height,
      greaterThanOrEqualTo(48),
      reason: 'the pin button is no longer a 48-dp target',
    );

    // The pill beside it is as tall as the words in it, the same way the
    // chips below are. A Row never reports a child taller than itself, so
    // this one clipped its label without anything being thrown.
    expect(
      say.height,
      greaterThanOrEqualTo(_heightWanted(tester, find.text('Hold to say it'))),
      reason: 'the hold-to-say label is sliced top and bottom',
    );
  });

  testWidgets('the Songs, Rooms and Sets chips are as tall as their words',
      (tester) async {
    await _openSongs(tester, textScale: 2.0);

    for (final label in <String>['Songs', 'Rooms', 'Sets']) {
      expect(find.text(label), findsWidgets, reason: 'no $label chip');
      final wanted = _heightWanted(tester, find.text(label).first);
      expect(
        _chipHeight(tester, label),
        greaterThanOrEqualTo(wanted),
        reason: 'the $label chip is ${_chipHeight(tester, label)} tall and its '
            'label needs $wanted, so the word is sliced top and bottom',
      );
    }
  });

  testWidgets('the room filter chips are as tall as their words',
      (tester) async {
    // The second fixed row, which only appears while somebody is searching
    // and only when they are in more than one room.
    await _openSongs(tester, textScale: 2.0, query: 'a');

    expect(
      find.text('All rooms'),
      findsOneWidget,
      reason: 'the room filter did not appear, so nothing was measured',
    );
    final wanted = _heightWanted(tester, find.text('All rooms'));
    expect(
      _chipHeight(tester, 'All rooms'),
      greaterThanOrEqualTo(wanted),
      reason: 'the room filter chip is ${_chipHeight(tester, 'All rooms')} '
          'tall and its label needs $wanted',
    );
  });

  testWidgets('nothing moves for a reader who has not turned their text up',
      (tester) async {
    // The floor. 34 is the height somebody measured on their own phone, and
    // a fix that grew the row at 1.0 would move every screen under it.
    await _openSongs(tester, textScale: 1.0);
    expect(_chipHeight(tester, 'Songs'), 34);
  });

  testWidgets('the initials in a face are drawn at the size of the circle',
      (tester) async {
    // They are a drawing of a person, not a second fact about them — the name
    // is written beside the face wherever it matters, and that is the text
    // that grows. player_face.dart already holds this line; this is the same
    // circle on the profile page, which did not.
    final wanted = <double, double>{};
    for (final scale in <double>[1.0, 2.0]) {
      _phone(tester, textScale: scale, size: const Size(390, 844));
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: const Scaffold(
          body: Center(
            child: ProfileFace(name: 'Mara Okonkwo', seed: 'preview-mara'),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('MO'), findsOneWidget);
      wanted[scale] = _heightWanted(tester, find.text('MO'));
      expect(
        wanted[scale],
        lessThanOrEqualTo(78),
        reason: 'the initials are taller than the circle holding them',
      );
    }

    expect(
      wanted[2.0],
      wanted[1.0],
      reason: 'the initials grew with the reader’s text size and overran the '
          'circle they are drawn in',
    );
  });
}
