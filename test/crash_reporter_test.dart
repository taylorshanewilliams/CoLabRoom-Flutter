import 'package:colabroom/services/crash_reporter.dart';
import 'package:colabroom/services/error_reporter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the real reporter so nothing here needs a backend.
class _CapturingReporter extends ErrorReporter {
  _CapturingReporter({this.failEveryTime = false});

  final bool failEveryTime;
  final List<String> messages = <String>[];
  final List<String?> stages = <String?>[];

  @override
  Future<void> reportError({
    required String service,
    required String message,
    String? stage,
    String? projectId,
  }) async {
    if (failEveryTime) throw StateError('telemetry is down');
    messages.add(message);
    stages.add(stage);
  }
}

void main() {
  late _CapturingReporter reporter;

  setUp(() {
    CrashReporter.resetForTest();
    reporter = _CapturingReporter();
    CrashReporter.reporter = reporter;
  });

  tearDown(CrashReporter.resetForTest);

  test('an error is recorded with its stack and where it came from', () async {
    await CrashReporter.report(
      StateError('the room would not load'),
      StackTrace.fromString('#0      Room.load (package:colabroom/room.dart:12)'),
      stage: 'async',
    );

    expect(reporter.messages, hasLength(1));
    expect(reporter.messages.single, contains('the room would not load'));
    expect(reporter.messages.single, contains('package:colabroom/room.dart:12'));
    expect(reporter.stages.single, 'async');
  });

  test('the same failure again is not a second row', () async {
    // A widget that throws during build throws again on the very next frame.
    // Without this, one bug becomes thousands of identical rows and buries
    // every other failure in the table.
    final stack = StackTrace.fromString('#0      Editor.build (package:colabroom/editor.dart:88)');
    for (var attempt = 0; attempt < 50; attempt += 1) {
      await CrashReporter.report(StateError('build failed'), stack);
    }

    expect(reporter.messages, hasLength(1));
  });

  test('a different failure still gets through', () async {
    await CrashReporter.report(StateError('one thing broke'), StackTrace.empty);
    await CrashReporter.report(StateError('a different thing broke'), StackTrace.empty);

    expect(reporter.messages, hasLength(2));
  });

  test('a flood of near-identical failures still stops', () async {
    // The case the cooldown cannot catch: every message slightly different,
    // so every one is its own signature.
    for (var i = 0; i < CrashReporter.maxPerSession + 20; i += 1) {
      await CrashReporter.report(StateError('failure number $i'), StackTrace.empty);
    }

    expect(reporter.messages, hasLength(CrashReporter.maxPerSession));
  });

  test('a reporter that is itself broken does not take the app down', () async {
    CrashReporter.reporter = _CapturingReporter(failEveryTime: true);

    // The whole point: this is called from FlutterError.onError, so throwing
    // here would turn one handled error into an unhandled one.
    await expectLater(
      CrashReporter.report(StateError('something'), StackTrace.empty),
      completes,
    );
  });

  test('an error with no stack is still worth recording', () async {
    await CrashReporter.report('a bare string thrown from somewhere', null);

    expect(reporter.messages.single, 'a bare string thrown from somewhere');
  });

  test('a layout error carries the widget Flutter named, not just the message', () async {
    // The real report this covers said only "A RenderFlex overflowed by 3.0
    // pixels on the bottom." — true, and impossible to act on. Everything
    // needed to find the widget was in FlutterErrorDetails and went unread.
    final details = FlutterErrorDetails(
      exception: FlutterError('A RenderFlex overflowed by 3.0 pixels on the bottom.'),
      library: 'rendering library',
      context: ErrorDescription('during layout'),
      informationCollector: () sync* {
        yield ErrorDescription(
          'The overflowing RenderFlex has an orientation of Axis.vertical',
        );
        yield DiagnosticsProperty<String>(
          'creator',
          'Column <- _AnalyzingRing <- StudioResultsScreen',
        );
      },
    );

    final detail = CrashReporter.describeFlutterError(details);
    expect(detail, contains('during layout'));
    expect(detail, contains('Axis.vertical'));
    expect(detail, contains('_AnalyzingRing'));

    await CrashReporter.report(
      details.exception,
      null,
      stage: details.library!,
      detail: detail,
    );

    final message = reporter.messages.single;
    expect(message, contains('overflowed by 3.0 pixels'));
    expect(message, contains('_AnalyzingRing'));
    expect(reporter.stages.single, 'rendering library');
  });

  test('a diagnostic that throws while describing itself is not fatal', () async {
    // A collector runs while the widget it describes is already broken, so
    // it is exactly the code most likely to throw. It must not replace that
    // widget's error with its own.
    final details = FlutterErrorDetails(
      exception: FlutterError('something went wrong'),
      library: 'rendering library',
      informationCollector: () sync* {
        throw StateError('the collector itself failed');
      },
    );

    expect(CrashReporter.describeFlutterError(details), isEmpty);
  });
}
