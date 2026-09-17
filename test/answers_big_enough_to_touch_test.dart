import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Small words, full-sized touches.
///
/// "Clear all" under the strip on Home was shrink-wrapped to its text, 61x17
/// on a desk and 74x22 at 1.3x text, under even the 24-pixel floor in WCAG
/// 2.2 SC 2.5.8 (audit, 17 September 2026). It is at least 24 now and still
/// in sight under the row; the full 48 costs a layout rule, and which one is
/// Taylor's call. Join and No thanks on an invitation are padded to 48 on a
/// phone, but Material trims that to 40 on a desk. Both are checked on a
/// phone and on a desk, because the desk is where the web build is used.
final _phoneAndDesk = TargetPlatformVariant(
    <TargetPlatform>{TargetPlatform.android, TargetPlatform.windows});

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(1280, 1400),
}) async {
  tester.view.physicalSize = size;
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
}

void main() {
  testWidgets('Clear all is touched at 24 pixels tall, in sight',
      (tester) async {
    WaitingItem item(String id) => WaitingItem(
          id: id,
          kind: WaitingKind.unfinished,
          line: 'Song $id',
          actionLabel: 'Open',
          onAction: () {},
          onDismiss: () {},
        );
    Widget strip(List<WaitingItem> items) => Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[WaitingOnYou(items: items)],
          ),
        );

    for (final size in <Size>[const Size(390, 844), const Size(1280, 1400)]) {
      await _pump(tester, strip(<WaitingItem>[item('a')]), size: size);
      final alone =
          tester.getSize(find.byKey(const Key('waiting_on_you'))).height;

      await _pump(
        tester,
        strip(<WaitingItem>[
          for (final id in <String>['a', 'b', 'c', 'd', 'e']) item(id),
        ]),
        size: size,
      );
      final touch = tester.getRect(find.byKey(const Key('waiting_clear_all')));
      expect(touch.height, greaterThanOrEqualTo(24), reason: '$size');
      expect(touch.width, greaterThanOrEqualTo(48), reason: '$size');

      // Where it was: under the row and on screen with five cards in it,
      // not at the far end of a row that has to be scrolled to find it.
      final row = tester.getRect(find.byKey(const Key('waiting_row')));
      expect(touch.top, greaterThanOrEqualTo(row.bottom), reason: '$size');
      expect(touch.right, lessThanOrEqualTo(size.width), reason: '$size');

      // The strip ends in the 24-pixel line instead of its 8 pixels of
      // space, and is no taller than that.
      expect(tester.getSize(find.byKey(const Key('waiting_on_you'))).height,
          lessThanOrEqualTo(alone - 8 + 24),
          reason: '$size');
    }
  }, variant: _phoneAndDesk);

  testWidgets('Join and No thanks are touched at 48 pixels tall',
      (tester) async {
    await _pump(tester, const NotificationsScreen());

    for (final key in <String>[
      'invite_join_invite-1',
      'invite_decline_invite-1',
      'room_invite_join_preview-room-invite-1',
      'room_invite_decline_preview-room-invite-1',
    ]) {
      expect(tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(48),
          reason: key);
    }
  }, variant: _phoneAndDesk);
}
