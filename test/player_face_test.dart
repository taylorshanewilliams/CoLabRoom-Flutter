import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/widgets/player_face.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A take is somebody playing, and the row has to say who.

Widget _face({String? name, Color? color}) => MaterialApp(
      home: Scaffold(body: PlayerFace(name: name, color: color)),
    );

void main() {
  testWidgets('one name gives one initial', (tester) async {
    await tester.pumpWidget(_face(name: 'Dylan'));
    expect(find.text('D'), findsOneWidget);
  });

  testWidgets('two names give two', (tester) async {
    await tester.pumpWidget(_face(name: 'Dylan Reed'));
    expect(find.text('DR'), findsOneWidget);
  });

  testWidgets('a middle name does not become a third initial', (tester) async {
    await tester.pumpWidget(_face(name: 'Dylan James Reed'));
    expect(find.text('DJ'), findsOneWidget);
  });

  testWidgets('an unknown player is a mark, not a wrong guess', (tester) async {
    // A take recorded before anyone was named, or by somebody who has left.
    await tester.pumpWidget(_face());
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
  });

  testWidgets('the player is spoken for a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_face(name: 'Dylan'));

    // Read off the node rather than searched for by label: the face has to
    // announce itself as its own thing, and asking the node directly is what
    // actually checks that.
    expect(
      tester.getSemantics(find.byType(PlayerFace)).label,
      'Played by Dylan',
    );
    semantics.dispose();
  });

  testWidgets('an unnamed player says so rather than staying silent',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_face());

    expect(
      tester.getSemantics(find.byType(PlayerFace)).label,
      'Player not recorded',
    );
    semantics.dispose();
  });

  test('initials survive whitespace a person actually types', () {
    expect(PlayerFace.initialsFor('  dylan   reed '), 'DR');
    expect(PlayerFace.initialsFor('dylan'), 'D');
    expect(PlayerFace.initialsFor('   '), '');
  });

  testWidgets('a member keeps the colour they chose', (tester) async {
    // The same value tints their lines in the song sheet. Two colours for one
    // person is the app disagreeing with itself about who they are.
    const chosen = AppColors.green;
    await tester.pumpWidget(_face(name: 'Dylan', color: chosen));

    final text = tester.widget<Text>(find.text('D'));
    expect(text.style?.color, chosen);
  });
}
