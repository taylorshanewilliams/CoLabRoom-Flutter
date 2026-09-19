import 'dart:io';

import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:colabroom/widgets/note_that_fits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Every note the app says lands on the screen, not only Perform's three.
///
/// The app's theme makes every snackbar floating, and a floating snackbar is
/// positioned upwards from whichever is higher of the record button and the
/// tab bar. It is as tall as its words, so at the largest iOS accessibility
/// text size — 3.12x, a real phone somebody is holding — a long sentence runs
/// out of room: Flutter throws "Floating SnackBar presented off screen" while
/// it lays out in debug, and in release, where that assertion is gone, draws
/// the box where nobody can see it.
///
/// Perform's three notes were wrapped one at a time (#407) and the other 113
/// were left holding the same bug. Wrapping those 113 would have left the
/// 114th, so instead there is one door: [SayIt.showNote] is the only thing in
/// `lib/` that shows a snackbar, and the ceiling is decided there. The last
/// test in this file is what keeps that true.
///
/// **The shell here is the real one.** The first version of this file stood a
/// record button over a Material tab bar and called that near enough, and it
/// was not: what a note has to fit into is the screen minus the app's own
/// bottom furniture, and the real furniture is taller — taller again once the
/// now-playing bar is up, which is when a 375x667 phone at 3.12x was still
/// drawing the note off the top of itself. The app is booted for real here,
/// and the note has to land with the now-playing bar's own height to spare.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. The ceiling is on the box, never on the type.
void main() {
  /// One of the longest sentences the app actually says, and one somebody
  /// only ever reads because something has already gone wrong: a server that
  /// refused a sign-in as if it came from the future. `reportAndDescribe`
  /// hands this to a snackbar, and this is the sentence it hands over.
  final String longNote = describeForUser(PostgrestException(
    message: 'JWT issued at future',
    code: 'PGRST303',
  ));

  /// What the now-playing bar takes out of the screen when something is
  /// playing, measured from its own layout: two pixels of progress, eight
  /// above and below, and either a title and a byline at the reader's size or
  /// a 48-pixel button, whichever of those is taller.
  ///
  /// A number here rather than the bar itself, because no widget test can
  /// raise the real one: it appears when `NowPlaying` has a path, and a path
  /// is only ever set by a player that has no plugin behind it in a test. So
  /// the shell below is the real shell with the bar down, and what is
  /// asserted is that a note still leaves this much room above it.
  double nowPlayingBar(double scale) {
    if (scale <= 1.0) return 66;
    if (scale <= 2.0) return 85;
    return 123;
  }

  void phone(WidgetTester tester, Size size, double scale) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    // On the view rather than in a MediaQuery wrapped around the app:
    // MaterialApp builds its own MediaQuery from the test window, so anything
    // wrapped outside is discarded and every large-text case would quietly
    // run at 1.0.
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// The whole app on that phone, and the messenger its shell says things on.
  Future<ScaffoldMessengerState> onTheRealShell(
    WidgetTester tester,
    Size size,
    double scale,
  ) async {
    phone(tester, size, scale);
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    await tester.pumpWidget(CoLabRoomApp.preview(controller: controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    return ScaffoldMessenger.of(
      tester.element(find.byKey(const Key('shell_record_button'))),
    );
  }

  /// Says [note] and waits for the snackbar to finish arriving.
  Future<void> say(
    WidgetTester tester,
    ScaffoldMessengerState on,
    String note, {
    SnackBarAction? action,
    Duration? duration,
  }) async {
    on.showNote(note, action: action, duration: duration);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
  }

  /// Where the snackbar ended up.
  RenderBox theNote(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byType(SnackBar));

  group('a long note lands on the screen, with the now-playing bar to spare',
      () {
    // The phones the app is drawn for: a tall one, the two iPhone shapes
    // people still carry, and the smallest Android the render harness walks.
    const List<Size> phones = <Size>[
      Size(390, 844),
      Size(375, 812),
      Size(375, 667),
      Size(360, 690),
    ];

    for (final size in phones) {
      for (final scale in <double>[1.0, 2.0, 3.12]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} at ${scale}x',
            (tester) async {
          final on = await onTheRealShell(tester, size, scale);
          await say(tester, on, longNote);

          expect(tester.takeException(), isNull,
              reason: 'the snackbar was positioned off the screen');

          final RenderBox note = theNote(tester);
          final double top = note.localToGlobal(Offset.zero).dy;
          expect(top, greaterThanOrEqualTo(nowPlayingBar(scale)),
              reason: 'the note reaches the top of the phone as soon as '
                  'something is playing and the now-playing bar pushes it up');
          expect(top + note.size.height, lessThanOrEqualTo(size.height),
              reason: 'the bottom of the note is below the bottom of the '
                  'phone');
        });
      }
    }
  });

  group('and on the two shapes with barely any room at all', () {
    // A phone held sideways, and a phone from when 320 points was a phone.
    // The furniture takes most of the screen on both, and on the sideways one
    // at the largest text it asks for more than the screen has. They are held
    // to landing on the screen rather than to leaving the now-playing bar
    // spare: a widget test draws the tab bar's labels in a placeholder face
    // taller than the one a phone uses, so the room left here is less than
    // the room a phone has — measured with the real faces loaded, both of
    // these keep the bar's height and more.
    for (final size in <Size>[const Size(320, 568), const Size(844, 390)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} at 3.12x',
          (tester) async {
        final on = await onTheRealShell(tester, size, 3.12);
        await say(tester, on, longNote);

        expect(tester.takeException(), isNull,
            reason: 'the snackbar was positioned off the screen');
        final RenderBox note = theNote(tester);
        final double top = note.localToGlobal(Offset.zero).dy;
        expect(top, greaterThanOrEqualTo(0));
        expect(top + note.size.height, lessThanOrEqualTo(size.height));
      });
    }
  });

  testWidgets('the words are all still there, at the size that was asked for',
      (tester) async {
    // The ceiling is on the box, not on the type: the sentence is laid out at
    // 3.12x and scrolls inside a box that fits. Nothing is shrunk to make it
    // fit, which is the rule the app has for its own text everywhere else.
    final on = await onTheRealShell(tester, const Size(390, 844), 3.12);
    await say(tester, on, longNote);

    final RenderBox words = tester.renderObject<RenderBox>(find.text(longNote));
    expect(words.size.height, greaterThan(theNote(tester).size.height),
        reason: 'at this size the sentence is taller than the box holding it, '
            'so this test is not quietly passing on a note that fits anyway');
    expect(find.byType(SingleChildScrollView), findsOneWidget,
        reason: 'the rest of the sentence has to be reachable');
  });

  testWidgets('a short note at an ordinary size is exactly as it was',
      (tester) async {
    final on = await onTheRealShell(tester, const Size(390, 844), 1.0);
    await say(tester, on, 'Password reset email sent.');

    expect(tester.takeException(), isNull);
    final RenderBox held =
        tester.renderObject<RenderBox>(find.byType(NoteThatFits));
    final RenderBox words =
        tester.renderObject<RenderBox>(find.text('Password reset email sent.'));
    expect(held.size.height, words.size.height,
        reason: 'below the ceiling a note is still exactly as tall as its '
            'words, so nothing about the usual case has changed');
  });

  testWidgets('a short note is its own height on a small phone too',
      (tester) async {
    // The ceiling used to be a fraction of the screen's height, which on a
    // short phone at a large text size left far less room than the phone
    // actually had. What replaced it is the screen minus the furniture, and
    // this is the other end of that: a note nobody needs to worry about is
    // still drawn exactly as tall as its words.
    final on = await onTheRealShell(tester, const Size(320, 568), 1.0);
    await say(tester, on, 'Saved.');

    final RenderBox held =
        tester.renderObject<RenderBox>(find.byType(NoteThatFits));
    final RenderBox words = tester.renderObject<RenderBox>(find.text('Saved.'));
    expect(held.size.height, words.size.height);
  });

  testWidgets('a note keeps its action, and waits for it', (tester) async {
    final on = await onTheRealShell(tester, const Size(390, 844), 1.0);
    var undone = false;
    await say(tester, on, 'Declined. They will be told.',
        action: SnackBarAction(label: 'Undo', onPressed: () => undone = true));

    // A snackbar with an action persists, which is [SnackBar]'s own rule and
    // still has to be the rule here: the button is the whole point of it.
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(SnackBarAction), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undone, isTrue);
  });

  testWidgets('a note stays up for as long as it was going to', (tester) async {
    final on = await onTheRealShell(tester, const Size(390, 844), 1.0);
    await say(tester, on, 'Saved.');
    expect(find.text('Saved.'), findsOneWidget);

    // Four seconds, which is what `SnackBar` does when nobody says otherwise
    // and what all 116 call sites were getting before there was a helper.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Saved.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Saved.'), findsNothing);

    await say(tester, on, 'Saved.', duration: const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Saved.'), findsOneWidget,
        reason: 'a duration asked for is a duration kept');
    on.removeCurrentSnackBar();
    await tester.pumpAndSettle();
  });

  test('the theme still makes every snackbar a floating one', () {
    // Which is the whole reason any of this is needed. A fixed snackbar sits
    // above the tab bar and is never asked to fit anywhere; if the theme ever
    // changes its mind, the allowance in note_that_fits.dart is costing room
    // to dodge a rule that no longer applies to it.
    expect(CoLabRoomTheme.dark().snackBarTheme.behavior,
        SnackBarBehavior.floating);
  });

  /// Asserted against the source, because there is nothing to assert against
  /// at runtime: a call site that builds its own `SnackBar` works perfectly
  /// on every phone whose text is not turned up, and the person it breaks for
  /// is the one who never sees the message that says why.
  ///
  /// A snackbar that genuinely needs something other than a sentence belongs
  /// in `note_that_fits.dart` beside [SayIt.showNote], where whatever it
  /// needs can be given a ceiling too.
  test('nothing in lib shows a snackbar any other way', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/widgets/note_that_fits.dart')) continue;
      final source = _withoutComments(entity.readAsStringSync());
      if (source.contains('showSnackBar(')) offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These build a snackbar of their own, which is as tall as its '
          'words and is drawn off the top of the screen at a large text '
          'size. Say it with showNote instead:\n  ${offenders.join('\n  ')}',
    );
  });
}

/// [source] with its comments blanked out, so that a snackbar described in a
/// sentence is not mistaken for one being shown.
String _withoutComments(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final ch = source[i];
    if (ch == "'" || ch == '"') {
      final quote = ch;
      out.write(ch);
      i += 1;
      while (i < source.length) {
        if (source[i] == r'\') {
          out.write(source.substring(i, i + 2 > source.length ? i + 1 : i + 2));
          i += 2;
          continue;
        }
        out.write(source[i]);
        if (source[i] == quote) {
          i += 1;
          break;
        }
        i += 1;
      }
      continue;
    }
    if (ch == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i += 1;
      }
      continue;
    }
    if (ch == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final close = source.indexOf('*/', i + 2);
      i = close == -1 ? source.length : close + 2;
      continue;
    }
    out.write(ch);
    i += 1;
  }
  return out.toString();
}
