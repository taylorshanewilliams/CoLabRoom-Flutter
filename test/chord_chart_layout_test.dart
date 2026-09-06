import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Chart tab, rendered the way the song sheet renders it.
///
/// chord_chart_test.dart covers everything about the chart *except* whether it
/// can be drawn, and the chart shipped in a state where it could not: the row
/// widget used `CrossAxisAlignment.stretch`, which copies the incoming
/// maxHeight down as a tight constraint, and the sheet lays it out inside a
/// scroll view where that height is infinite. Every row threw
/// "BoxConstraints forces an infinite height", the tab failed to lay out, and
/// the pointer dispatch and overlay teardown errors that followed filled the
/// error table for the rest of the session.
///
/// The unbounded height is the whole test. Pumping this inside a plain
/// `Scaffold` — a bounded box — passes against the broken widget.
ChartBar _bar(int number, {List<ChartChord> chords = const <ChartChord>[]}) {
  return ChartBar(
    number: number,
    startMs: (number - 1) * 2000,
    endMs: number * 2000,
    beatsInBar: 4,
    chords: chords,
  );
}

List<ChartRow> _rows(int count) {
  return <ChartRow>[
    for (var row = 0; row < count; row += 1)
      ChartRow(
        sectionLabel: row == 0 ? 'Verse' : null,
        bars: <ChartBar>[
          for (var bar = 1; bar <= 4; bar += 1)
            _bar(
              row * 4 + bar,
              chords: bar.isOdd
                  ? <ChartChord>[
                      ChartChord(
                        chord: bar == 1 ? 'C:maj' : 'A:min',
                        beat: 1,
                        startMs: 0,
                      ),
                    ]
                  : const <ChartChord>[],
            ),
        ],
      ),
  ];
}

Widget _inAScrollView(Widget child, {double textScale = 1.0}) {
  return MaterialApp(
    home: Scaffold(
      // Inside the MaterialApp, not around it: MaterialApp installs its own
      // MediaQuery from the test window and would overwrite one wrapped
      // outside it, so the scaled-text case would silently test 1.0.
      body: Builder(
        // copyWith, not a bare MediaQueryData: a fresh one has Size.zero, and
        // a viewport handed a zero size is a different test than this one.
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: CustomScrollView(
            slivers: <Widget>[
              SliverList(
                delegate: SliverChildListDelegate(<Widget>[
                  // The song sheet's own shape: a stretched Column of panels
                  // inside a sliver, so everything below gets an infinite
                  // maxHeight.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[child],
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lays out inside a scroll view, where the height is unbounded',
      (tester) async {
    await tester.pumpWidget(_inAScrollView(
      ChordChartView(rows: _rows(6), transpose: 0, fontScale: 1),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('C'), findsWidgets);
    expect(find.text('Am'), findsWidgets);
    expect(find.text('VERSE'), findsOneWidget);
  });

  testWidgets('draws every row at a readable height rather than collapsing',
      (tester) async {
    await tester.pumpWidget(_inAScrollView(
      ChordChartView(rows: _rows(3), transpose: 0, fontScale: 1),
    ));
    expect(tester.takeException(), isNull);

    // The trap this guards: removing `stretch` also collapses bar lines to
    // zero height if they are separate widgets with no content, which draws a
    // chart with no bars in it and reports nothing. A row has to have real
    // height, and the closing line has to be part of a cell that does.
    final rowHeight = tester.getSize(find.byType(ChordChartView)).height;
    expect(rowHeight, greaterThan(60));
  });

  testWidgets('a reader with large system text does not overflow a row',
      (tester) async {
    // 1.3 rather than an arbitrary large number: ColabRoomApp clamps the
    // reader's system scale to 1.3, so this is the biggest text the chart can
    // actually be asked to draw.
    await tester.pumpWidget(_inAScrollView(
      ChordChartView(rows: _rows(4), transpose: 2, fontScale: 1.3),
      textScale: 1.3,
    ));

    expect(tester.takeException(), isNull);
  });

  testWidgets('says so rather than laying out a broken beat grid',
      (tester) async {
    await tester.pumpWidget(_inAScrollView(
      ChordChartView(rows: _rows(250), transpose: 0, fontScale: 1),
    ));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('the beat grid is probably wrong'),
        findsOneWidget);
  });
}
