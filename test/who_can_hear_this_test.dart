import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/audience_dial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Can somebody tell who can hear their song?
///
/// Until this, no. A song's audience was decided by which room it lived in,
/// who was invited to that one song, and whether it was on the Open Mic —
/// three mechanisms, two of them behind an overflow menu, and no indicator
/// anywhere in the app. The single sentence about privacy in a song's whole
/// interface lived inside a confirmation dialog.
///
/// The dial has one job and one way to fail badly: saying the wrong thing.
/// A control that under-reports reach would tell somebody their song is
/// private while strangers listen to it, which is worse than no control.
void main() {
  SongAudience audience(
    SongReach reach, {
    List<SongListener> listeners = const <SongListener>[],
    bool onOpenMic = false,
    String roomName = 'The Basement',
  }) =>
      SongAudience(
        reach: reach,
        listeners: listeners,
        onOpenMic: onOpenMic,
        roomName: roomName,
        roomIcon: '🎸',
      );

  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  group('it says who', () {
    testWidgets('alone reads as alone', (tester) async {
      await tester.pumpWidget(wrap(
        AudienceDial(audience: audience(SongReach.justYou), onTap: () {}),
      ));
      expect(find.text('Only you'), findsOneWidget);
      expect(find.text('Nobody else can hear this yet'), findsOneWidget);
    });

    testWidgets('a room is named, not counted', (tester) async {
      await tester.pumpWidget(wrap(AudienceDial(
        audience: audience(
          SongReach.room,
          listeners: const <SongListener>[
            SongListener(id: 'a', name: 'Mara'),
            SongListener(id: 'b', name: 'Dev'),
          ],
        ),
        onTap: () {},
      )));
      // The room's own name, because that is how somebody remembers where a
      // song lives — not "2 people".
      expect(find.text('The Basement'), findsOneWidget);
      expect(find.text('2 people can hear it'), findsOneWidget);
    });

    testWidgets('public says so unmistakably', (tester) async {
      await tester.pumpWidget(wrap(AudienceDial(
        audience: audience(SongReach.anyone, onOpenMic: true),
        onTap: () {},
      )));
      expect(find.text('Anyone'), findsOneWidget);
      expect(
        find.text('On the Open Mic — anybody signed in can listen'),
        findsOneWidget,
      );
    });
  });

  group('it never guesses', () {
    testWidgets('nothing is drawn until the answer arrives', (tester) async {
      await tester.pumpWidget(
        wrap(AudienceDial(audience: null, onTap: () {})),
      );
      // The failure that would matter most: telling somebody their song is
      // private a moment before finding out it is not.
      expect(find.text('Only you'), findsNothing);
      expect(find.byKey(const Key('song_audience_dial')), findsNothing);
    });
  });

  group('the sheet offers the move that is actually available', () {
    testWidgets('a private song is offered the stage', (tester) async {
      SongAudienceChoice? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showAudienceSheet(
                  context,
                  audience: audience(SongReach.room),
                  songTitle: 'Ladder Of Life',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // All four positions, so the sheet teaches the gradient rather than
      // only reporting one point on it.
      expect(find.text('Only you'), findsOneWidget);
      expect(find.text('People you asked'), findsOneWidget);
      expect(find.text('Anyone'), findsOneWidget);

      expect(find.text('Put it on the Open Mic'), findsOneWidget);
      await tester.tap(find.byKey(const Key('audience_open_mic_toggle')));
      await tester.pumpAndSettle();
      expect(picked, SongAudienceChoice.putOnOpenMic);
    });

    testWidgets('a public song can be taken back down', (tester) async {
      SongAudienceChoice? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showAudienceSheet(
                  context,
                  audience: audience(SongReach.anyone, onOpenMic: true),
                  songTitle: 'Ladder Of Life',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The menu this replaced said "Put it on the Open Mic" whether or not
      // it already was, and taking it down was not offered anywhere at all.
      // An app where publishing is one-way is one where nobody publishes.
      expect(find.text('Take it off the Open Mic'), findsOneWidget);
      await tester.tap(find.byKey(const Key('audience_open_mic_toggle')));
      await tester.pumpAndSettle();
      expect(picked, SongAudienceChoice.takeOffOpenMic);
    });
  });
}
