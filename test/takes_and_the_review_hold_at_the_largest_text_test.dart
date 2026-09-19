import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/take_lane.dart';
import 'package:colabroom/features/layers/timeline_ruler.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/workspace/lyric_review_screen.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fixed heights left on Takes, and the one screen a reader could not
/// reach the bottom of.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. The app bars were measured in their own pass; what
/// was left were boxes given a height somebody once measured on their own
/// phone — 22 for the strip of times, 78 for a lane — and a sentence held out
/// of a scroll.
///
/// Each is asserted the way it actually fails. The ruler and the lane are
/// [RenderFlex]es and do complain, once per mark and once per take, so the
/// exception is the evidence. The review of the lyrics fails differently: its
/// body overflowed too, but the thing that matters there is that the fields
/// somebody came to type in were off the bottom of the screen with no way to
/// scroll to them, so that is what is asked about.
///
/// The floors are asserted as well as the growth. A reader who has not turned
/// their text up should find the strip 22 and the lane 78, to the pixel.

Take _take({required String id, required String label, int durationMs = 41000}) =>
    Take(
      id: id,
      path: 'takes/$id.m4a',
      label: label,
      recordedAt: DateTime(2026, 9, 17),
      durationMs: durationMs,
    );

/// A phone of [size] with its text set to [textScale].
///
/// On the view and the dispatcher rather than in a MediaQuery wrapped around
/// what is pumped: MaterialApp builds its own MediaQuery from the test window,
/// so anything outside it is discarded and the case runs at 1.0.
void _phone(
  WidgetTester tester, {
  required double textScale,
  Size size = const Size(390, 900),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _pump(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(backgroundColor: AppColors.deepNavy, body: body),
  ));
  await tester.pump();
}

/// Takes the tree down, so a screen that started a load is disposed before the
/// test ends rather than leaving a timer behind.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// The height [label] actually wants, wherever it has been squeezed.
///
/// A Text in a box too short for it is *constrained* to that box, so its size
/// reports the box rather than the line — which is how a clipped label passes
/// a test that asks it how tall it is.
double _heightWanted(WidgetTester tester, Finder label) =>
    tester.renderObject<RenderParagraph>(label).getMaxIntrinsicHeight(
          double.infinity,
        );

void main() {
  group('the strip of times above the lanes', () {
    Future<void> openTheRuler(WidgetTester tester, double textScale) async {
      _phone(tester, textScale: textScale);
      await _pump(tester, const TimelineRuler(totalMs: 120000, leftInset: 112));
    }

    testWidgets('grows for the times in it at twice the text size',
        (tester) async {
      await openTheRuler(tester, 2.0);
      // Five marks on a two-minute song, and before this the strip overflowed
      // on every one of them.
      expect(tester.takeException(), isNull);
      final strip = tester.getSize(find.byType(TimelineRuler)).height;
      expect(strip, greaterThan(22),
          reason: 'a 9-point time is 25 at this size, in a strip of 22');
      expect(_heightWanted(tester, find.text('0:30')) + 5,
          lessThanOrEqualTo(strip + 0.5),
          reason: 'the strip holds the time and the tick under it');
      await _close(tester);
    });

    testWidgets('is the height it always was at an ordinary text size',
        (tester) async {
      await openTheRuler(tester, 1.0);
      expect(tester.getSize(find.byType(TimelineRuler)).height, 22,
          reason: 'nothing moves for a reader who has not turned their text up');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('a take lane', () {
    Future<void> openTheLane(
      WidgetTester tester,
      double textScale, {
      String label = 'Harmony',
    }) async {
      _phone(tester, textScale: textScale);
      await _pump(
        tester,
        TakeLane(
          take: _take(id: 't1', label: label),
          onToggle: () {},
          onDelete: () {},
          onAdjust: () {},
        ),
      );
    }

    testWidgets('holds the face and the words in it at twice the text size',
        (tester) async {
      await openTheLane(tester, 2.0);
      expect(tester.takeException(), isNull,
          reason: 'the left column overflowed its lane by 15 at this size, on '
              'every take in the song');
      expect(tester.getSize(find.byType(TakeLane)).height, greaterThan(78));
      await _close(tester);
    });

    testWidgets('and at the largest text size iOS offers', (tester) async {
      await openTheLane(tester, 3.12);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('is the same height as its neighbours, whatever is in it',
        (tester) async {
      // The lanes share one clock and the playhead is drawn straight down all
      // of them, so a lane that grew because somebody's part had a longer name
      // would bend the one thing about this view that must not bend. Measured
      // from the styles rather than from the words for exactly this reason.
      _phone(tester, textScale: 2.0);
      await _pump(
        tester,
        Column(
          children: <Widget>[
            TakeLane(take: _take(id: 't1', label: 'Bass'), onToggle: () {}),
            TakeLane(
              take: _take(id: 't2', label: 'Second harmony over the chorus'),
              onToggle: () {},
              onDelete: () {},
              onAdjust: () {},
              silent: true,
            ),
            TakeLane(
              take: _take(id: 't3', label: 'Lead', durationMs: 214000),
              onToggle: () {},
              onShare: () {},
              shareLabel: 'Send to Ms. Rivera',
              subtitle: 'the song',
            ),
          ],
        ),
      );
      final heights = tester
          .widgetList<TakeLane>(find.byType(TakeLane))
          .map((lane) => tester.getSize(find.byWidget(lane)).height)
          .toSet();
      expect(heights, hasLength(1),
          reason: 'every lane in a song is drawn against the same grid');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('is the height it always was at an ordinary text size',
        (tester) async {
      await openTheLane(tester, 1.0);
      expect(tester.getSize(find.byType(TakeLane)).height, 78,
          reason: 'nothing moves for a reader who has not turned their text up');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('the review of the lyrics', () {
    Future<void> openTheReview(WidgetTester tester, double textScale) async {
      _phone(tester, textScale: textScale, size: const Size(390, 844));
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final project = controller.rooms.first.projects.first;
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: LyricReviewScreen(
            project: project,
            reference: ReferenceTrack(
              projectId: project.id,
              fileId: 'file-1',
              storagePath: 'takes/file-1.m4a',
              displayName: 'south of midnight 2.m4a',
              state: SongAnalysisState.ready,
              transcriptText: 'Turning in the wind',
              transcriptWords: const <TranscriptWord>[
                TranscriptWord(word: 'Turning', startMs: 0, endMs: 400),
                TranscriptWord(word: 'in', startMs: 400, endMs: 600),
                TranscriptWord(word: 'the', startMs: 600, endMs: 800),
                TranscriptWord(word: 'wind', startMs: 800, endMs: 1400),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('the words to fix can be reached at the largest text size',
        (tester) async {
      await openTheReview(tester, 3.12);
      // The sentence above the lines used to be held out of the scroll, so at
      // this size it was taller than the screen: the body overflowed by 376
      // and the fields somebody came here to type in were off the bottom of it
      // with nothing that would scroll to them.
      expect(tester.takeException(), isNull);
      // Scrolled to rather than looked for where it stands: at this size the
      // sentence fills the screen on its own, so the first line is genuinely
      // below the fold — which is fine, and is the whole difference. Before
      // this it was below the fold of a body that did not scroll.
      final field = find.byKey(const Key('review_lyric_line_0'));
      await tester.scrollUntilVisible(field, 200);
      await tester.pump();
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Turning in the wind');
      await tester.pump();
      expect(find.text('Turning in the wind'), findsOneWidget,
          reason: 'a correction can be typed into the line it is about');
      await _close(tester);
    });

    testWidgets('and the sentence above them scrolls with them', (tester) async {
      await openTheReview(tester, 2.0);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(Scrollable),
          matching: find.textContaining('These are the words heard'),
        ),
        findsOneWidget,
        reason: 'it is the first thing in the list, not a header above it',
      );
      await _close(tester);
    });
  });

  group('the Inbox', () {
    // Flutter holds an app bar's title to 1.34 of the reader's text size
    // however large it is set, so measuring that title at the reader's full
    // scale reports a title wider than any that is ever painted, and the word
    // actions moved into the menu while there was still room for them.
    //
    // A window 1000 wide at 3.12 is where that shows. "Mark all read" and its
    // padding want 601. The title as it is really drawn is 147 wide, which
    // leaves 725 — but measured at the reader's own scale it claimed 343 and
    // left 529, so the words went into the menu on the strength of 196 pixels
    // of title that are never painted.
    Future<void> openTheInbox(WidgetTester tester, double textScale) async {
      _phone(tester, textScale: textScale, size: const Size(1000, 900));
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: const NotificationsScreen(),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('keeps its actions as words while the width really holds them',
        (tester) async {
      await openTheInbox(tester, 3.12);
      expect(find.byKey(const Key('inbox_more')), findsNothing,
          reason: 'there is room for the words at this width; they were being '
              'folded into the menu on the strength of a title 196 pixels '
              'wider than the one the bar draws');
      expect(find.byKey(const Key('inbox_mark_all_read')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });
}
