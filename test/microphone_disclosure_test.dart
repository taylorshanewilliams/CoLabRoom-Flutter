import 'package:colabroom/widgets/microphone_disclosure.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  /// Drives one call to [MicrophoneAccess.ensureGranted] from a real widget
  /// tree, since the disclosure is a dialog and needs somewhere to open.
  /// Both fields are closures, not values: the call is still in flight while
  /// the disclosure sits on screen, so a snapshot taken here would record the
  /// answer as null every time the dialog actually appears.
  Future<({bool? Function() result, bool Function() wasAsked})> run(
    WidgetTester tester, {
    required Future<bool> Function() request,
  }) async {
    var asked = false;
    bool? result;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await MicrophoneAccess.ensureGranted(
                context,
                purpose: 'to test this',
                request: () {
                  asked = true;
                  return request();
                },
              );
            },
            child: const Text('start'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    return (result: () => result, wasAsked: () => asked);
  }

  testWidgets('the person is asked before the operating system is', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final call = await run(tester, request: () async => true);

    expect(find.text('Before the microphone turns on'), findsOneWidget);
    // The entire point of a prominent disclosure: the OS prompt has not
    // happened yet at this moment.
    expect(call.wasAsked(), isFalse);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(call.wasAsked(), isTrue);
  });

  testWidgets('declining never reaches the permission prompt', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final call = await run(tester, request: () async => true);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(call.wasAsked(), isFalse);
    // Declining is an answer, not a failure.
    expect(call.result(), isFalse);
  });

  testWidgets('somebody who already granted it is not asked again', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{'microphone_granted': true});
    final call = await run(tester, request: () async => true);

    expect(find.text('Before the microphone turns on'), findsNothing);
    expect(call.wasAsked(), isTrue);
    expect(call.result(), isTrue);
  });

  testWidgets('revoking it in Settings brings the explanation back', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{'microphone_granted': true});

    // Permission was granted once and has since been taken away, so the
    // request comes back false and the remembered grant is no longer true.
    final revoked = await run(tester, request: () async => false);
    expect(revoked.result(), isFalse);

    // The next attempt must disclose again rather than letting a bare OS
    // prompt appear out of nowhere.
    final retry = await run(tester, request: () async => true);
    expect(find.text('Before the microphone turns on'), findsOneWidget);
    expect(retry.wasAsked(), isFalse);
  });

  testWidgets('the disclosure says where the recording goes', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await run(tester, request: () async => true);

    // The facts the OS prompt cannot state, and the reason this screen exists.
    expect(find.textContaining('Never in the background'), findsOneWidget);
    expect(find.textContaining('uploaded to this song'), findsOneWidget);
    expect(find.textContaining('sent to our processing'), findsOneWidget);
    expect(find.textContaining('delete a recording at any time'), findsOneWidget);
  });
}
