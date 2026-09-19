import 'dart:io';

import 'package:colabroom/app/colabroom_theme.dart';
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
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. The ceiling is on the box, never on the type.
void main() {
  /// Roughly what a snackbar is measured against in this app: a record button
  /// over a tab bar. Not the real shell — the walk in `test_render/` is where
  /// the real one is drawn — but enough to put a floating snackbar under the
  /// same rule.
  Widget shell(GlobalKey<ScaffoldMessengerState> messengerKey, double scale) {
    return MaterialApp(
      theme: CoLabRoomTheme.dark(),
      scaffoldMessengerKey: messengerKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: const SizedBox.expand(),
        floatingActionButton: FloatingActionButton(
            onPressed: () {}, child: const Icon(Icons.mic_rounded)),
        bottomNavigationBar: SafeArea(
          top: false,
          child: NavigationBar(destinations: const <Widget>[
            NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.library_music_rounded), label: 'Songs'),
            NavigationDestination(
                icon: Icon(Icons.forum_rounded), label: 'Messages'),
          ]),
        ),
      ),
    );
  }

  const Size phone = Size(390, 844);

  /// The phone, the shell, and a messenger to say something through.
  Future<GlobalKey<ScaffoldMessengerState>> onAPhone(
    WidgetTester tester,
    double scale,
  ) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(shell(messengerKey, scale));
    return messengerKey;
  }

  /// One of the longest sentences the app actually says, and one somebody
  /// only ever reads because something has already gone wrong: a server that
  /// refused a sign-in as if it came from the future. `reportAndDescribe`
  /// hands this to a snackbar, and this is the sentence it hands over.
  final String longNote = describeForUser(PostgrestException(
    message: 'JWT issued at future',
    code: 'PGRST303',
  ));

  testWidgets('a long note is drawn on the screen at the largest text size',
      (tester) async {
    final messengerKey = await onAPhone(tester, 3.12);
    messengerKey.currentState!.showNote(longNote);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(tester.takeException(), isNull,
        reason: 'the snackbar was positioned off the screen');

    final RenderBox box = tester.renderObject<RenderBox>(find.byType(SnackBar));
    final Offset topLeft = box.localToGlobal(Offset.zero);
    expect(topLeft.dy, greaterThanOrEqualTo(0),
        reason: 'the top of the note is above the top of the phone');
    expect(topLeft.dy + box.size.height, lessThanOrEqualTo(phone.height),
        reason: 'the bottom of the note is below the bottom of the phone');

    // And proof that the test is not passing on a sentence that fits anyway:
    // at this size the words are taller than the box holding them, and the
    // rest of them is reachable rather than gone.
    final RenderBox words = tester.renderObject<RenderBox>(find.text(longNote));
    expect(words.size.height, greaterThan(box.size.height));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('a short note at an ordinary size is exactly as it was',
      (tester) async {
    final messengerKey = await onAPhone(tester, 1.0);
    messengerKey.currentState!.showNote('Password reset email sent.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(tester.takeException(), isNull);
    final RenderBox held =
        tester.renderObject<RenderBox>(find.byType(NoteThatFits));
    final RenderBox words =
        tester.renderObject<RenderBox>(find.text('Password reset email sent.'));
    expect(held.size.height, words.size.height,
        reason: 'below the ceiling a note is still exactly as tall as its '
            'words, so nothing about the usual case has changed');
  });

  testWidgets('a note keeps its action, and waits for it', (tester) async {
    final messengerKey = await onAPhone(tester, 1.0);
    var undone = false;
    messengerKey.currentState!.showNote(
      'Declined. They will be told.',
      action: SnackBarAction(label: 'Undo', onPressed: () => undone = true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    // A snackbar with an action persists, which is [SnackBar]'s own rule and
    // still has to be the rule here: the button is the whole point of it.
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(SnackBarAction), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undone, isTrue);
  });

  testWidgets('a note stays up for as long as it was going to', (tester) async {
    final messengerKey = await onAPhone(tester, 1.0);
    messengerKey.currentState!.showNote('Saved.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.text('Saved.'), findsOneWidget);

    // Four seconds, which is what `SnackBar` does when nobody says otherwise
    // and what all 116 call sites were getting before there was a helper.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Saved.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Saved.'), findsNothing);

    messengerKey.currentState!
        .showNote('Saved.', duration: const Duration(seconds: 30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Saved.'), findsOneWidget,
        reason: 'a duration asked for is a duration kept');
    messengerKey.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
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
