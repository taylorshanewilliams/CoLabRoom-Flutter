import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/auth/supabase_auth_screen.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The text is the size your phone says it is.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. ColabRoomApp used to hold the system scale
/// between 0.8 and 1.3, so somebody who had set the largest size on their
/// phone — which is the whole of how a partially sighted musician reads
/// anything — was handed a *smaller* one here than their phone promised. That
/// clamp is what gates every public school and university: ADA Title II and
/// WCAG 2.1 AA §1.4.4 both ask this question first.
///
/// So the two halves of it are asserted here. That the app passes the
/// reader's scale through untouched, and that the screens in this slice — the
/// three tabs, the inbox, the account screen, a profile and sign-in — can be
/// drawn at twice normal without Flutter complaining. Overflow is an
/// exception in a widget test, so `takeException` catches the yellow stripes
/// as well as the crashes.
///
/// 2.0 rather than 1.3, and 2.0 rather than some number nobody can name: it
/// is roughly where iOS's accessibility sizes land, and it is what
/// `test_render/` now renders the whole app at.
/// Everything Flutter complained about since the last boot, in full — the
/// one-line summary alone costs an investigation to locate.
final List<FlutterErrorDetails> _complaints = <FlutterErrorDetails>[];

String _why(String what) {
  if (_complaints.isEmpty) return '$what did not draw';
  final first = _complaints.first.toString();
  final detail = first.length > 2600 ? first.substring(0, 2600) : first;
  return '''$what did not draw:

$detail''';
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

/// A phone of a given size, with its text set to [textScale], and every
/// complaint recorded.
///
/// Both settings go on the view and the dispatcher rather than into a
/// MediaQuery wrapped around whatever is pumped: MaterialApp builds its own
/// MediaQuery from the test window, so anything wrapped outside is discarded
/// and every "large text" case would silently run at 1.0.
void _phone(
  WidgetTester tester, {
  required double textScale,
  Size size = const Size(390, 844),
}) {
  _complaints.clear();
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _complaints.add(details);
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// The whole app, signed in, on that phone.
Future<void> _boot(
  WidgetTester tester, {
  required double textScale,
  Size size = const Size(390, 844),
}) async {
  _phone(tester, textScale: textScale, size: size);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(CoLabRoomApp.preview(controller: controller));
  await _frames(tester);
}

/// One screen on its own, for the two that the signed-in app never reaches.
Future<void> _bootScreen(
  WidgetTester tester,
  Widget screen, {
  required double textScale,
}) async {
  _phone(tester, textScale: textScale);
  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: screen,
  ));
  await _frames(tester);
}

/// What the app actually believes it is drawing text at.
TextScaler _scalerInside(WidgetTester tester) {
  return tester
      .widget<MediaQuery>(
        find
            .descendant(
              of: find.byType(MaterialApp),
              matching: find.byType(MediaQuery),
            )
            .first,
      )
      .data
      .textScaler;
}

/// Back to the shell, however deep this is.
///
/// A single pop off the first Navigator is not enough: a pushed screen can
/// open a sheet of its own, and a walk left one route down finds none of the
/// controls it is looking for and says the screen is missing.
Future<void> _popToRoot(WidgetTester tester) async {
  for (var i = 0; i < 6; i += 1) {
    if (find.byType(Navigator).evaluate().isEmpty) return;
    final state = tester.state<NavigatorState>(find.byType(Navigator).last);
    if (!state.canPop()) return;
    state.pop();
    await _frames(tester);
  }
}

Future<bool> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

void main() {
  testWidgets('the app draws text at the size the phone asked for',
      (tester) async {
    await _boot(tester, textScale: 2.0);

    // The assertion the clamp used to fail. 0.8-1.3 turned a 2.0 reader into
    // a 1.3 one, silently, on every screen.
    expect(
      _scalerInside(tester).scale(10),
      20,
      reason: 'the app is clamping the text size the phone asked for',
    );
  });

  testWidgets('a reader who turned their text down gets what they asked for',
      (tester) async {
    // The other end of the same clamp, and the one nobody thinks about: it
    // had a floor of 0.8, so somebody who wanted more on screen at once was
    // overruled too.
    await _boot(tester, textScale: 0.5);
    expect(_scalerInside(tester).scale(10), 5);
  });

  testWidgets('the tab labels grow with the text rather than being shrunk',
      (tester) async {
    // Not an overflow test — that one passes either way, which is the whole
    // problem. The bar held a fixed 56-pixel column and a FittedBox scaled
    // every label back down into it, so the app looked fine in a screenshot
    // and drew three eleven-point words at somebody who had asked for
    // twenty-two. Nothing is shrunk to fit.
    //
    // Open Mic rather than Your music: the second is also the heading of the
    // tab the app opens on, and the tab itself is what is being measured.
    await _boot(tester, textScale: 1.0);
    expect(find.text('Open Mic'), findsOneWidget);
    final small = tester.getSize(find.text('Open Mic'));

    await _boot(tester, textScale: 2.0);
    expect(find.text('Open Mic'), findsOneWidget);
    final large = tester.getSize(find.text('Open Mic'));

    expect(
      large.height,
      greaterThan(small.height * 1.6),
      reason: 'the tab label was ${small.height} tall at 1x and '
          '${large.height} at 2x — it is being scaled back down to fit',
    );
  });

  testWidgets('every tab holds at the largest text size', (tester) async {
    await _boot(tester, textScale: 2.0);
    expect(tester.takeException(), isNull, reason: _why('the first tab'));

    for (final tab in <String>['Open Mic', 'Messages', 'Your music']) {
      expect(await _tapText(tester, tab), isTrue, reason: '$tab is gone');
      expect(tester.takeException(), isNull, reason: _why(tab));
    }
  });

  testWidgets('the inbox and the account screen hold at the largest text size',
      (tester) async {
    await _boot(tester, textScale: 2.0);

    // Both are in the top bar and both are an InkResponse rather than a
    // keyed button, so they are reached the way a screen reader reaches
    // them: by the name they announce.
    for (final label in <String>['Notifications', 'Account']) {
      final control = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      );
      expect(control, findsWidgets, reason: 'nothing labelled "$label"');
      await tester.tap(control.last, warnIfMissed: false);
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: _why(label));

      await _popToRoot(tester);
    }
  });

  testWidgets('a profile page holds at the largest text size', (tester) async {
    // Somebody else's, which is the version most people see, and the one
    // carrying the most: a face, what they play, where they are, and the
    // three sections under it.
    await _bootScreen(
      tester,
      MusicianProfileScreen(
        profileId: 'preview-mara',
        repository: InMemoryMusicRepository.seeded(),
      ),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull, reason: _why('a profile'));
  });

  testWidgets('the sign-in screen holds at the largest text size',
      (tester) async {
    // Never reached by CoLabRoomApp.preview, which is already signed in, and
    // it is the one screen in the app somebody who has never used it sees
    // first. The client is never called: this screen only talks to it when
    // somebody presses a button.
    //
    // Made outside the test's fake clock, and that is not a detail. A real
    // client starts a ten-second timer to refresh a session it does not have;
    // made in here that is a *fake* timer, and the test fails with "A Timer is
    // still pending even after the widget tree was disposed" — which reads
    // like the screen leaking something and is the client being a client.
    final client = (await tester.runAsync(() async => SupabaseClient(
          'https://example.supabase.co',
          'anon-key-for-a-test',
        )))!;
    addTearDown(() => tester.runAsync(client.dispose));

    await _bootScreen(
      tester,
      SupabaseAuthScreen(client: client),
      textScale: 2.0,
    );

    expect(tester.takeException(), isNull, reason: _why('sign in'));

    // And the way in for somebody who has no account yet, which is a
    // different layout: a name field, an age-and-terms checkbox with two
    // links in the sentence, and a second button.
    if (await _tapText(tester, 'Create an account')) {
      expect(tester.takeException(), isNull, reason: _why('create an account'));
    }
  });
}
