import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/take_naming.dart';
import 'package:flutter_test/flutter_test.dart';

Take _take({
  required String id,
  TakePart part = TakePart.other,
  String? performer,
  String label = '',
  bool namedByHand = false,
}) {
  return Take(
    id: id,
    path: '/tmp/$id.wav',
    label: label,
    recordedAt: DateTime(2026, 8, 25),
    part: part,
    performer: performer,
    namedByHand: namedByHand,
  );
}

void main() {
  group('describing one layer', () {
    test('who played it and what it was', () {
      expect(
        TakeNaming.describe(_take(id: 'a', part: TakePart.lead, performer: 'Dylan')),
        "Dylan's lead",
      );
    });

    test('a name ending in s takes the bare apostrophe', () {
      expect(
        TakeNaming.describe(_take(id: 'a', part: TakePart.vocal, performer: 'Chris')),
        "Chris' vocal",
      );
    });

    test('the part alone when nobody is credited', () {
      expect(
        TakeNaming.describe(_take(id: 'a', part: TakePart.bass)),
        'bass',
      );
    });

    test('a typed name beats anything composed', () {
      // The rule that protects a person's own words from a later rule.
      expect(
        TakeNaming.describe(_take(
          id: 'a',
          part: TakePart.lead,
          performer: 'Dylan',
          label: 'the weird one',
          namedByHand: true,
        )),
        'the weird one',
      );
    });
  });

  group('naming a version by what is in it', () {
    final takes = <Take>[
      _take(id: '1', part: TakePart.rhythm),
      _take(id: '2', part: TakePart.lead, performer: 'Dylan'),
      _take(id: '3', part: TakePart.harmony, performer: 'Kate'),
      _take(id: '4', part: TakePart.bass, performer: 'Sam'),
    ];

    test('joins the layers', () {
      expect(
        TakeNaming.autoName(takes, <String>{'1', '2'}),
        "rhythm + Dylan's lead",
      );
    });

    test('counts the rest rather than listing six things', () {
      // A list of everything is an inventory, not a name, and nobody reads
      // it in a picker.
      expect(
        TakeNaming.autoName(takes, <String>{'1', '2', '3', '4'}),
        "rhythm + Dylan's lead + 2 more",
      );
    });

    test('an empty mix says so', () {
      expect(TakeNaming.autoName(takes, <String>{}), 'Empty');
    });
  });

  group('naming a version by how it differs', () {
    final takes = <Take>[
      _take(id: '1', part: TakePart.rhythm),
      _take(id: '2', part: TakePart.lead, performer: 'Dylan'),
      _take(id: '3', part: TakePart.harmony, performer: 'Kate'),
    ];

    test('one layer added is "with"', () {
      expect(
        TakeNaming.differenceFrom(
          takes: takes,
          baseline: <String>{'1'},
          version: <String>{'1', '2'},
        ),
        "with Dylan's lead",
      );
    });

    test('one layer removed is "without"', () {
      expect(
        TakeNaming.differenceFrom(
          takes: takes,
          baseline: <String>{'1', '2'},
          version: <String>{'1'},
        ),
        "without Dylan's lead",
      );
    });

    test('two changes at once are not a name', () {
      // "with Dylan's lead and Kate's harmony but without the rhythm" is the
      // sort of label people stop reading. Falling back to the contents is
      // better than pretending.
      expect(
        TakeNaming.differenceFrom(
          takes: takes,
          baseline: <String>{'1'},
          version: <String>{'2', '3'},
        ),
        isNull,
      );
    });
  });

  group('what a version is called on screen', () {
    final takes = <Take>[
      _take(id: '1', part: TakePart.rhythm),
      _take(id: '2', part: TakePart.lead, performer: 'Dylan'),
    ];

    TakeVersion version(Set<String> ids, {String? name}) => TakeVersion(
          id: 'v',
          name: name,
          enabledTakeIds: ids,
          createdAt: DateTime(2026, 8, 25),
        );

    test('the song title and the difference, which is what a band says', () {
      expect(
        TakeNaming.display(
          version(<String>{'1', '2'}),
          takes,
          baseline: <String>{'1'},
          songTitle: 'Mountains',
        ),
        "Mountains with Dylan's lead",
      );
    });

    test('an untitled sketch is not called "Untitled with..."', () {
      expect(
        TakeNaming.display(
          version(<String>{'1', '2'}),
          takes,
          baseline: <String>{'1'},
          songTitle: '   ',
        ),
        "with Dylan's lead",
      );
    });

    test('a chosen name wins over everything', () {
      expect(
        TakeNaming.display(
          version(<String>{'1', '2'}, name: 'Chorus test'),
          takes,
          baseline: <String>{'1'},
          songTitle: 'Mountains',
        ),
        'Chorus test',
      );
    });

    test('falls back to contents when the difference is not one layer', () {
      expect(
        TakeNaming.display(
          version(<String>{'2'}),
          takes,
          baseline: <String>{},
          songTitle: 'Mountains',
        ),
        "Mountains with Dylan's lead",
      );
    });
  });

  group('labelling a take the moment it is recorded', () {
    test('the first of a part is unnumbered', () {
      expect(
        TakeNaming.nextLabel(const <Take>[], TakePart.lead, 'Dylan'),
        "Dylan's lead",
      );
    });

    test('a second attempt at the same thing is numbered', () {
      // Numbered per part, so trying the lead again reads as a second
      // attempt rather than as a different instrument.
      final existing = <Take>[_take(id: '1', part: TakePart.lead, performer: 'Dylan')];
      expect(
        TakeNaming.nextLabel(existing, TakePart.lead, 'Dylan'),
        "Dylan's lead 2",
      );
    });

    test('a different part starts its own count', () {
      final existing = <Take>[_take(id: '1', part: TakePart.lead, performer: 'Dylan')];
      expect(
        TakeNaming.nextLabel(existing, TakePart.bass, 'Sam'),
        "Sam's bass",
      );
    });
  });
}
