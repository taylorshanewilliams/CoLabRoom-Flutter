import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/widgets/app_top_bar.dart';
import 'package:colabroom/widgets/player_face.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Small text on a coloured ground, readable at 4.5:1.
///
/// The render harness measured the unread count on the bell at 2.66:1, white
/// on the error pink at ten pixels, and the inviter's initial on an
/// invitation at 3.37:1 (audit, 17 September 2026). Looking for the rest
/// turned up worse: your own initials in the top bar and on Account had no
/// colour of their own, took the body text grey, and sat on the app's blue at
/// 1.6:1.
///
/// Worked out here from the colours the widgets actually carry, with the
/// WCAG formula written out again rather than borrowed from the app, so a
/// mistake in one is not quietly repeated in the other.
double _wcag(Color a, Color b) {
  final one = a.computeLuminance();
  final two = b.computeLuminance();
  return ((one > two ? one : two) + 0.05) / ((one > two ? two : one) + 0.05);
}

/// The colour a [Text] is actually painted in, style inherited and all.
Color _painted(WidgetTester tester, Finder text) {
  final element = tester.element(text);
  final own = tester.widget<Text>(text).style;
  return DefaultTextStyle.of(element).style.merge(own).color!;
}

Future<MusicBetaController> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
  ));
  await tester.pump(const Duration(milliseconds: 500));
  return controller;
}

Widget _topBar() => Scaffold(
      body: AppTopBar(
        displayName: 'Taylor Williams',
        onOpenAccount: () {},
        onOpenNotifications: () {},
      ),
    );

void main() {
  testWidgets('the unread count reads on its pill', (tester) async {
    await _pump(tester, _topBar());

    final badge = find.byKey(const Key('top_bar_inbox_badge'));
    expect(badge, findsOneWidget,
        reason: 'the seeded inbox has an invitation waiting');
    final pill =
        (tester.widget<Container>(badge).decoration! as BoxDecoration).color!;
    final number = find.descendant(of: badge, matching: find.byType(Text));

    expect(_wcag(_painted(tester, number), pill), greaterThanOrEqualTo(4.5));
    expect(pill, CoLabRoomTheme.dark().colorScheme.error,
        reason: 'the pill keeps its colour; the number on it is what changed');
  });

  testWidgets('your initials read on every part of the top bar blue',
      (tester) async {
    await _pump(tester, _topBar());

    final face = find.byKey(const Key('top_bar_face'));
    final ground = ((tester.widget<Container>(face).decoration!
                as BoxDecoration)
            .gradient! as LinearGradient)
        .colors;
    final letters = _painted(
        tester, find.descendant(of: face, matching: find.text('TW')));

    for (final stop in ground) {
      expect(_wcag(letters, stop), greaterThanOrEqualTo(4.5),
          reason: 'the letters cross the gradient, so every stop counts');
    }
  });

  testWidgets('and on Account', (tester) async {
    await _pump(tester, const AccountScreen());

    final face = find.byKey(const Key('account_face'));
    final ground = ((tester.widget<Container>(face).decoration!
                as BoxDecoration)
            .gradient! as LinearGradient)
        .colors;
    final letters =
        _painted(tester, find.descendant(of: face, matching: find.byType(Text)));

    for (final stop in ground) {
      expect(_wcag(letters, stop), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets("an inviter's initial reads on its circle", (tester) async {
    await _pump(tester, const NotificationsScreen());

    final face = find.byKey(const Key('invite_face'));
    final ground = tester.widget<CircleAvatar>(face).backgroundColor!;
    // What CircleAvatar paints, which is not the Text's own style: it sets
    // the letter colour on the text theme around its child.
    final letter = find.descendant(of: face, matching: find.text('J'));
    final painted = DefaultTextStyle.of(tester.element(letter)).style.color!;

    expect(_wcag(painted, ground), greaterThanOrEqualTo(4.5));
  });

  testWidgets('a face drawn in anybody\'s colour reads, and no colour does too',
      (tester) async {
    tester.view.physicalSize = const Size(900, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tints = <Color?>[...AppColors.memberPalette, AppColors.cyan, AppColors.muted, null];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: AppColors.raised,
        body: Wrap(children: <Widget>[
          for (var i = 0; i < tints.length; i += 1)
            PlayerFace(key: Key('face_$i'), name: 'Dylan Reed', color: tints[i]),
        ]),
      ),
    ));

    for (var i = 0; i < tints.length; i += 1) {
      final face = find.byKey(Key('face_$i'));
      final circle = tester.widget<Container>(
          find.descendant(of: face, matching: find.byType(Container)).first);
      final wash = (circle.decoration! as BoxDecoration).color!;
      // The face is see-through; this is what it looks like on the lightest
      // card in the app.
      final ground = Color.alphaBlend(wash, AppColors.raised);
      final letters = _painted(
          tester, find.descendant(of: face, matching: find.text('DR')));

      expect(_wcag(letters, ground), greaterThanOrEqualTo(4.5),
          reason: 'tint ${tints[i]} on its own wash');
    }
  });

  test('a colour that already reads is left as the member chose it', () {
    final ground = Color.alphaBlend(
        AppColors.green.withValues(alpha: 0.22), AppColors.raised);
    expect(readableOn(AppColors.green, ground), AppColors.green);
  });
}
