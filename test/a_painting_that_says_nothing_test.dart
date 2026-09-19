import 'dart:async';
import 'dart:io';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/features/layers/take_lane.dart';
import 'package:colabroom/features/workspace/guitar_chord_diagram.dart';
import 'package:colabroom/features/workspace/making_the_sheet.dart';
import 'package:colabroom/features/workspace/tuner_sheet.dart';
import 'package:colabroom/services/audio_analysis_utils.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/widgets/brand_mark.dart';
import 'package:colabroom/widgets/qr_code.dart';
import 'package:flutter/foundation.dart';
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

/// The same walk, as the list rather than as findings.
List<SilentThing> _silent(WidgetTester tester) =>
    silentPaint(tester, painters: <String>{'_MarkPainter'});

/// An image that never arrives.
///
/// The rule reads the widget rather than the pixels, and a provider that
/// resolves to nothing keeps a decode — and the real async zone a decode has
/// to happen in — out of a widget test.
class _NoPicture extends ImageProvider<_NoPicture> {
  const _NoPicture();

  @override
  Future<_NoPicture> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_NoPicture>(this);

  @override
  ImageStreamCompleter loadImage(_NoPicture key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

/// One widget, centred, at a size the report can be checked against.
Future<void> _pumpOne(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(body: Center(child: child)),
  ));
}

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

    test('source it cannot read is an error, not a clean sheet', () {
      // The way this rule would go quietly stale: run from somewhere that is
      // not the package root, find no lib/, judge no painters, and report
      // nothing wrong forever. It has to say so instead.
      final nowhere = Directory.systemTemp.createTempSync('no_painters');
      addTearDown(() => nowhere.deleteSync(recursive: true));
      File('${nowhere.path}/not_a_painter.dart')
          .writeAsStringSync('class Quiet {}\n');

      expect(() => paintersUnder(nowhere), throwsStateError);
      expect(() => paintersUnder(Directory('${nowhere.path}/missing')),
          throwsStateError);
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
          child: FrettedChordDiagram(
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

    testWidgets('a take too short to go anywhere says one place, not two',
        (tester) async {
      // Nine seconds punched in at 1:21 of a three-minute song begins and
      // ends in the same words. "Plays from halfway to halfway" is a sentence
      // nobody should have to listen to.
      expect(await _lanePlaying(tester, starts: 0.45, spans: 0.05),
          'Plays around halfway.');
      expect(await _lanePlaying(tester, starts: 0.96, spans: 0.04),
          'Plays around the end.');
      // "Near" is already vague, and does not need an "around" in front of it.
      expect(await _lanePlaying(tester, starts: 0.10, spans: 0.05),
          'Plays near the start.');
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

  // The list, rather than the findings. The harness reports both: the
  // findings go into REPORT.md beside the contrast and the tap targets, and
  // the list goes into SILENT.md and into the snapshot that keeps it from
  // growing — so what the list holds, and what it calls things, is part of
  // the contract and not an implementation detail.
  group('the list', () {
    testWidgets('holds the painting nobody named and not the one somebody did',
        (tester) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: <Widget>[
            Semantics(
              label: 'G major',
              image: true,
              child: const SizedBox(
                width: 40,
                height: 40,
                child: CustomPaint(painter: _MarkPainter()),
              ),
            ),
            const SizedBox(
              width: 60,
              height: 30,
              child: CustomPaint(painter: _MarkPainter()),
            ),
          ],
        ),
      ));

      final silent = _silent(tester);
      expect(silent, hasLength(1));
      expect(silent.single.kind, SilentThing.painting);
      expect(silent.single.what, '_MarkPainter');
      expect(silent.single.size, const Size(60, 30));
      expect(silent.single.line, 'CustomPaint · _MarkPainter');
    });

    test('a line carries the screen and no pixels', () {
      // The snapshot is compared, not looked at, so everything in it has to be
      // the same on every device. A size in the line would churn on a font
      // change and teach people to re-record without reading.
      final lines = silentPaintLines(<SilentThing>[
        SilentThing(
          kind: SilentThing.painting,
          what: '_WavePainter',
          size: const Size(320, 64),
          screen: 'the takes',
        ),
        SilentThing(
          kind: SilentThing.painting,
          what: '_WavePainter',
          size: const Size(640, 64),
          screen: 'the takes',
        ),
        SilentThing(
          kind: SilentThing.image,
          what: 'MemoryImage',
          size: const Size(44, 44),
          screen: 'a song',
        ),
      ]);
      expect(lines, <String>[
        'a song · Image · MemoryImage',
        'the takes · CustomPaint · _WavePainter',
      ]);
    });
  });

  group('an image', () {
    testWidgets('with no label is silent', (tester) async {
      await _pumpOne(tester, const Image(image: _NoPicture(), width: 44, height: 44));

      final silent = _silent(tester);
      expect(silent, hasLength(1));
      expect(silent.single.kind, SilentThing.image);
      expect(silent.single.what, '_NoPicture');
      expect(_audit(tester).single.detail, contains('an Image (_NoPicture)'));
    });

    testWidgets('with a label of its own is not', (tester) async {
      await _pumpOne(
        tester,
        const Image(
          image: _NoPicture(),
          width: 44,
          height: 44,
          semanticLabel: 'Ruth',
        ),
      );
      expect(_silent(tester), isEmpty);
    });

    testWidgets('declared decoration is not', (tester) async {
      // A face beside a name that is already read out loud is decoration, and
      // saying "image" after the name helps nobody.
      await _pumpOne(
        tester,
        const Image(
          image: _NoPicture(),
          width: 44,
          height: 44,
          excludeFromSemantics: true,
        ),
      );
      expect(_silent(tester), isEmpty);
    });
  });

  group('an icon-only control', () {
    testWidgets('with no tooltip is silent', (tester) async {
      await _pumpOne(
        tester,
        IconButton(onPressed: () {}, icon: const Icon(Icons.mic_rounded)),
      );

      final silent = _silent(tester);
      expect(silent, hasLength(1));
      expect(silent.single.kind, SilentThing.iconControl);
      expect(silent.single.what, contains('${Icons.mic_rounded}'));
    });

    testWidgets('with a tooltip is not', (tester) async {
      await _pumpOne(
        tester,
        IconButton(
          onPressed: () {},
          tooltip: 'Record something',
          icon: const Icon(Icons.mic_rounded),
        ),
      );
      expect(_silent(tester), isEmpty);
    });

    testWidgets('is not a finding twice', (tester) async {
      // auditLabels already reports it from the semantics side. A report that
      // says the same thing under two headings is a report people stop
      // reading, so the list carries it and the findings do not.
      await _pumpOne(
        tester,
        IconButton(onPressed: () {}, icon: const Icon(Icons.mic_rounded)),
      );
      expect(_audit(tester), isEmpty);
      expect(auditLabels(tester), hasLength(1));
    });

    testWidgets('an icon beside words is not a control that says nothing',
        (tester) async {
      // The commonest icon in any app: decoration at the head of a row whose
      // words are the thing being read. Flagging those would bury the handful
      // that matter under a hundred that do not.
      await _pumpOne(
        tester,
        InkWell(
          onTap: () {},
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[Icon(Icons.mic_rounded), Text('Record')],
          ),
        ),
      );
      expect(_silent(tester), isEmpty);
    });

    testWidgets('an icon in nothing tappable is not a control at all',
        (tester) async {
      await _pumpOne(tester, const Icon(Icons.mic_rounded));
      expect(_silent(tester), isEmpty);
    });

    testWidgets('a hint is a name too', (tester) async {
      await _pumpOne(
        tester,
        Semantics(
          hint: 'Starts recording',
          child: IconButton(
            onPressed: () {},
            icon: const Icon(Icons.mic_rounded),
          ),
        ),
      );
      expect(_silent(tester), isEmpty);
    });
  });

  group('a button announced through its parent', () {
    testWidgets('a FloatingActionButton with a tooltip is not silent',
        (tester) async {
      // FloatingActionButton ends its build with MergeSemantics, so the
      // tooltip lands on the parent node and the tap action on the child.
      // Reading the child on its own reported the Record button — the most
      // prominent control in the app, which announces "Record something" —
      // as a silent 56x56 square on four screens of every walk.
      await _pumpOne(
        tester,
        FloatingActionButton(
          onPressed: () {},
          tooltip: 'Record something',
          child: const Icon(Icons.mic_rounded),
        ),
      );

      expect(auditLabels(tester), isEmpty);
      expect(_silent(tester), isEmpty);
    });

    testWidgets('and one without a tooltip still is', (tester) async {
      await _pumpOne(
        tester,
        FloatingActionButton(
          onPressed: () {},
          child: const Icon(Icons.mic_rounded),
        ),
      );

      expect(auditLabels(tester), hasLength(1));
      expect(_silent(tester).single.kind, SilentThing.iconControl);
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

/// What one lane says about where its take sits, and nothing else.
Future<String> _lanePlaying(
  WidgetTester tester, {
  required double starts,
  required double spans,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: TakeLane(
        take: Take(
          id: 't1',
          path: 'takes/t1.m4a',
          label: 'Harmony',
          recordedAt: DateTime(2026, 9, 17),
          durationMs: 9000,
        ),
        onToggle: () {},
        startsFraction: starts,
        spansFraction: spans,
      ),
    ),
  ));
  final lane = tester.widgetList<Semantics>(find.byType(Semantics)).firstWhere(
        (widget) => (widget.properties.label ?? '').startsWith('Plays'),
      );
  return lane.properties.label!;
}
