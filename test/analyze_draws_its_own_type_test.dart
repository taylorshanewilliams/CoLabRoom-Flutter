import 'dart:convert';
import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/bundled_fonts.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/song_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Analyze draws its heading from the app's own assets, never from a request.
///
/// The heading on a finished song sheet is set in Fraunces, and `google_fonts`
/// fetches a face from fonts.gstatic.com the first time it is asked for. That
/// put a network round trip behind the one line on the screen where the app
/// hands back the chords somebody has just sung — on a screen people open in a
/// rehearsal room with no signal. On a device the fetch usually succeeds and
/// nothing looks wrong, which is why this went unnoticed; offline the heading
/// quietly became a different typeface, and under `test_render/` the failed
/// fetch arrived as a raw zone error that no handler could sort out, so the
/// whole render harness exited non-zero whatever the app did.
///
/// `google_fonts/Fraunces-Medium.ttf` is in the bundle now, and
/// `useBundledFonts` turns runtime fetching off. Both halves are asserted
/// here, because either one alone would let the bug back: without the asset
/// the screen throws, and without the flag a missing asset would silently go
/// back to fetching.
void main() {
  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('the Analyze heading is drawn with the bundled face',
      (tester) async {
    // Every HttpClient this test's zone hands out, counted. google_fonts
    // fetches through `package:http`, which on the VM is an IOClient over
    // `HttpClient` — so a client asked for here is a fetch attempted, and
    // that is the thing this test is really about. flutter_test installs its
    // own override that answers 400, which would make a fetch *look* like a
    // tidy failure rather than the network dependency it is.
    final asked = <String>[];
    final previous = HttpOverrides.current;
    HttpOverrides.global = _CountingHttpOverrides(asked);
    addTearDown(() => HttpOverrides.global = previous);

    resetBundledFontsForTest();
    useBundledFonts();
    expect(GoogleFonts.config.allowRuntimeFetching, isFalse,
        reason: 'useBundledFonts should forbid fetching a face at runtime');

    // Where google_fonts actually looks, asserted before the screen is built.
    //
    // It scans the asset manifest for an entry ending `<Family>-<Variant>`
    // and loads that through `rootBundle` instead of fetching. Checked here,
    // and first, because of how it fails otherwise: with the asset gone the
    // load falls through to path_provider, which no headless test answers, and
    // the whole thing *hangs* rather than throwing. A missing font should say
    // so in a line, not run a suite into its timeout.
    // Read inside `runAsync` and asserted outside it, which matters: an
    // `expect` that fails *inside* runAsync does not end the test, it hangs
    // it, and the suite then stops on a ten-minute timeout with no message.
    final List<String>? assets = await tester.runAsync(() async {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return manifest.listAssets();
    });
    expect(assets, contains('google_fonts/Fraunces-Medium.ttf'),
        reason: 'the face Analyze asks for is not in the asset bundle, so the '
            'heading would be fetched — or, with fetching off, throw');

    final int? length = await tester.runAsync<int?>(() async {
      try {
        final ByteData data =
            await rootBundle.load('google_fonts/Fraunces-Medium.ttf');
        return data.lengthInBytes;
      } catch (_) {
        return null;
      }
    });
    expect(length, 71572,
        reason: 'the bundled face should be the one google_fonts would '
            'otherwise download, byte for byte');

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    final SongProject project = controller.projects.first;

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: BetaScope(
        controller: controller,
        child: SongAnalysisScreen(project: project),
      ),
    ));
    await tester.pump();

    // The heading is the one thing on this screen set in Fraunces, so it is
    // found by its face rather than by its words — which change with the
    // state of the sheet (the song's name once it is ready, the recording's
    // name while it is working, an invitation to add one before that).
    final List<Text> inFraunces = tester
        .widgetList<Text>(find.byType(Text))
        .where((Text text) =>
            text.style?.fontFamily != null &&
            text.style!.fontFamily!.startsWith('Fraunces'))
        .toList();
    expect(inFraunces, hasLength(1),
        reason: 'Analyze should set exactly its heading in Fraunces');

    final TextStyle style = inFraunces.single.style!;
    // Two different spellings of the same weight, and they are easy to mix
    // up. google_fonts names the *loaded family* `<Family>_<apiVariant>`, so
    // w500 is `Fraunces_500`; it looks for the *asset* under
    // `<Family>-<filenameVariant>`, where the same weight is spelled
    // `Fraunces-Medium`. The bare family is the fallback.
    expect(style.fontFamily, 'Fraunces_500');
    expect(style.fontFamilyFallback, contains('Fraunces'));
    // A seeded song has no reference recording yet, so this is the heading
    // before anything has been analysed.
    expect(inFraunces.single.data, 'Add a reference recording');

    // The load itself, which with the asset in place completes off the bundle.
    await tester.runAsync(() => GoogleFonts.pendingFonts());

    expect(asked, isEmpty,
        reason: 'drawing the Analyze heading asked for an HTTP client, so the '
            'face is still being fetched rather than read from the bundle: '
            '$asked');

    // Taken down inside the body: the framework checks for leaked timers
    // before it runs tearDowns, and this screen starts them.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('every face the app asks for is in the bundle', () {
    // The rule `allowRuntimeFetching = false` enforces at runtime, checked
    // here against the source instead, so it fails in CI rather than on
    // somebody's screen. A `GoogleFonts.x()` call whose file is not in
    // `google_fonts/` throws when that screen is opened.
    final bundled = Directory('google_fonts')
        .listSync()
        .whereType<File>()
        .map((File file) => file.uri.pathSegments.last)
        .where((String name) => name.endsWith('.ttf') || name.endsWith('.otf'))
        .toList();

    expect(bundled, contains('Fraunces-Medium.ttf'));

    final calls = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Comments stripped first: bundled_fonts.dart explains this very rule
      // and names `GoogleFonts.x()` while doing it. A comment describing the
      // mistake should not read as the mistake — the same reason
      // button_labels_keep_their_font_test.dart strips them.
      final source = _withoutComments(entity.readAsStringSync());
      for (final match
          in RegExp(r'GoogleFonts\.([a-zA-Z0-9_]+)\(').allMatches(source)) {
        final name = match.group(1)!;
        // `GoogleFonts.config` is the settings object, not a typeface.
        if (name == 'config' || name == 'pendingFonts') continue;
        calls.add(name);
      }
    }

    expect(calls, <String>{'fraunces'},
        reason: 'A face is asked for that may not be bundled. Add its file to '
            'google_fonts/ (named <Family>-<Variant>.ttf) and list it here, '
            'or the screen that uses it throws when it is opened: $calls');
  });

  test('the font licence travels with the font', () {
    // The SIL Open Font License asks for its notice to be distributed with the
    // face. useBundledFonts reads this file into Flutter's licence page.
    final licence = File('google_fonts/OFL.txt');
    expect(licence.existsSync(), isTrue,
        reason: 'Fraunces is under the OFL; its notice has to ship with it');
    expect(licence.readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
  });
}

/// [source] with its `//` and `///` comments taken out.
String _withoutComments(String source) {
  final out = StringBuffer();
  for (final line in const LineSplitter().convert(source)) {
    final at = line.indexOf('//');
    out.writeln(at == -1 ? line : line.substring(0, at));
  }
  return out.toString();
}

/// Hands out clients that refuse, and writes down that it was asked.
///
/// Refusing rather than counting quietly: if anything here does try to fetch,
/// the test should say which URL it wanted.
class _CountingHttpOverrides extends HttpOverrides {
  _CountingHttpOverrides(this.asked);

  final List<String> asked;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    asked.add(StackTrace.current.toString().split('\n').first);
    throw StateError('this test asked for no network');
  }
}
