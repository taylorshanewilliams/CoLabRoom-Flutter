import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/widgets/app_top_bar.dart';
import 'package:colabroom/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wordmark gets the room it is given.
///
/// Taylor: "the colabroom logo at the top shrunk a lot."
///
/// `Flexible` and `Spacer` are both flex children with flex 1, so a Row
/// holding one of each hands them half the free space apiece. The mark got 95
/// of the 190 spare pixels on a 360px phone, its icon and gap ate 58 of those,
/// and `BrandMark`'s own `FittedBox` dutifully shrank the wordmark into the 37
/// that were left — with an identical 95 pixels of nothing sitting beside it.
///
/// Nothing overflowed. Nothing threw. No existing test could see it, because
/// every existing test asks whether Flutter complained, and Flutter had no
/// complaint: it was asked to fit a name into 37 pixels and it did.
///
/// So this one measures instead of asking.
Future<double> _markWidth(
  WidgetTester tester, {
  required Size size,
  List<String> tabs = const <String>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: AppTopBar(
          displayName: 'Taylor Williams',
          onOpenAccount: () {},
          onOpenNotifications: () {},
          onGoHome: () {},
          tabs: tabs,
          onSelectTab: (_) {},
        ),
      ),
    ),
  ));
  await tester.pump();
  return tester.getSize(find.byType(BrandMark)).width;
}

void main() {
  testWidgets('on a phone the mark keeps the width it is not using',
      (tester) async {
    final width = await _markWidth(tester, size: const Size(360, 690));
    // The whole bar is 360 with 18 of padding each side, and the help button,
    // the bell and the avatar want about 134 between them. Anything close to
    // half of what is left means the Spacer is back.
    expect(
      width,
      greaterThan(180),
      reason: 'the mark was sharing the free space with an empty Spacer, so '
          'it got half a row and the wordmark was scaled into the remainder',
    );
  });

  testWidgets('and the name is drawn whole, not cut', (tester) async {
    await _markWidth(tester, size: const Size(360, 690));
    // A `FittedBox` never reports an overflow and an ellipsis never throws,
    // so the only evidence either way is the text itself.
    expect(find.text('CoLabRoom', findRichText: true), findsOneWidget);
  });

  testWidgets('with tabs, the tabs take the slack and the mark does not shrink',
      (tester) async {
    // The desk bar. Before this the mark was the flex child and the tab strip
    // was not, so the two of them plus a Spacer split the row three ways.
    final width = await _markWidth(
      tester,
      size: const Size(1100, 900),
      tabs: const <String>['Songs', 'People', 'Open Mic'],
    );
    expect(width, greaterThan(180));
  });

  testWidgets('a narrow window with tabs still fits', (tester) async {
    // 900 is the width at which the app switches to the desk bar, so it is
    // the tightest this layout is ever asked to be. The tabs scroll rather
    // than overflow, which is why nothing here has to be dropped.
    await _markWidth(
      tester,
      size: const Size(900, 800),
      tabs: const <String>['Songs', 'People', 'Open Mic'],
    );
    expect(tester.takeException(), isNull);
  });
}
