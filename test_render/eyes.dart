// Somewhere to actually look at this app.
//
// The suite in `test/` is strong and blind in one specific way: it asserts
// that Flutter did not *complain*. That catches overflow and it catches
// crashes, and it caught neither of the last two things reported by
// screenshot — a workspace where the lyrics sat in a column of their natural
// measure with a thousand pixels of empty navy beside them, and a navigation
// rail spending 116 pixels to hold two words. Nothing threw. Both shipped.
//
// Cramped, empty, ugly and cut-off are not exceptions. They are pictures, and
// some of them are numbers. So this renders the app at the sizes it actually
// runs at, with the real fonts, and writes the results somewhere they can be
// looked at and measured.
//
// Lives outside `test/` on purpose: `flutter test` with no arguments walks
// `test/` only, so CI never pays for this and it never fails a build over a
// pixel. Run it deliberately:
//
//     flutter test test_render/
//
// and read `build/eyes/`.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:colabroom/app/bundled_fonts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A screen, captured, with the name it should be filed under.
class Shot {
  Shot(this.name, this.image);

  final String name;
  final ui.Image image;
}

/// A size the app is actually asked to draw itself into.
class Device {
  const Device(this.name, this.size, {this.textScale = 1.0});

  final String name;
  final Size size;
  final double textScale;

  /// Safe for a directory name on every platform this repo is built on.
  String get slug => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
}

/// The screens this app is judged at.
///
/// Phones because that is where the users are, three of them with the text
/// turned up because that is who this is for, and the wider ones because that
/// is where every recent complaint has been and where the existing suite has
/// never once looked: it runs at 360x690 and 390x844 and nothing else, so a
/// desk layout could be anything at all and pass.
const List<Device> kDevices = <Device>[
  Device('Small phone', Size(360, 690)),
  Device('iPhone', Size(390, 844)),
  // A size a lot of people over fifty are already reading at.
  Device('iPhone at 1.3x text', Size(390, 844), textScale: 1.3),
  // Large text, and then the largest text this app can be asked to draw.
  //
  // Every Musician, Same Song, 17 September 2026: the phone's own text size is
  // honoured, never clamped. ColabRoomApp used to hold the system scale down
  // to 1.3, so neither of these could exist.
  //
  // 3.12 and not "a little over 2x": iOS's five accessibility sizes reach
  // Flutter as 1.64, 1.94, 2.35, 2.76 and 3.12, so judging the app at 2.0 left
  // three real settings above the top of the range — and the first strip on
  // the landing tab ran off the bottom at 2.35 while 2.0 looked clean. 2.0
  // stays as well: it is the size most of this work was drawn against, and a
  // regression there is worth seeing on its own.
  //
  // A screen that overflows on either is a screen a partially sighted
  // musician cannot read, and it is what ADA Title II and WCAG 2.1 AA ask
  // about first.
  Device('iPhone at 2x text', Size(390, 844), textScale: 2.0),
  Device('iPhone at 3.12x text', Size(390, 844), textScale: 3.12),
  Device('Tablet', Size(834, 1112)),
  Device('Laptop', Size(1440, 900)),
  // A desk with the text turned up, which nothing here had ever looked at:
  // every large-text device was a phone, so a header that clips four pixels
  // off a room's name on a laptop at 1.3 went unreported for as long as it
  // has existed.
  Device('Laptop at 1.3x text', Size(1440, 900), textScale: 1.3),
  Device('Desk', Size(1920, 1080)),
];

/// Where the app is anchored so it can be photographed.
///
/// A widget test's render tree is rooted at a RenderView, which cannot hand
/// back an image. A RepaintBoundary can, so the app gets wrapped in one — and
/// in nothing else, because MaterialApp builds its own MediaQuery from the
/// test window and anything wrapped out here is silently discarded.
final GlobalKey rootKey = GlobalKey();

// ---------------------------------------------------------------- real fonts

bool _fontsLoaded = false;

/// Loads the fonts the app actually draws with.
///
/// Without this every screen renders as boxes. `flutter test` ships no font
/// data at all — text lays out at roughly the right size and paints as a
/// filled rectangle, which is useless for looking at and worse than useless
/// for measuring, because the layout is *nearly* right and the picture looks
/// like a redacted document rather than a bug.
///
/// Roboto and MaterialIcons both sit in the SDK's own cache, so there is
/// nothing to vendor and nothing to keep in sync with a pubspec.
///
/// The app's own face is the exception and is handled first. Analyze titles
/// itself in Fraunces, which `google_fonts` used to fetch from
/// fonts.gstatic.com at first use — and a fetch in a test throws as a raw zone
/// error, outside `FlutterError.onError`, where nothing below could sort it
/// out of the findings. Every device that walked as far as Analyze failed on
/// it, so this harness exited non-zero whatever the app did and a run had to
/// be judged by reading `build/eyes/REPORT.md` instead. The face is an asset
/// now; `useBundledFonts` points google_fonts at it and forbids fetching, so
/// the walk draws the real heading and the exit code means something again.
Future<void> loadRealFonts() async {
  useBundledFonts();

  if (_fontsLoaded) return;
  _fontsLoaded = true;

  final root = _flutterRoot();
  if (root == null) {
    debugPrint('eyes: no FLUTTER_ROOT — screens will render as boxes');
    return;
  }
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) {
    debugPrint('eyes: no material_fonts at ${dir.path}');
    return;
  }

  // Every weight under one family name, which is how the engine expects to be
  // given a family: it picks the face by the weight the style asks for.
  // Registering only regular makes every w600 heading synthesise a fake bold,
  // and then the picture stops matching the device it claims to be.
  await _register('Roboto', dir, const <String>[
    'roboto-thin.ttf',
    'roboto-light.ttf',
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-black.ttf',
    'roboto-italic.ttf',
    'roboto-bolditalic.ttf',
  ]);
  // The icon font. Without it every icon is a hollow box, and an app
  // photographed with no icons is not the app.
  await _register('MaterialIcons', dir, const <String>[
    'materialicons-regular.otf',
  ]);
}

Future<void> _register(String family, Directory dir, List<String> files) async {
  final loader = FontLoader(family);
  var found = 0;
  for (final name in files) {
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) continue;
    found += 1;
    final bytes = file.readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
  }
  if (found == 0) {
    debugPrint('eyes: found no faces for $family in ${dir.path}');
    return;
  }
  await loader.load();
}

/// The SDK, from the environment the tool sets, or from the VM running us.
///
/// `flutter test` exports FLUTTER_ROOT. Anything else running this file does
/// not, so fall back to walking up from the Dart executable, which lives at
/// `<root>/bin/cache/dart-sdk/bin/dart`.
String? _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i += 1) {
    if (Directory('${dir.path}/bin/cache/artifacts/material_fonts')
        .existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

// ------------------------------------------------------------ the platform

/// Answers the plugins the app talks to, so screens behave rather than throw.
///
/// Two reasons, and the second is the important one. The noise is annoying —
/// eight MissingPluginExceptions per run, every one of them the harness's
/// fault. But a screen whose player throws on creation renders its *error*
/// state, and then the picture is a photograph of a failure that happens
/// nowhere but here. Answering with null gets the real screen.
void stubPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in const <String>[
    'xyz.luan/audioplayers.global',
    'com.llfbandit.record/messages',
    'plugins.flutter.io/path_provider',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  // The player channel, answered by hand rather than with the rest, because
  // answering it is also the only chance to answer the channel it is about to
  // create.
  //
  // Each AudioPlayer gets its own event channel named
  // `xyz.luan/audioplayers/events/<uuid>`, and the uuid is made by the app at
  // the moment the player is constructed — so there is no name to register in
  // advance, and `setMockStreamHandler` takes an exact name with no wildcard.
  // Left unanswered the player threw MissingPluginException while activating
  // its stream, which is what failed 'Profile phone' on a screen where nothing
  // was wrong with the app.
  //
  // The hook is reliable rather than lucky: audioplayers calls `create` on
  // this channel with the playerId and *awaits* it before subscribing
  // (AudioPlayer._create → AudioplayersPlatform.create → createEventStream),
  // so a handler registered here is always in place before the listen.
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (MethodCall call) async {
      if (call.method == 'create') {
        final Object? arguments = call.arguments;
        final Object? playerId =
            arguments is Map ? arguments['playerId'] : null;
        if (playerId is String) {
          messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$playerId'),
            MockStreamHandler.inline(
              onListen: (Object? args, MockStreamHandlerEventSink sink) {},
            ),
          );
        }
      }
      return null;
    },
  );

  messenger.setMockStreamHandler(
    const EventChannel('xyz.luan/audioplayers.global/events'),
    MockStreamHandler.inline(
      onListen: (Object? args, MockStreamHandlerEventSink sink) {},
    ),
  );
}

// ----------------------------------------------------------------- shadows

/// Runs [body] with shadows drawn, and puts them back before it returns.
///
/// The binding turns shadows off so goldens stay stable across platforms.
/// These images are for looking at rather than diffing, and an app
/// photographed without its elevation is flatter than the real thing — so the
/// harness turns them back on.
///
/// It has to be per test, and it has to be inside the body.
/// `debugDisableShadows` is one of the painting debug variables, and the
/// framework checks that all of them are back at their defaults at the end of
/// every test body — before it runs any tearDown. Set in `setUpAll` and
/// restored in `tearDownAll`, the check fires on every test with "the value of
/// a painting debug variable was changed by the test", which reads like a
/// rendering fault and is nothing of the kind: it failed all eight welcome
/// shots and both profile shots, on screens where nothing at all was wrong
/// with the app.
///
/// `finally` rather than two statements, so a body that throws still leaves
/// the flag as it found it and the *next* test fails for its own reasons rather
/// than for this one's. the_app_test.dart and the_strip_test.dart do the same
/// thing inline.
Future<void> withShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}

// -------------------------------------------------------------- complaints

/// Everything Flutter objected to during the walk.
final List<FlutterErrorDetails> complaints = <FlutterErrorDetails>[];

/// Plugins that are simply not present in a headless test.
///
/// Kept separately and reported as a caveat rather than a defect. audioplayers
/// and record both talk to a platform that does not exist here, and calling
/// that an app bug would be the harness accusing the app of the harness's own
/// limitation — which is worse than saying nothing, because somebody would
/// eventually go looking for it.
final Set<String> absentPlugins = <String>{};

/// Collects rather than aborts.
///
/// The exit code means something again, which it did not until the Fraunces
/// face was bundled. The Analyze screen titles itself in Fraunces, which
/// `google_fonts` used to fetch from fonts.gstatic.com at first use; there is
/// no network in a test, so it threw, and it threw as a raw zone error that
/// reached flutter_test directly rather than through `FlutterError.onError`,
/// where nothing here could sort it out of the findings. Every device that
/// walked as far as Analyze failed on it, so a run had to be judged by reading
/// the sheets and `build/eyes/REPORT.md` rather than by whether it passed —
/// which is a bad habit to ask of the one tool meant to say something is
/// wrong. The face is an asset now (`useBundledFonts`), so a failure here is
/// the app's again.
///
/// The suite in `test/` is a gate and is supposed to stop at the first
/// problem. This one collects instead: a screen that throws is the most
/// interesting thing it could possibly find, and stopping there means never
/// photographing the eleven screens after it. So every complaint is recorded
/// and the walk carries on. Collecting is not forgiving, though — a recorded
/// throw still fails that device's walk at the end of it (see `_broken` in
/// the_app_test.dart), so the walk is complete *and* red.
/// Returns the function that puts the framework's own handler back.
///
/// Chaining matters more than it looks. The binding installs its own
/// `onError` for the duration of a test and asserts, at the end, that what it
/// recorded and what it handled agree. Replacing that handler outright made
/// every real exception invisible to the framework — including "a Timer is
/// still pending", which is how a test says it cannot finish. Swallowing that
/// one turned a clear failure into a walk that hung to its timeout.
///
/// So: everything real goes to the framework as well as into this list, and
/// the walk drains it with `takeException` once it has been recorded.
VoidCallback collectComplaints() {
  final previous = FlutterError.onError;
  complaints.clear();
  absentPlugins.clear();
  FlutterError.onError = (FlutterErrorDetails details) {
    final error = details.exception;
    if (error is MissingPluginException) {
      // Sorted out of the findings — a plugin that does not exist in a
      // headless test is a fact about the harness, and failing the walk over
      // it would mean never photographing any screen that plays a sound.
      absentPlugins.add(error.message ?? 'a platform channel');
    } else {
      complaints.add(details);
    }
    // Handed on regardless, including the ones being ignored. An uncaught
    // async error arrives through the binding's own `handleUncaughtError`,
    // which asserts immediately afterwards that *something* recorded it —
    // so a handler that quietly drops one crashes the test with a message
    // about `expect()` that has nothing to do with the real cause.
    previous?.call(details);
  };
  return () => FlutterError.onError = previous;
}

/// Whether a complaint is a box that could not hold what was put in it.
///
/// Every overflow in Flutter, whatever render object noticed it, is reported
/// through the one helper that draws the yellow stripes, and every one of its
/// messages reads "A RenderFlex overflowed by 14 pixels on the right" — so the
/// phrase is the reliable thing to match on rather than the class name.
///
/// Told apart from the rest so that it reads as itself in the report. It is
/// not the only thing the walk fails on — a build that threw does too — but it
/// is the one with a name somebody can act on, and since the reader's own text
/// size stopped being clamped it is the failure that would come back first.
bool isOverflow(FlutterErrorDetails details) =>
    details.exception.toString().contains('overflowed by');

/// Hands back what has been collected since the last call, and clears it.
List<FlutterErrorDetails> drainComplaints() {
  final taken = <FlutterErrorDetails>[...complaints];
  complaints.clear();
  return taken;
}

// -------------------------------------------------------------------- taking
//
// Everything in this section touches the engine, and the engine does not run
// on the fake clock a widget test lives on. `boundary.toImage()` hands back a
// Future that the test's `FakeAsync` will never complete, so a plain `await`
// on it hangs the test until its timeout — which looks like the app being
// slow and is actually the harness deadlocking against itself.
//
// Every caller therefore wraps these in `tester.runAsync`, which is the same
// thing `matchesGoldenFile` does for the same reason.

/// Photographs whatever is on screen.
Future<ui.Image> take(WidgetTester tester) async {
  final boundary =
      rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return boundary.toImage();
}

/// The raw pixels, so a rule can look at what was actually drawn.
///
/// RGBA, four bytes per pixel, row-major. The view is pinned to a device
/// pixel ratio of 1.0, so an index here is a logical pixel and every
/// measurement can be compared with a widget's own geometry directly.
Future<Uint8List?> rawPixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data?.buffer.asUint8List();
}

/// Writes one image to `build/eyes/<folder>/<name>.png`.
Future<File> writePng(ui.Image image, String folder, String name) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('build/eyes/$folder')..createSync(recursive: true);
  final file = File('${dir.path}/$name.png');
  file.writeAsBytesSync(data!.buffer.asUint8List(), flush: true);
  return file;
}

// ------------------------------------------------------------- contact sheet

/// Every shot from one walk, on one page.
///
/// Sixty separate PNGs is a directory nobody opens. One sheet per device is a
/// thing somebody looks at for a second and immediately sees which screen is
/// wrong — which is the entire point of rendering any of this.
Future<File> contactSheet(
  List<Shot> shots, {
  required String folder,
  required String title,
  String name = '_sheet',
  int columns = 4,
  double thumbWidth = 320,
}) async {
  if (shots.isEmpty) {
    throw StateError('contactSheet was given nothing to draw');
  }
  const gutter = 18.0;
  const labelHeight = 26.0;
  const titleHeight = 46.0;
  const pad = 20.0;

  // Screens from one walk are all the same shape, so one scale does for all
  // of them and every thumbnail on the sheet stays comparable.
  final scale = thumbWidth / shots.first.image.width;
  final thumbHeight = shots.first.image.height * scale;
  final rows = (shots.length / columns).ceil();

  final width = pad * 2 + columns * thumbWidth + (columns - 1) * gutter;
  final height = pad * 2 +
      titleHeight +
      rows * (thumbHeight + labelHeight) +
      (rows - 1) * gutter;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF12141A),
  );

  _paintText(canvas, title, const Offset(pad, pad),
      width: width, size: 20, weight: FontWeight.w700);

  for (var i = 0; i < shots.length; i += 1) {
    final column = i % columns;
    final row = i ~/ columns;
    final x = pad + column * (thumbWidth + gutter);
    final y = pad + titleHeight + row * (thumbHeight + labelHeight + gutter);
    final shot = shots[i];

    final dst = Rect.fromLTWH(x, y, thumbWidth, thumbHeight);
    canvas.drawImageRect(
      shot.image,
      Rect.fromLTWH(
          0, 0, shot.image.width.toDouble(), shot.image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    // A hairline, so a screen whose own background is dark still reads as a
    // rectangle rather than bleeding into the sheet.
    canvas.drawRect(
      dst,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x33FFFFFF),
    );
    _paintText(canvas, shot.name, Offset(x, y + thumbHeight + 6),
        width: thumbWidth, size: 13, weight: FontWeight.w600);
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.ceil(), height.ceil());
  return writePng(image, folder, name);
}

void _paintText(
  Canvas canvas,
  String text,
  Offset at, {
  required double width,
  required double size,
  required FontWeight weight,
}) {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
    fontFamily: 'Roboto',
    fontSize: size,
    fontWeight: weight,
    maxLines: 1,
    ellipsis: '…',
  ))
    ..pushStyle(ui.TextStyle(color: const Color(0xFFE8EAF0)))
    ..addText(text);
  final paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: width));
  canvas.drawParagraph(paragraph, at);
}
