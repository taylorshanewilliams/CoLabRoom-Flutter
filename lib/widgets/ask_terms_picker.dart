import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';

/// What answering this ask will mean, chosen before it is sent.
///
/// Every Musician, Same Song, 17 September 2026: co-writing fights are two
/// honest memories of a session nobody wrote down. One person remembers a
/// favour, the other remembers a co-write, and the disagreement was made when
/// the ask went out without saying which it was.
///
/// One picker rather than two, in one file, because the sentence under it is
/// the thing being promised: the room's ask and the ask sent to one musician
/// have to offer the same words or the promise is two promises.
///
/// Playing is the default and shows nothing, here or anywhere else. Nearly
/// every ask in this app is somebody wanting bass under a chorus, and small
/// print on all of those would make the normal case read like a contract.
class AskTermsPicker extends StatelessWidget {
  const AskTermsPicker({
    required this.terms,
    required this.onChanged,
    super.key,
  });

  final AskTerms terms;
  final ValueChanged<AskTerms> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: <Widget>[
            _Option(
              label: 'Play on it',
              value: AskTerms.play,
              chosen: terms,
              onChanged: onChanged,
            ),
            _Option(
              label: 'Write on it',
              value: AskTerms.write,
              chosen: terms,
              onChanged: onChanged,
            ),
          ],
        ),
        // Shown to the asker as soon as they pick it, in the words the person
        // they are asking will read. Nobody should send a sentence they have
        // not seen.
        if (terms.notice != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            terms.notice!,
            key: const Key('ask_terms_notice'),
            style: const TextStyle(
                color: AppColors.muted, fontSize: 12, height: 1.4),
          ),
        ],
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.value,
    required this.chosen,
    required this.onChanged,
  });

  final String label;
  final AskTerms value;
  final AskTerms chosen;
  final ValueChanged<AskTerms> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value == chosen;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      // Tapping the one already chosen does nothing rather than clearing it:
      // an ask always has terms, so there is no third state to fall back to.
      onSelected: (_) => onChanged(value),
      showCheckmark: false,
      backgroundColor: AppColors.raised,
      selectedColor: AppColors.cyan.withValues(alpha: 0.18),
      side: BorderSide(color: selected ? AppColors.cyan : AppColors.line),
      labelStyle: TextStyle(
        color: selected ? AppColors.cyan : AppColors.text,
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
