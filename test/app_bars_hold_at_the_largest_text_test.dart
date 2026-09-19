import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/calls/call_screen.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/workspace/lyric_review_screen.dart';
import 'package:colabroom/features/workspace/song_history_screen.dart';
import 'package:colabroom/services/call_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// App bars hold what is in them at the largest text.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. Material's 56 does not move with it, and a bar
/// does not complain when it runs out of room — [AppBar] hands the toolbar
/// height it was given to its title and its actions and draws what fits. So a
/// labelled action loses the bottom of its letters and a two-line title is
/// painted over the edges of the bar, both in silence, which is how this
/// shipped past the whole suite and the render harness.
///
/// The two shapes behave differently and are asserted separately.
///
/// A **two-line title** runs out of room first. Flutter holds a title to 1.34
/// of normal on purpose, so the pair of lines stops growing there — but 1.34
/// of a 22-point name over a 12.5-point sentence is already 59, and the call
/// screen's bar was 56. It goes wrong at any text size past about 1.3, so 2.0
/// is well inside it.
///
/// A **labelled action** is not held to anything, so it grows with the reader
/// all the way. At 2.0 a button label is 40 and still fits; it passes 56 at
/// about 2.8 and is cut off from there up, so the size that catches it is the
/// largest one iOS offers, 3.12 — the size the rest of the suite already
/// renders at. The measure keeps 16 of air around a label, so such a bar is a
/// few pixels taller than it was from about 2.0 up, before anything was being
/// cut; that is the margin Takes has always kept, and why only 1.0 is asserted
/// to be exactly 56.
///
/// The Inbox is the same shape with a condition on it — its actions are words
/// only while there is width for them — so it is asserted at both widths.
class _FakeCall extends CallSession {
  @override
  CallState get state => CallState.connected;
  @override
  List<CallPerson> get people => const <CallPerson>[
        CallPerson(
            userId: 'preview-user',
            name: 'Taylor',
            isYou: true,
            micOn: true,
            cameraOn: false),
      ];
  @override
  bool get micOn => true;
  @override
  bool get cameraOn => false;
  @override
  bool get musicMode => false;
  @override
  Future<void> setMic(bool on) async {}
  @override
  Future<void> setCamera(bool on) async {}
  @override
  Future<void> flipCamera() async {}
  @override
  Future<void> setMusicMode(bool on) async {}
  @override
  Future<void> leave() async {}
}

/// The phone every case here runs on unless it says otherwise.
const Size _aPhone = Size(390, 844);

/// Wide enough that the Inbox keeps its actions as words at the largest text
/// size instead of folding them into the overflow menu — a tablet, or a
/// browser window on the web build.
const Size _somethingWide = Size(1600, 900);

/// A screen of [size] with its text set to [textScale].
///
/// The scale goes on the dispatcher rather than into a MediaQuery wrapped
/// around what is pumped: MaterialApp builds its own MediaQuery from the test
/// window, so anything outside it is discarded and every large-text case would
/// silently run at 1.0.
void _phone(WidgetTester tester, double textScale, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<MusicBetaController> _boot(
  WidgetTester tester,
  InMemoryMusicRepository repository,
  Widget Function(MusicBetaController) home, {
  required double textScale,
  Size size = _aPhone,
}) async {
  _phone(tester, textScale, size);
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home(controller)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  return controller;
}

/// Takes the tree down, so a screen that started a call or a load is disposed
/// before the test ends rather than leaving a timer behind.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// The height the bar asked for, which is 56 until somebody measures it.
double _barHeight(WidgetTester tester) =>
    tester.widget<AppBar>(find.byType(AppBar).first).toolbarHeight ??
    kToolbarHeight;

/// Every word in the bar is drawn whole, and inside the bar.
///
/// Two different ways of losing words, so two checks. A paragraph handed a box
/// shorter than its line keeps the top of the letters and drops the rest,
/// silently — that is the labelled action. A title taller than the bar is laid
/// out at its full height and painted over the edges instead — that is the two
/// lines. Neither raises anything, so both are measured.
void _theBarHoldsItsWords(WidgetTester tester, String where) {
  final bar = tester.getRect(find.byType(AppBar).first);
  final lost = <String>[];
  final words = find.descendant(
    of: find.byType(AppBar).first,
    matching: find.byType(RichText),
  );
  for (final element in words.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    if (!paragraph.hasSize) continue;
    final said = paragraph.text.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: false,
    );
    if (said.trim().isEmpty) continue;
    // An icon is a paragraph too, drawn in a private-use glyph nobody reads.
    if (said.runes.every((rune) => rune >= 0xE000 && rune <= 0xF8FF)) continue;
    final painter = TextPainter(
      text: paragraph.text,
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      maxLines: paragraph.maxLines,
      strutStyle: paragraph.strutStyle,
      textWidthBasis: paragraph.textWidthBasis,
      textHeightBehavior: paragraph.textHeightBehavior,
      locale: paragraph.locale,
    )..layout(
        maxWidth: paragraph.softWrap ? paragraph.size.width : double.infinity,
      );
    final needsHigh = painter.height;
    painter.dispose();
    if (needsHigh > paragraph.size.height + 0.5) {
      lost.add('  "$said" is drawn ${paragraph.size.height.toStringAsFixed(1)} '
          'high and needs ${needsHigh.toStringAsFixed(1)}');
    }
    final top = paragraph.localToGlobal(Offset.zero).dy;
    final bottom = top + paragraph.size.height;
    if (top < bar.top - 0.5 || bottom > bar.bottom + 0.5) {
      lost.add('  "$said" runs ${top.toStringAsFixed(1)} to '
          '${bottom.toStringAsFixed(1)} and the bar is '
          '${bar.top.toStringAsFixed(1)} to ${bar.bottom.toStringAsFixed(1)}');
    }
  }
  expect(lost, isEmpty, reason: 'words are lost in the bar on $where:\n'
      '${lost.join('\n')}');
}

const List<TranscriptWord> _heard = <TranscriptWord>[
  TranscriptWord(word: 'Turning', startMs: 0, endMs: 400),
  TranscriptWord(word: 'in', startMs: 400, endMs: 600),
  TranscriptWord(word: 'the', startMs: 600, endMs: 800),
  TranscriptWord(word: 'wind', startMs: 800, endMs: 1400),
];

ReferenceTrack _reference(String projectId) => ReferenceTrack(
      projectId: projectId,
      fileId: 'file-1',
      storagePath: 'takes/file-1.m4a',
      displayName: 'south of midnight 2.m4a',
      state: SongAnalysisState.ready,
      transcriptText: 'Turning in the wind',
      transcriptWords: _heard,
    );

void main() {
  group('a two-line title', () {
    Future<void> openTheCall(WidgetTester tester, double textScale) async {
      final repository = InMemoryMusicRepository.seeded()
        ..callStanding = CallStanding.adult;
      await _boot(
        tester,
        repository,
        (controller) => CallScreen(
          roomId: controller.rooms.first.id,
          roomName: 'The Thursday Band',
          repository: repository,
          join: (_) async => _FakeCall(),
        ),
        textScale: textScale,
      );
    }

    testWidgets('grows to hold both its lines at twice the text size',
        (tester) async {
      await openTheCall(tester, 2.0);
      expect(_barHeight(tester), greaterThan(kToolbarHeight),
          reason: 'the room name and the line under it come to more than 56 '
              'between them at this size');
      _theBarHoldsItsWords(tester, 'the call at 2.0');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('is the height it always was at an ordinary text size',
        (tester) async {
      await openTheCall(tester, 1.0);
      expect(_barHeight(tester), kToolbarHeight,
          reason: 'nothing moves for a reader who has not turned their text up');
      _theBarHoldsItsWords(tester, 'the call at 1.0');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('a labelled action', () {
    Future<void> openTheReview(WidgetTester tester, double textScale) async {
      final repository = InMemoryMusicRepository.seeded();
      await _boot(
        tester,
        repository,
        (controller) {
          final project = controller.rooms.first.projects.first;
          return LyricReviewScreen(
            project: project,
            reference: _reference(project.id),
          );
        },
        textScale: textScale,
      );
    }

    testWidgets('keeps the bottom of its letters at the largest text size',
        (tester) async {
      await openTheReview(tester, 3.12);
      expect(_barHeight(tester), greaterThan(kToolbarHeight),
          reason: 'Save is taller than 56 at this size, and it is the only '
              'way to keep the corrections somebody has just typed');
      _theBarHoldsItsWords(tester, 'Review lyrics at 3.12');
      // Not asked whether anything else on this screen overflowed, because
      // something does and it is not the bar: the sentence above the lines is
      // an unflexed child of a Column, so at this size it is taller than the
      // screen and the list under it overflows by 376 — with the bar still at
      // 56 and before any of this. That is its own fix; this one is about the
      // bar. Cleared so it does not land in the next test.
      tester.takeException();
      await _close(tester);
    });

    testWidgets('loses nothing at twice the text size', (tester) async {
      await openTheReview(tester, 2.0);
      _theBarHoldsItsWords(tester, 'Review lyrics at 2.0');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('is the height it always was at an ordinary text size',
        (tester) async {
      await openTheReview(tester, 1.0);
      expect(_barHeight(tester), kToolbarHeight,
          reason: 'nothing moves for a reader who has not turned their text up');
      _theBarHoldsItsWords(tester, 'Review lyrics at 1.0');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('a labelled action that is only sometimes a word', () {
    // The Inbox is the one bar that measures itself conditionally: on a phone
    // its two actions have already moved into the overflow menu by the time
    // the text is this large, and a menu glyph is 48 and does not grow, so
    // there is nothing to measure. On something wide enough to keep them as
    // words — a tablet, or the web build in a wide window — they grow like any
    // other label and the bar has to grow with them. Tested at that width
    // because otherwise the branch that grows is never run by anything.
    Future<void> openTheInbox(
      WidgetTester tester,
      double textScale, {
      required Size size,
    }) async {
      await _boot(
        tester,
        InMemoryMusicRepository.seeded(),
        (_) => const NotificationsScreen(),
        textScale: textScale,
        size: size,
      );
    }

    testWidgets('grows for its words when there is room to keep them',
        (tester) async {
      await openTheInbox(tester, 3.12, size: _somethingWide);
      expect(find.byKey(const Key('inbox_mark_all_read')), findsOneWidget,
          reason: 'this width is the whole point of the case: if the action '
              'has folded into the menu the bar is not being measured');
      expect(_barHeight(tester), greaterThan(kToolbarHeight));
      _theBarHoldsItsWords(tester, 'the Inbox at 3.12 on something wide');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('is the height it always was at an ordinary text size',
        (tester) async {
      await openTheInbox(tester, 1.0, size: _somethingWide);
      expect(find.byKey(const Key('inbox_mark_all_read')), findsOneWidget);
      expect(_barHeight(tester), kToolbarHeight,
          reason: 'nothing moves for a reader who has not turned their text up');
      _theBarHoldsItsWords(tester, 'the Inbox at 1.0 on something wide');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('stays 56 on a phone, where the words are in the menu',
        (tester) async {
      await openTheInbox(tester, 3.12, size: _aPhone);
      expect(find.byKey(const Key('inbox_more')), findsOneWidget,
          reason: 'there is no room for the words at this size on a phone');
      expect(_barHeight(tester), kToolbarHeight,
          reason: 'a menu glyph is 48 square and does not grow with the text, '
              'so there is nothing for the bar to make room for');
      _theBarHoldsItsWords(tester, 'the Inbox at 3.12 on a phone');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('a two-line title and a labelled action together', () {
    Future<void> openTheHistory(WidgetTester tester, double textScale) async {
      final repository = InMemoryMusicRepository.seeded();
      await _boot(
        tester,
        repository,
        (controller) => SongHistoryScreen(
          projectId: controller.rooms.first.projects.first.id,
          songTitle: 'South of midnight',
          repository: repository,
        ),
        textScale: textScale,
      );
    }

    testWidgets('the bar is as tall as the taller of the two', (tester) async {
      await openTheHistory(tester, 3.12);
      expect(_barHeight(tester), greaterThan(kToolbarHeight),
          reason: 'Export is the whole point of this screen');
      _theBarHoldsItsWords(tester, 'History at 3.12');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('and is 56 at an ordinary text size', (tester) async {
      await openTheHistory(tester, 1.0);
      expect(_barHeight(tester), kToolbarHeight);
      _theBarHoldsItsWords(tester, 'History at 1.0');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });
}
