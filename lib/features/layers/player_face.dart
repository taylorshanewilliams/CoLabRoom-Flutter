import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// Whoever played a take, as a face on its row.
///
/// A list of takes is a list of people, and it did not look like one: every
/// row carried a part name and nothing about who played it, on the one
/// feature whose whole argument is that a band knows whose lead that was.
///
/// A photo when there is one, initials when there is not. Initials are the
/// common case rather than the fallback — almost nobody sets a picture — so
/// they get a real treatment instead of a grey circle.
///
/// The tint is the person's **own room colour** (`room_members.color_value`,
/// which they picked), not a colour derived from their name. That matters:
/// the same value already tints their lyric lines, so a bandmate's takes and
/// their words in the song sheet come out the same colour, and the app is
/// saying one thing about who somebody is rather than two.
class PlayerFace extends StatelessWidget {
  const PlayerFace({
    required this.name,
    this.color,
    this.photo,
    this.size = 26,
    super.key,
  });

  /// The player's room colour, or null when the take belongs to somebody who
  /// is not a member — a guest who was handed the phone, or a member who has
  /// since left. Drawn neutral rather than assigned a colour that would
  /// collide with a real member's.
  final Color? color;

  /// Null when nobody typed a performer and the account has no display name —
  /// rare, and drawn as a neutral mark rather than a wrong guess.
  final String? name;
  final Uint8List? photo;
  final double size;

  /// One letter from the first two words: "Dylan Reed" is DR, "Dylan" is D.
  static String initialsFor(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    if (words.length == 1) return words.first.characters.first.toUpperCase();
    return (words.first.characters.first + words[1].characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final person = name?.trim();
    final known = person != null && person.isNotEmpty;
    final initials = known ? initialsFor(person) : '';
    final tint = color ?? AppColors.line;

    return Semantics(
      // Its own node rather than merged into whatever is around it. A label
      // alone attaches to an ancestor, so on a take row the player's name
      // would be swallowed into the row's own announcement instead of being
      // readable as the distinct fact it is.
      container: true,
      label: known ? 'Played by $person' : 'Player not recorded',
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: photo != null ? AppColors.raised : tint.withValues(alpha: 0.22),
          shape: BoxShape.circle,
          border: Border.all(color: tint.withValues(alpha: 0.55), width: 1),
        ),
        child: photo != null
            ? Image.memory(photo!, fit: BoxFit.cover, width: size, height: size)
            // The initials are a drawing of the name, not a second fact
            // about it. Left readable, this node announced "Played by Dylan,
            // D" — the name, and then it spelled at you.
            : ExcludeSemantics(
                child: Center(
                  child: initials.isEmpty
                      ? Icon(Icons.person_rounded,
                          size: size * 0.55, color: AppColors.muted)
                      : Text(
                          initials,
                          style: TextStyle(
                            color: tint,
                            fontSize: size * 0.40,
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                            letterSpacing: 0.2,
                          ),
                        ),
                ),
              ),
      ),
    );
  }
}
