import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/widgets/music_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The badge that says somebody played something you have not heard.
///
/// Shallow on purpose, like song_layers_screen_test: what matters is that a
/// count reaches the tile, that zero draws nothing, and that a screen reader
/// gets the sentence rather than a bare number.

SongProject _song({String title = 'Ladder'}) => SongProject(
      id: 'project-1',
      roomId: 'room-1',
      accountId: 'account-1',
      title: title,
      createdAt: DateTime(2026, 8, 26),
      updatedAt: DateTime(2026, 8, 26),
    );

Widget _tile({int unheard = 0}) => MaterialApp(
      home: Scaffold(
        body: SongTile(
          project: _song(),
          onTap: () {},
          unheardTakes: unheard,
        ),
      ),
    );

void main() {
  testWidgets('a song with nothing new shows no badge', (tester) async {
    await tester.pumpWidget(_tile());
    await tester.pumpAndSettle();

    expect(find.byType(UnheardTakesBadge), findsNothing);
  });

  testWidgets('a song with new takes shows the count', (tester) async {
    await tester.pumpWidget(_tile(unheard: 3));
    await tester.pumpAndSettle();

    expect(find.byType(UnheardTakesBadge), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a long silence does not widen the tile', (tester) async {
    // Somebody comes back to a song a band has been busy with. The number
    // stops mattering past a point; the tile keeping its shape does not.
    await tester.pumpWidget(_tile(unheard: 47));
    await tester.pumpAndSettle();

    expect(find.text('9+'), findsOneWidget);
    expect(find.text('47'), findsNothing);
  });

  testWidgets('the badge is spoken, not just drawn', (tester) async {
    await tester.pumpWidget(_tile(unheard: 1));
    await tester.pumpAndSettle();

    // Singular, because "1 new takes" is the kind of thing that makes an app
    // feel unattended.
    expect(
      find.bySemanticsLabel(
        RegExp(r'Open Ladder, 1 new take you have not heard'),
      ),
      findsOneWidget,
    );
  });
}
