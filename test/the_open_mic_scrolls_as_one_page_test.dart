import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Open Mic is one page, at every text size.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. At twice normal the room's chrome — the strip of
/// your own songs, the title with its two buttons, the sentence saying what
/// you are looking at — is taller than a phone, and #391 held that by capping
/// it and letting it scroll inside its own box. Nothing overflowed after
/// that, which is why it shipped, and the tab was two things: a drag starting
/// on the title moved the chrome and left the list exactly where it was, and
/// the list was allowed as little as 140 pixels to live in. Somebody reading
/// at that size was browsing a room through a letterbox, with the scroll
/// they were making not moving what they were reading.
///
/// So the three things asserted here are the three the split cost: one scroll
/// rather than two, one drag moving everything together, and a list that gets
/// the whole screen once the chrome has gone by. The other two are what a
/// rewrite of a screen's scrolling is most likely to break on the way past —
/// where the room is when you come back from somebody, and whether anything
/// moved at all for a reader at the ordinary text size.
/// A room with more people in it than a screen holds.
///
/// The preview seeds three, which at twice normal text is a list shorter than
/// the chrome above it — and the cap only ever bit when there was more room
/// wanted than given.
class _AFullRoom extends InMemoryMusicRepository {
  _AFullRoom() : super.from(InMemoryMusicRepository.seeded());

  @override
  Future<List<Musician>> findMusicians({
    List<String>? parts,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async =>
      <Musician>[
        for (var i = 1; i <= 12; i += 1)
          Musician(
            id: 'somebody-$i',
            displayName: i == 1 ? 'Mara Ellison' : 'Somebody $i',
            plays: const <String>['bass'],
            partsRecorded: const <String, int>{},
            songsPlayedOn: 0,
            peopleWorkedWith: 0,
          ),
      ];
}

Future<void> _open(WidgetTester tester, {required double textScale}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(body: OpenMicScreen(repository: _AFullRoom())),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Everything on screen that scrolls up and down.
///
/// The strip of your own songs runs sideways, so it is not one of these — the
/// two this used to find were the chrome and the list.
Finder _downwards() => find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );

/// A drag that starts on the chrome, released without a flick.
Future<void> _dragFromTheTitle(WidgetTester tester, double by) async {
  await tester.dragFrom(
    tester.getCenter(find.text('Open Mic')),
    Offset(0, by),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('the room is one scroll rather than two', (tester) async {
    await _open(tester, textScale: 2.0);
    expect(
      _downwards(),
      findsOneWidget,
      reason: 'the chrome and the list are two scrolling regions again, so a '
          'drag on one of them leaves the other where it was',
    );
  });

  testWidgets('at the largest text one drag moves the whole room',
      (tester) async {
    await _open(tester, textScale: 2.0);

    final titleBefore = tester.getTopLeft(find.text('Open Mic')).dy;
    final personBefore = tester.getTopLeft(find.text('Mara Ellison')).dy;

    await _dragFromTheTitle(tester, -250);

    final titleMoved = tester.getTopLeft(find.text('Open Mic')).dy - titleBefore;
    final personMoved =
        tester.getTopLeft(find.text('Mara Ellison')).dy - personBefore;

    expect(titleMoved, lessThan(-100),
        reason: 'the drag did not move the chrome at all');
    expect(
      personMoved,
      moreOrLessEquals(titleMoved, epsilon: 0.5),
      reason: 'the chrome moved $titleMoved and the person in the list moved '
          '$personMoved — a drag on the top of the room left the room behind',
    );
  });

  testWidgets('the list gets the whole screen once the chrome is scrolled by',
      (tester) async {
    await _open(tester, textScale: 2.0);

    // Scrolls the chrome away rather than a measured distance: the room is
    // longer than the screen, so this is as far as one drag reaches, and the
    // cap left the list 140 pixels however far anybody scrolled.
    await _dragFromTheTitle(tester, -800);

    // Off the top, or no longer built at all — both mean the same thing here,
    // which is that every pixel of the screen is now the room.
    final title = find.text('Open Mic');
    expect(
      title.evaluate().isEmpty || tester.getBottomLeft(title).dy <= 0,
      isTrue,
      reason: 'the chrome is still holding the top of the screen, so the list '
          'has only what was left over',
    );
    // And what is on that screen is the room: somebody drawn inside the
    // 844 pixels the reader can actually see.
    final onScreen = find.textContaining('Somebody').evaluate().where((element) {
      final box = element.renderObject! as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      return top >= 0 && top < 844;
    });
    expect(onScreen, isNotEmpty,
        reason: 'nobody from the room is on the screen the chrome left');
  });

  testWidgets('coming back from somebody leaves the room where you left it',
      (tester) async {
    await _open(tester, textScale: 1.0);

    // Far enough down that the room has to be scrolled to reach them, and
    // built as the page goes rather than all at once.
    await tester.scrollUntilVisible(find.text('Somebody 6'), 200,
        scrollable: _downwards());
    await tester.pump(const Duration(milliseconds: 300));
    // First of the downward scrollables, because a pushed profile brings one
    // of its own and the room is the route underneath it.
    final room = tester.state<ScrollableState>(_downwards().first);
    final where = room.position.pixels;
    expect(where, greaterThan(0), reason: 'the room did not scroll at all');

    await tester.tap(find.text('Somebody 6'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MusicianProfileScreen), findsOneWidget);

    Navigator.of(tester.element(find.byType(MusicianProfileScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.state<ScrollableState>(_downwards().first).position.pixels,
      where,
      reason: 'the room started again from the top after a look at somebody',
    );
  });

  testWidgets('nothing moves for a reader at the usual text size',
      (tester) async {
    await _open(tester, textScale: 1.0);

    // The room opens on its title, its sentence and the first person in it,
    // with nothing to scroll past first.
    expect(tester.getTopLeft(find.text('Open Mic')).dx, 18,
        reason: 'the title left the gutter the other tabs use');
    expect(find.text('Everybody who is here'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Mara Ellison')).dy,
      lessThan(844),
      reason: 'the first person in the room is off the bottom of the screen '
          'before anybody has scrolled',
    );
  });
}
