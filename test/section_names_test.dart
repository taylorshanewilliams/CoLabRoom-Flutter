import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

StructureSection _section(
  String label, {
  int startMs = 0,
  int endMs = 1000,
  String? customLabel,
  int groupIndex = 0,
}) {
  return StructureSection(
    startMs: startMs,
    endMs: endMs,
    label: label,
    groupIndex: groupIndex,
    customLabel: customLabel,
  );
}

void main() {
  group('displayLabel', () {
    test('a name someone chose beats a name a model guessed', () {
      expect(_section('Chorus', customLabel: 'the big one').displayLabel, 'the big one');
      expect(_section('Chorus').displayLabel, 'Chorus');
    });

    test('treats a blank custom name as no custom name', () {
      expect(_section('Verse', customLabel: '   ').displayLabel, 'Verse');
      expect(_section('Verse', customLabel: '   ').isRenamed, isFalse);
    });

    test('shortens the name that is actually shown', () {
      expect(_section('Chorus').shortLabel, 'Ch');
      expect(_section('Chorus', customLabel: 'Big').shortLabel, 'Bi');
    });
  });

  group('carryCustomSectionNames', () {
    test('hands a name back to every occurrence of that part', () {
      final previous = <StructureSection>[
        _section('Verse', startMs: 0),
        _section('Chorus', startMs: 1000, customLabel: 'the big one'),
      ];
      // Boundaries moved and a section appeared that wasn't there before.
      final next = <StructureSection>[
        _section('Intro', startMs: 0),
        _section('Verse', startMs: 900),
        _section('Chorus', startMs: 2100),
        _section('Chorus', startMs: 5000),
      ];
      final carried = carryCustomSectionNames(previous, next);
      expect(carried.map((s) => s.displayLabel),
          <String>['Intro', 'Verse', 'the big one', 'the big one']);
    });

    test('leaves parts nobody renamed alone', () {
      final carried = carryCustomSectionNames(
        <StructureSection>[_section('Verse')],
        <StructureSection>[_section('Verse'), _section('Chorus')],
      );
      expect(carried.every((s) => s.isRenamed), isFalse);
    });

    test('survives the section count changing entirely', () {
      // Position- or time-matching would fall apart here; matching on the
      // model's label doesn't care.
      final carried = carryCustomSectionNames(
        <StructureSection>[
          _section('Verse', customLabel: 'the quiet bit'),
          _section('Chorus'),
        ],
        <StructureSection>[_section('Verse')],
      );
      expect(carried.single.displayLabel, 'the quiet bit');
    });

    test('has nothing to do with an empty side', () {
      final next = <StructureSection>[_section('Verse')];
      expect(carryCustomSectionNames(const <StructureSection>[], next), same(next));
      expect(
        carryCustomSectionNames(<StructureSection>[_section('Verse')], const <StructureSection>[]),
        isEmpty,
      );
    });

    test('round-trips a custom name through json', () {
      final json = _section('Chorus', customLabel: 'the big one').toJson();
      expect(StructureSection.fromJson(json).customLabel, 'the big one');
      // An older analysis has no such key and must still load.
      expect(StructureSection.fromJson(<String, dynamic>{'label': 'A'}).isRenamed, isFalse);
    });
  });
}
