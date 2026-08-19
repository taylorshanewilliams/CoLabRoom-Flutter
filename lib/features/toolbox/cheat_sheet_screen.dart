import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../widgets/app_surface.dart';
import 'guitar_chord_diagram.dart';
import 'toolbox_models.dart';

class CheatSheetScreen extends StatelessWidget {
  const CheatSheetScreen({required this.category, required this.sheet, super.key});

  final ToolboxCategory category;
  final CheatSheet sheet;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(sheet.title),
      ),
      body: SafeArea(
        child: switch (sheet.kind) {
          CheatSheetKind.chordDiagrams => _ChordGrid(chords: sheet.chords),
          CheatSheetKind.text => _TextSections(sections: sheet.sections),
        },
      ),
    );
  }
}

class _ChordGrid extends StatelessWidget {
  const _ChordGrid({required this.chords});

  final List<ChordDiagramData> chords;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final count = width >= 900 ? 5 : width >= 620 ? 4 : width >= 420 ? 3 : 2;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.78,
          ),
          itemCount: chords.length,
          itemBuilder: (context, index) {
            final chord = chords[index];
            return AppSurface(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    chord.name,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(child: FittedBox(child: GuitarChordDiagram(chord: chord))),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _TextSections extends StatelessWidget {
  const _TextSections({required this.sections});

  final List<CheatSheetSection> sections;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
      itemCount: sections.length,
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemBuilder: (context, index) {
        final section = sections[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              section.heading,
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            AppSurface(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(
                children: <Widget>[
                  for (final row in section.rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            width: 108,
                            child: Text(
                              row.label,
                              style: const TextStyle(
                                color: AppColors.cyan,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              row.value,
                              style: const TextStyle(color: AppColors.text, fontSize: 13, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
