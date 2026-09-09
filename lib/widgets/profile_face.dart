import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

/// A colour that belongs to one person, and always the same one.
///
/// Derived from their id rather than stored, so it costs no column and can
/// never disagree with itself between two screens. The palette is the one the
/// backend already assigns room members from, which means somebody's ring here
/// and their initial beside a lyric they wrote are the same colour by
/// construction rather than by anybody remembering to make them match.
Color colourFor(String seed) {
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7FFFFFFF;
  }
  return AppColors.memberPalette[hash % AppColors.memberPalette.length];
}

/// Somebody's face, or the next best thing.
///
/// The profile page had no avatar on it at all — not a small one, not a
/// fallback, nothing. A musician's page that never shows their face is a
/// database row with headings on it, and a picture is the first thing anybody
/// deciding whether to work with a stranger looks for.
///
/// The ring is not decoration. Almost nobody in this app has uploaded a
/// picture, so the fallback is the common case and has to be worth looking at
/// on its own — initials on a flat grey circle is what every abandoned account
/// on the internet looks like. Their own colour, on a dark ground, at least
/// makes the page theirs.
class ProfileFace extends StatelessWidget {
  const ProfileFace({
    required this.name,
    required this.seed,
    this.bytes,
    this.size = 78,
    super.key,
  });

  final String name;

  /// Whatever identifies this person — their id. See [colourFor].
  final String seed;

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colour = colourFor(seed);
    final image = bytes;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // A ring rather than a border: it sits outside the picture, so a
        // photograph is never cropped by the thing framing it.
        border: Border.all(color: colour.withValues(alpha: 0.85), width: 2.5),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: colour.withValues(alpha: 0.24),
            blurRadius: 18,
            spreadRadius: -2,
          ),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: ClipOval(
        child: image != null
            ? Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true)
            : DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      Color.lerp(colour, AppColors.raised, 0.55)!,
                      AppColors.raised,
                    ],
                  ),
                ),
                child: Center(
                  child: Text(
                    _initials(name),
                    style: TextStyle(
                      color: colour,
                      fontSize: size * 0.34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  static String _initials(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.characters.take(2).toString().toUpperCase();
    }
    return (words.first.characters.first + words.last.characters.first)
        .toUpperCase();
  }
}

/// What somebody has actually played, as a shape.
///
/// The counts were already on this page as chips — "vocal · 9", "harmony · 4"
/// — which is accurate and reads like a receipt. This is the same numbers as
/// a row of little meters, and it does two things a chip cannot: it is
/// comparable at a glance, and it is unmistakably *this* app rather than any
/// other directory of people.
///
/// Deliberately unlabelled and deliberately small. It is a signature, not a
/// chart — the chips underneath still say which part is which, and a reader
/// who wants the number reads the number. Anybody who has ever looked at a
/// desk knows what a taller bar means without being told.
class PartsSignature extends StatelessWidget {
  const PartsSignature({
    required this.parts,
    required this.seed,
    this.height = 46,
    super.key,
  });

  /// Part name to how many takes of it a room actually kept.
  final Map<String, int> parts;

  final String seed;
  final double height;

  /// Enough to read as a signature, few enough to stay one.
  static const int _most = 6;

  @override
  Widget build(BuildContext context) {
    if (parts.isEmpty) return const SizedBox.shrink();

    final entries = parts.entries.toList(growable: false)
      ..sort((a, b) => b.value.compareTo(a.value));
    final shown = entries.take(_most).toList(growable: false);
    final tallest = shown.first.value;
    final colour = colourFor(seed);

    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (final entry in shown)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: '${entry.key} · ${entry.value}',
                child: SizedBox(
                  width: 11,
                  height: height,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: <Widget>[
                      // The unlit track. Without it a short bar is just a
                      // short bar; with it, it is a level — you can see how
                      // much of the tallest this one is, which is the whole
                      // reason to draw it rather than print the number.
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.line.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      Container(
                        // A floor, so one take is a visible mark rather than
                        // a smudge. Somebody's first recorded part is the one
                        // they would most like to see on their own page.
                        height: (height * (entry.value / tallest))
                            .clamp(9.0, height),
                        decoration: BoxDecoration(
                          color: colour,
                          borderRadius: BorderRadius.circular(5),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: colour.withValues(alpha: 0.35),
                              blurRadius: 8,
                              spreadRadius: -2,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
