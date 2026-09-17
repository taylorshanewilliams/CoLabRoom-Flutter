import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:colabroom/features/rooms/room_actions.dart';
import 'package:colabroom/services/copy_text.dart';
import 'package:colabroom/widgets/send_on_enter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Small dead ends, from the audit of 17 September 2026.
///
/// Each one is a tap that did nothing, or did the wrong thing quietly: a copy
/// button a browser refused, Enter writing a new line under a message instead
/// of sending it, and dialogs that closed on nothing typed and then
/// complained about it.
void main() {
  group('copying', () {
    Future<void> pumpButton(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => copyAndSay(context, 'https://app.colabroom.com/add/ze9w27t0', 'Link copied.'),
              child: const Text('Copy my link'),
            ),
          ),
        ),
      ));
    }

    void clipboard(WidgetTester tester, {required bool allowed}) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData' && !allowed) {
          throw PlatformException(code: 'NotAllowedError', message: 'Write permission denied.');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    testWidgets('says it copied when it did', (tester) async {
      clipboard(tester, allowed: true);
      await pumpButton(tester);

      await tester.tap(find.text('Copy my link'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Link copied.'), findsOneWidget);
    });

    testWidgets('shows the link to copy by hand when the browser says no', (tester) async {
      clipboard(tester, allowed: false);
      await pumpButton(tester);

      await tester.tap(find.text('Copy my link'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'it used to throw, and do nothing');
      expect(find.text('Link copied.'), findsNothing);
      expect(find.text('Copy it by hand'), findsOneWidget);
      expect(find.byKey(const Key('copy_by_hand_text')), findsOneWidget);
    });
  });

  group('Enter', () {
    Future<List<String>> pumpComposer(WidgetTester tester, {required bool keyboard}) async {
      final sent = <String>[];
      final words = TextEditingController();
      addTearDown(words.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SendOnEnter(
            onKeyboard: keyboard,
            onSend: () => sent.add(words.text),
            child: TextField(controller: words, minLines: 1, maxLines: 4),
          ),
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'see you at eight');
      return sent;
    }

    testWidgets('sends on a keyboard', (tester) async {
      final sent = await pumpComposer(tester, keyboard: true);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, <String>['see you at eight']);
    });

    testWidgets('Shift+Enter is still a new line', (tester) async {
      final sent = await pumpComposer(tester, keyboard: true);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets("a phone's own keyboard is left alone", (tester) async {
      final sent = await pumpComposer(tester, keyboard: false);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, isEmpty);
    });
  });

  group('dialogs wait for words', () {
    testWidgets('renaming a room', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<String>(
              context: context,
              builder: (_) => const RenameRoomDialog(initialName: 'South Dean'),
            ),
            child: const Text('Rename'),
          ),
        ),
      ));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      FilledButton save() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(save().onPressed, isNotNull);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(save().onPressed, isNull);
    });

    testWidgets('sending feedback, and the way back from Account', (tester) async {
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountScreen())),
              child: const Text('Account'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();

      expect(find.byType(BackButton), findsOneWidget, reason: 'Account had no way back');

      await tester.tap(find.text('Send feedback'));
      await tester.pumpAndSettle();
      final send = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send Feedback'));
      expect(send.onPressed, isNull);
    });
  });
}
