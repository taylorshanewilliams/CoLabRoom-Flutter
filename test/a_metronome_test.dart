import 'package:colabroom/features/workspace/metronome_sheet.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The click the takes console has had for months, with nothing to record:
/// a tempo to feel before the red button.
class _SilentClick implements ClickPlayer {
  final List<String> log = <String>[];

  @override
  Future<void> play({required double bpm, required int beatsPerBar}) async =>
      log.add('play ${bpm.round()}/$beatsPerBar');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');
}

void main() {
  group('tap tempo', () {
    DateTime at(int ms) => DateTime(2026, 9, 14, 12, 0, 0, ms);

    test('four even taps at half a second are 120', () {
      expect(tapTempo(<DateTime>[at(0), at(500), at(1000), at(1500)]), closeTo(120, 0.01));
    });

    test('one tap is not a tempo yet', () {
      expect(tapTempo(<DateTime>[at(0)]), isNull);
    });

    test('an uneven hand gets the middle interval, not the mean', () {
      // 500, 500, 900: the mean would say 95, the median says 120.
      expect(tapTempo(<DateTime>[at(0), at(500), at(1000), at(1900)]), closeTo(120, 0.01));
    });

    test('a long pause means start again', () {
      expect(tapTempo(<DateTime>[at(0), at(500), at(4000)]), isNull);
    });

    test('the range is a musician\'s, not a slider\'s', () {
      expect(clampBpm(10), minBpm);
      expect(clampBpm(999), maxBpm);
      expect(clampBpm(100), 100);
    });
  });

  testWidgets('start, change tempo, change the bar, stop', (tester) async {
    final click = _SilentClick();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MetronomeSheet(initialBpm: 96, player: click)),
    ));
    await tester.pump();
    expect(find.text('96'), findsOneWidget);

    await tester.tap(find.byKey(const Key('metronome_play')));
    await tester.pump();
    expect(click.log, <String>['play 96/4']);
    expect(find.text('Stop'), findsOneWidget);

    // A faster tap restarts the click, but only after the hand has settled.
    await tester.tap(find.byKey(const Key('metronome_faster')));
    await tester.pump();
    expect(find.text('97'), findsOneWidget);
    expect(click.log.length, 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(click.log.last, 'play 97/4');

    // Three in a bar is a different click, at once.
    await tester.tap(find.byKey(const Key('metronome_beats_3')));
    await tester.pump();
    expect(click.log.last, 'play 97/3');

    await tester.tap(find.byKey(const Key('metronome_play')));
    await tester.pump();
    expect(click.log.last, 'stop');
    expect(find.text('Start'), findsOneWidget);

    // Closing stops it too, so it can never end up on a take by accident.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(click.log.sublist(click.log.length - 2), <String>['stop', 'dispose']);
    expect(tester.takeException(), isNull);
  });
}
