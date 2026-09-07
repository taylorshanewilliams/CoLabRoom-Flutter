import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:colabroom/features/workspace/song_analysis_screen.dart';
import 'package:colabroom/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Can this app be drawn — on a small phone, and by somebody who has turned
/// their text size up?
///
/// This suite exists because of what the other forty-five files are not. They
/// are strong on logic and nearly blind to layout: 11 of them render a widget
/// at all, and roughly 12 of 57 screens are named anywhere in a test. Every
/// layout defect this project has shipped went out through that gap.
///
///   * The Chart tab could not be laid out at all. `chord_chart_test.dart`
///     covered chord spelling, bar grouping, transposition and section
///     labels — everything about the chart except whether it could be drawn.
///   * A take strip overflowed by 47 pixels, then by 3.
///   * A fixed 30px box held two lines of 10px text: 24 logical pixels on the
///     phone it was written on, 31 on a phone whose owner had set their font
///     larger.
///
/// None of those are logic bugs and none were catchable by a unit test. All
/// three are caught by mounting the screen and looking at whether Flutter
/// complained.
///
/// **Two conditions do the work here.** A narrow screen, because 800x600 —
/// the test binding's default — is wider than any phone and hides horizontal
/// crowding. And 1.3x text, because ColabRoomApp clamps the reader's system
/// scale to 1.3, so that is the largest text this app can ever be asked to
/// draw and the point at which every fixed pixel height in the codebase is
/// wrong by the most.
///
/// Overflow is an exception in a widget test, so `takeException` catches the
/// yellow stripes as well as the crashes.
/// Everything Flutter complained about since the last boot, in full.
///
/// `takeException` hands back only the one-line summary — "A RenderFlex
/// overflowed by 107 pixels on the right" — and the creator chain that says
/// *which* RenderFlex never reaches the CI log. A finding that costs an
/// investigation to locate is a finding people stop chasing, so the harness
/// keeps the details and puts them in the failure message.
final List<FlutterErrorDetails> _complaints = <FlutterErrorDetails>[];

String _why(String what) {
  if (_complaints.isEmpty) return '$what did not draw';
  final first = _complaints.first.toString();
  final detail = first.length > 2600 ? first.substring(0, 2600) : first;
  return '''$what did not draw:

$detail''';
}


/// Lets a few frames go by, without requiring the app to ever stop moving.
///
/// `pumpAndSettle` waits for no animation to be in flight and throws when one
/// never ends — and this app has controls that pulse on purpose. That is not a
/// defect, and a sweep like this one should not treat it as one, so the
/// harness advances a fixed number of frames instead: long enough for a route
/// transition and a rebuild, indifferent to anything still ticking.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<MusicBetaController> _controller() async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  return controller;
}

/// Pumps the app at a given phone size and text scale.
///
/// Both go on the view and the dispatcher rather than into a MediaQuery
/// wrapped around the app, and that is the only way this works. CoLabRoomApp
/// owns the MaterialApp, MaterialApp builds its own MediaQuery from the test
/// window, and anything wrapped outside is discarded — so a scale set that way
/// looks applied, changes nothing, and every "large text" case silently tests
/// 1.0 instead. Setting it on the dispatcher puts it where MaterialApp reads
/// from.
Future<void> _boot(
  WidgetTester tester,
  MusicBetaController controller, {
  required Size size,
  required double textScale,
}) async {
  _complaints.clear();
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _complaints.add(details);
    // Chained, not replaced: the binding's own handler is what makes
    // takeException work, and swallowing it would turn every assertion in
    // this file into a pass.
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(CoLabRoomApp.preview(controller: controller));
  await _frames(tester);
}

/// What the app actually believes it is being drawn into.
///
/// Asserted rather than assumed. A harness that silently runs at the test
/// binding's default 800x600 would pass everything and prove nothing, and the
/// failure would look exactly like a clean bill of health.
MediaQueryData _observed(WidgetTester tester) {
  return tester.widget<MediaQuery>(
    find.descendant(
      of: find.byType(MaterialApp),
      matching: find.byType(MediaQuery),
    ).first,
  ).data;
}

/// Taps something by its visible text, if it is there, and settles.
///
/// Tolerant on purpose. This suite is a smoke sweep over the whole app, and a
/// destination that has been renamed should not fail it — the thing being
/// tested is whether what *is* on screen can be drawn, not whether a
/// particular label still exists. The specific assertions about labels and
/// keys live in widget_test.dart, where a rename is supposed to fail.
Future<bool> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// Taps a keyed control if it is on screen, and settles.
///
/// Keys rather than labels for the destinations that have them: a key is a
/// promise the screen makes to its tests, and a label is copy somebody will
/// reword. widget_test.dart is where a rename is supposed to fail; this file
/// is only ever asking whether what is there can be drawn.
Future<bool> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

Future<bool> _back(WidgetTester tester) async {
  final finder = find.byTooltip('Back');
  if (finder.evaluate().isEmpty) {
    // No AppBar back button — a sheet, or a screen that owns its own
    // navigation. Pop the route directly so the sweep can carry on.
    final state = tester.state<NavigatorState>(find.byType(Navigator).first);
    if (!state.canPop()) return false;
    state.pop();
    await _frames(tester);
    return true;
  }
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// Scrolls until [finder] exists, then returns it.
///
/// Home is a lazy CustomScrollView: a section below the fold is not built, so
/// it is invisible to `find` and to anything else looking.
Future<Finder> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return finder;
  await tester.scrollUntilVisible(finder, 220, maxScrolls: 12);
  await _frames(tester);
  return finder;
}

void main() {
  // Proves the harness before any of it is believed. If the viewport is not
  // what was asked for, every result below is meaningless — and meaningless
  // in the worst direction, because it would look like everything passes.
  testWidgets('the harness actually resizes the app', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.0);

    final observed = _observed(tester);
    expect(
      observed.size.width,
      360,
      reason: 'the app is being drawn at ${observed.size}, not a phone width',
    );
    expect(observed.size.height, 690);
  });

  // A small phone and a large one. 360x690 is roughly the smallest Android
  // still in real use; 390x844 is an iPhone the beta is actually running on.
  const phones = <String, Size>{
    'small phone': Size(360, 690),
    'iPhone': Size(390, 844),
  };
  // 1.0 is the author's own device. 1.3 is the ceiling ColabRoomApp clamps
  // the reader's system setting to, and therefore the worst case that can
  // reach a real screen.
  const scales = <double>[1.0, 1.3];

  for (final phone in phones.entries) {
    for (final scale in scales) {
      final label = '${phone.key} at ${scale}x text';

      testWidgets('$label — every tab draws', (tester) async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await _boot(tester, controller, size: phone.value, textScale: scale);
        expect(tester.takeException(), isNull, reason: _why('Home'));

        // Asserted present, not merely tapped. _tapText is tolerant by
        // design, so when the Studio and the Control Room stopped being tabs
        // this loop kept passing while testing nothing — which is the exact
        // failure mode this whole file exists to prevent.
        for (final tab in <String>['Home', 'Songs', 'Open Mic']) {
          expect(find.text(tab), findsWidgets, reason: '$tab is not a tab');
        }
        for (final gone in <String>['Studio', 'Control Room']) {
          expect(find.text(gone), findsNothing,
              reason: '$gone is a tab again');
        }

        for (final tab in <String>['Songs', 'Open Mic', 'Home']) {
          expect(await _tapText(tester, tab), isTrue, reason: '$tab is gone');
          expect(tester.takeException(), isNull, reason: _why('$tab'));
        }
      });

      testWidgets('$label — a song and its workspace draw', (tester) async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await _boot(tester, controller, size: phone.value, textScale: scale);

        await _tapText(tester, 'Songs');
        expect(tester.takeException(), isNull, reason: _why('Songs'));

        // The seeded song. Opening one is the single most-used path in the
        // app and the one carrying the most layout: a toolbar, the ask bar,
        // and a full-height editor.
        await _tapText(tester, 'Midnight Signal');
        expect(
          tester.takeException(),
          isNull,
          reason: _why('the song workspace'),
        );
      });
    }
  }

  testWidgets('the keyboard appearing does not break the workspace',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    await _tapText(tester, 'Songs');
    await _tapText(tester, 'Midnight Signal');
    expect(tester.takeException(), isNull);

    // Half the screen, which is roughly what a keyboard takes on a small
    // phone. Everything in the workspace has to survive being given half the
    // room it had a moment ago — this is where a column of fixed heights
    // stops fitting, and it is a state the app spends a lot of its life in.
    tester.view.viewInsets = const FakeViewPadding(bottom: 345);
    addTearDown(tester.view.reset);
    await _frames(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: 'the workspace did not survive the keyboard opening',
    );
  });

  // Past the four tabs and one song: the destinations somebody actually
  // reaches in a session. Each is checked on the small phone at 1.3x, which
  // is where the last five defects were and where fixed pixel heights are
  // most wrong.
  testWidgets('the workspace destinations draw', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    await _tapText(tester, 'Songs');
    await _tapText(tester, 'Midnight Signal');
    expect(tester.takeException(), isNull, reason: _why('the workspace'));

    for (final entry in <String, String>{
      'workspace_analyze_button': 'Analyze',
      'workspace_layers_button': 'Takes',
      'workspace_live_button': 'Live',
    }.entries) {
      if (!await _tapKey(tester, entry.key)) continue;
      expect(tester.takeException(), isNull,
          reason: _why('${entry.value}'));
      await _back(tester);
      expect(tester.takeException(), isNull,
          reason: _why('coming back from ${entry.value}'));
    }
  });

  testWidgets('the inbox and the account screen draw', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    // The bell on Home. Reached by its Semantics label because it is an
    // InkResponse rather than a keyed button.
    final bell = find.bySemanticsLabel('Notifications');
    if (bell.evaluate().isNotEmpty) {
      await tester.tap(bell.last, warnIfMissed: false);
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: _why('the Inbox'));
      await _back(tester);
    }

    for (final label in <String>['Account', 'Settings']) {
      if (await _tapText(tester, label)) {
        expect(tester.takeException(), isNull, reason: _why('$label'));
        break;
      }
    }
  });

  testWidgets('starting a song draws', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    // The single most important path in the app for somebody new, and the one
    // Home leads with.
    if (await _tapKey(tester, 'home_new_song')) {
      expect(tester.takeException(), isNull,
          reason: _why('the new song flow'));
    }
  });

  testWidgets('recording is one tap from every tab', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    // The Studio's one capability nothing else had was recording something
    // with no home yet, and that is a button rather than a destination. It
    // has to be reachable from all three tabs, or it has simply been buried
    // deeper than the tab it replaced.
    for (final tab in <String>['Home', 'Songs', 'Open Mic']) {
      await _tapText(tester, tab);
      expect(find.byKey(const Key('shell_record_button')), findsOneWidget,
          reason: 'no record button on $tab');
    }

    // What the button does now: makes a song and opens its sheet. There is no
    // holding pen in between, which is the whole of retiring studio_drafts —
    // the conversion step was where a song once forked into two projects with
    // the same name and half the words each.
    expect(await _tapKey(tester, 'shell_record_button'), isTrue);
    expect(tester.takeException(), isNull, reason: _why('the song sheet'));
    expect(find.byType(SongAnalysisScreen), findsOneWidget,
        reason: 'the record button did not open a song');
  });

  testWidgets('the song sheet queue is a filter, not a destination',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    await _tapText(tester, 'Songs');
    // The Control Room's two piles, now questions asked of one list. Sets
    // joins them rather than sitting at the weight of the whole library.
    for (final chip in <String>[
      'All',
      'Ideas',
      'Needs a sheet',
      'Has a sheet',
      'Sets'
    ]) {
      final finder = find.text(chip);
      expect(finder, findsOneWidget, reason: '$chip chip is gone');
      // Scrolled into view first. The row scrolls sideways on a small phone
      // with large text, and a chip that has to be reached is still a chip —
      // one that was never built would not be.
      await tester.ensureVisible(finder);
      await _frames(tester);
      await tester.tap(finder, warnIfMissed: false);
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: _why('the $chip filter'));
    }
  });

  testWidgets('Open Mic has both halves, and the songs one draws',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    await _tapText(tester, 'Open Mic');
    expect(tester.takeException(), isNull, reason: _why('Open Mic'));

    // Two things are on an open mic: who is here, and what is being played.
    // It only knew about the first until the public song page existed.
    expect(find.text('People'), findsOneWidget);
    expect(find.text('Songs'), findsWidgets);

    // Targeted, not by text: "Songs" is also the name of a tab, and the
    // tolerant helper taps the last match — which switched tab instead and
    // made this test pass by looking at the wrong screen.
    final songsSegment = find.descendant(
      of: find.byType(SegmentedButton<bool>),
      matching: find.text('Songs'),
    );
    expect(songsSegment, findsOneWidget);
    await tester.tap(songsSegment);
    await _frames(tester);
    expect(tester.takeException(), isNull,
        reason: _why('the songs half of Open Mic'));

    // Cards lead with what a song is asking for, because that is the only
    // thing that decides whether somebody taps. A list of titles is a list
    // nobody can act on.
    expect(find.textContaining('Asking for'), findsWidgets,
        reason: 'a song on the Open Mic did not say what it wants');

    expect(await _tapText(tester, 'Ladder Of Life'), isTrue);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull, reason: _why('an Open Mic song'));
    expect(find.byType(OpenMicSongScreen), findsOneWidget,
        reason: 'tapping a song did not open it');
    expect(find.text('Offer to play on this'), findsOneWidget,
        reason: 'the song page had no way to answer it');
  });

  testWidgets('Home shows something happening, or offers the first move',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    // The app's pulse. Before this, Home reflected you back at yourself —
    // which for a new account is a blank screen, and on a quiet week is one
    // for everybody else too.
    expect(await _reveal(tester, find.text('Happening now')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: _why('Happening now'));

    // Either there is something, or there is an invitation. Never nothing.
    // Scrolled to, because the rows sit under the heading and a lazy list
    // does not build what is off-screen.
    await _reveal(tester, find.textContaining('asking for'));
    final somethingUp = find.textContaining('asking for');
    final invitation = find.text('Nobody is up here yet');
    expect(
      somethingUp.evaluate().isNotEmpty || invitation.evaluate().isNotEmpty,
      isTrue,
      reason: 'Home had a section with neither content nor an offer in it',
    );
  });

  testWidgets('the app says its own name in full', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.0);

    // Not an overflow test — that one already passes. This is the failure the
    // overflow check cannot see: content that fits because it was truncated.
    //
    // The header once read "CoL…" on a phone with obvious empty space beside
    // it, because the wordmark and a Spacer were both flex children and split
    // the free space between them. Nothing overflowed. It was simply an app
    // whose own name was cut off on its first screen, which is worse than the
    // overflow that fix was for.
    final wordmark = find.descendant(
      of: find.byType(BrandMark),
      matching: find.byType(RichText),
    );
    expect(wordmark, findsWidgets, reason: 'the wordmark is not on Home');

    final paragraph = tester.renderObject<RenderParagraph>(wordmark.first);
    final markWidth = tester.getSize(find.byType(BrandMark).first).width;
    final wanted = paragraph.getMaxIntrinsicWidth(double.infinity);
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      // Measured, not asserted blind. The first attempt at this fix was
      // reasoned about rather than measured and was wrong, so the failure
      // says what the widths actually were.
      reason: 'the wordmark is truncated. BrandMark got ${markWidth}px, '
          'the text was given ${paragraph.size.width}px and wanted ${wanted}px',
    );
  });
}
