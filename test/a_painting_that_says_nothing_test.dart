import 'dart:async';
import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/features/layers/take_lane.dart';
import 'package:colabroom/features/workspace/guitar_chord_diagram.dart';
import 'package:colabroom/features/workspace/making_the_sheet.dart';
import 'package:colabroom/features/workspace/tuner_sheet.dart';
import 'package:colabroom/services/audio_analysis_utils.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/widgets/brand_mark.dart';
import 'package:colabroom/widgets/qr_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_render/rules.dart';

/// The eyes harness, taught to see a painting nobody labelled.
///
/// Every Musician, Same Song, 17 September 2026 starts the accessibility
/// baseline here because a `CustomPaint` fails WCAG 2.1 SC 1.1.1 silently:
/// it contributes no semantics at all, nothing throws, nothing overflows and
/// the screenshot looks finished. The rule is in `test_render/rules.dart`
/// with the rest of the measurements; this is in `test/` so the full suite
/// runs it, because a rule nobody runs is a comment.
class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(size.center(Offset.zero), 4, Paint()..color = AppColors.cyan);
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}

/// One painting, however the caller chose to wrap it.
Future<void> _pump(WidgetTester tester, Widget Function(Widget) wrap) {
  return tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: wrap(const SizedBox(
        width: 40,
        height: 40,
        child: CustomPaint(painter: _MarkPainter()),
      )),
    ),
  ));
}

/// Judged as if `_MarkPainter` were one of the app's own.
List<Finding> _audit(WidgetTester tester) =>
    auditPaintedMeaning(tester, painters: <String>{'_MarkPainter'});

void main() {
  group('the rule', () {
    testWidgets('a painting with no label and no exclusion is a failure',
        (tester) async {
      await _pump(tester, (painting) => painting);

      final found = _audit(tester);
      expect(found, hasLength(1));
      expect(found.single.severity, Severity.fails);
      expect(found.single.standard, contains('1.1.1'));
      expect(found.single.detail, contains('_MarkPainter'));
      expect(found.single.detail, contains('40x40'));
    });

    testWidgets('a painting somebody named is not', (tester) async {
      await _pump(
        tester,
        (painting) => Semantics(label: 'G major', image: true, child: painting),
      );
      expect(_audit(tester), isEmpty);
    });

    testWidgets('a painting declared decoration is not', (tester) async {
      await _pump(tester, (painting) => ExcludeSemantics(child: painting));
      expect(_audit(tester), isEmpty);
    });

    testWidgets('an ExcludeSemantics that is switched off excludes nothing',
        (tester) async {
      // The widget being in the tree is not the claim; `excluding` is.
      await _pump(
        tester,
        (painting) => ExcludeSemantics(excluding: false, child: painting),
      );
      expect(_audit(tester), hasLength(1));
    });

    testWidgets('an empty label is silence, not a name', (tester) async {
      await _pump(
        tester,
        (painting) => Semantics(label: '  ', child: painting),
      );
      expect(_audit(tester), hasLength(1));
    });

    testWidgets('a label further up the tree still counts', (tester) async {
      // A drawing inside a named card is announced through the card. This is
      // where the rule is deliberately generous, and it is worth being able
      // to see that it is.
      await _pump(
        tester,
        (painting) => Semantics(
          label: 'Midnight Signal',
          child: Padding(padding: const EdgeInsets.all(8), child: painting),
        ),
      );
      expect(_audit(tester), isEmpty);
    });
  });

  group('whose painters it judges', () {
    test('the app\'s own, read off lib/', () {
      final painters = appPainters();
      expect(painters, contains('_ChordPainter'));
      expect(painters, contains('_NeedlePainter'));
      expect(painters, contains('CoLabRoomMarkPainter'));
    });

    test('not the framework\'s', () {
      // Scrollbar and CircularProgressIndicator are both a CustomPaint, and
      // the app is not answerable for either.
      expect(appPainters(), isNot(contains('ScrollbarPainter')));
    });

    testWidgets('a Scrollbar does not fail this rule', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scrollbar(
          thumbVisibility: true,
          child: ListView(
            children: <Widget>[for (var i = 0; i < 40; i += 1) Text('row $i')],
          ),
        ),
      ));
      expect(auditPaintedMeaning(tester), isEmpty);
    });
  });

  group('what it found, now fixed', () {
    testWidgets('the chord diagram speaks', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: GuitarChordDiagram(
            chord: ChordDiagramData(
              name: 'G',
              spokenName: 'G major',
              frets: <int>[3, 2, 0, 0, 0, 3],
            ),
          ),
        ),
      ));
      expect(auditPaintedMeaning(tester), isEmpty);
    });

    testWidgets('the brand mark declares itself decoration', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: const Scaffold(body: Center(child: BrandMark())),
      ));
      expect(auditPaintedMeaning(tester), isEmpty);
    });

    testWidgets('the tuner needle says where it is', (tester) async {
      final microphone = StreamController<Uint8List>();
      addTearDown(microphone.close);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: TunerSheet(openStream: () async => microphone.stream),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(auditPaintedMeaning(tester), isEmpty);
      // Nothing has been played yet, and saying so is the honest reading.
      expect(_byLabel('No note yet.'), findsOneWidget);
    });

    testWidgets('the take lane says when the take plays', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: TakeLane(
            take: Take(
              id: 't1',
              path: 'takes/t1.m4a',
              label: 'Harmony',
              recordedAt: DateTime(2026, 9, 17),
              durationMs: 41000,
            ),
            onToggle: () {},
            startsFraction: 0.7,
            spansFraction: 0.3,
          ),
        ),
      ));

      expect(auditPaintedMeaning(tester), isEmpty);
      // The one thing the lane was built to show and the row never said: a
      // harmony punched in over the last chorus is not a full-length take.
      expect(
        _byLabel('Plays from three quarters of the way in to the end.'),
        findsOneWidget,
      );
    });

    testWidgets('the ring while the sheet is made is decoration',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: MakingTheSheet(
              progress: SongAnalysisProgress('working', 0.4),
              songTitle: 'Midnight Signal',
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 60));
      expect(auditPaintedMeaning(tester), isEmpty);
    });

    testWidgets('the QR code says what it opens', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: QrCode(data: 'https://colabroom.com/j/ze9w-27t0', label: 'Join the room'),
          ),
        ),
      ));
      expect(auditPaintedMeaning(tester), isEmpty);
    });
  });
}

/// A control by the label it was given.
///
/// Not `find.bySemanticsLabel`, which reads `debugSemantics` off the render
/// object and matches none of these. The `Semantics` widget carries the label
/// itself, and matching it needs no semantics pipeline at all — the same
/// approach `test_render/the_app_test.dart` settled on.
Finder _byLabel(String label) => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    );
