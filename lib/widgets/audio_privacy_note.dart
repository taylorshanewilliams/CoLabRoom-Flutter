import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

/// Where a recording actually goes when it's analysed.
///
/// People upload unreleased songs to this app. Three third parties touch that
/// audio and until now nothing in the interface said so — which is a
/// disclosure obligation before it's anything else, and the kind of thing
/// that is far better said by you than discovered by someone else.
///
/// Written once and shown in two places: at the moment of analysing, where
/// consent actually happens, and in Account, where somebody goes looking.
const String audioJourneyTitle = 'Where your audio goes';

const String audioJourneyBody =
    'Analysing a recording sends it off this device. It is uploaded to '
    'CoLabRoom\'s storage, then passed to a GPU service that separates the '
    'instruments and a chord-detection service that reads the harmony. If '
    'there is singing, the isolated vocal is sent to OpenAI\'s transcription '
    'API to work out the words.\n\n'
    'Analyses are cached by the recording\'s fingerprint. If the exact same '
    'file is analysed again — by you, or by anyone else who has that same '
    'file — the second one reuses the first result instead of processing it '
    'again. Nobody can reach an analysis without already having the '
    'recording it came from.\n\n'
    'Your recordings stay private to your catalogs. Removing a recording from a '
    'song deletes it and everything derived from it, and deleting your '
    'account removes all of it.';

Future<void> showAudioJourneySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(audioJourneyTitle, style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text(
                audioJourneyBody,
                style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.55),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The one-line version, for the moment somebody is about to analyse.
///
/// Quiet on purpose. This is not a consent gate — it is a fact that should be
/// available exactly where it becomes relevant, without turning starting an
/// analysis into a legal ceremony.
class AudioJourneyLink extends StatelessWidget {
  const AudioJourneyLink({super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showAudioJourneySheet(context),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            const Icon(Icons.info_outline_rounded, size: 13, color: AppColors.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'This sends your recording to our analysis services. '
                '$audioJourneyTitle ›',
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  height: 1.4,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.line,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
