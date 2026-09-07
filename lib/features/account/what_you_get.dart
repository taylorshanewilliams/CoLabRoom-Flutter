import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';

/// What you get, and what you would be paying for.
///
/// **The free tier is the product, not a trailer for it.** Everything social
/// here — listening, rooms, recording, takes, the Open Mic, asking somebody
/// for help — is storage and bandwidth. It is cheap, it does not get more
/// expensive because people are enthusiastic, and charging for it would be
/// charging for the thing that makes the app worth opening.
///
/// The song sheet is the one operation that costs real money per use, and it
/// comes in two depths that were built long before anybody thought about
/// price. Chords, key, tempo and words cost about six tenths of a cent.
/// Doing it again after source separation — stems, structure, instruments,
/// and better chords on a dense mix — costs five to eight.
///
/// ANALYSIS_COST.md measured them against each other: **93.3% exact chord
/// agreement, 97.2% on the root**. That number is why this page can be
/// honest. The free sheet is not crippled; it is 93% of the answer for a
/// hundredth of the cost, and a thousand free accounts making five a month
/// is thirty dollars rather than four hundred.
///
/// **So this page does not sell by withholding.** It says what each thing
/// costs to run and what the difference actually is, because somebody who
/// can see the reason for a price is being treated as an adult — and because
/// the real argument for paying is stems and a synced sheet, not a number of
/// songs somebody was denied.
class WhatYouGet extends StatefulWidget {
  const WhatYouGet({super.key});

  @override
  State<WhatYouGet> createState() => _WhatYouGetState();
}

class _WhatYouGetState extends State<WhatYouGet> {
  MyPlan? _plan;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    CurrentRoute.enter('What you get');
    _load();
  }

  Future<void> _load() async {
    try {
      final plan = await BetaScope.of(context, listen: false).repository.myPlan();
      if (mounted) setState(() => (_plan = plan, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: const Text('What you get'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.gold))
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
                children: <Widget>[
                  if (plan != null) _Standing(plan: plan),
                  const SizedBox(height: 20),

                  const _Tier(
                    name: 'Free',
                    price: 'Always',
                    accent: AppColors.cyan,
                    // Deliberately the longer list. It is the longer list.
                    lines: <String>[
                      'Every song, room and set you want',
                      'Record and keep as many takes as you like',
                      'Song sheets — chords over your words, the key, the tempo',
                      'The Open Mic: listen, be heard, ask for help, be asked',
                      'Everything you make stays yours, and stays private '
                          'until you move it',
                    ],
                  ),
                  const SizedBox(height: 12),

                  const _Tier(
                    name: 'Member',
                    price: 'Later this year',
                    accent: AppColors.gold,
                    lines: <String>[
                      'Separated stems — hear the bass on its own, or mute it '
                          'and play along',
                      'The song sheet scrolling in time with the recording, '
                          'for playing rather than reading',
                      'Sharper chords on a dense mix, and the song’s '
                          'structure worked out',
                      'No monthly ceiling on song sheets',
                    ],
                  ),

                  const SizedBox(height: 24),
                  const _Honest(),
                ],
              ),
      ),
    );
  }
}

/// Where you actually stand, before either list.
///
/// A page about tiers that does not say which one you are on is a brochure.
class _Standing extends StatelessWidget {
  const _Standing({required this.plan});

  final MyPlan plan;

  @override
  Widget build(BuildContext context) {
    final left = plan.sheetsLeft;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.raised,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            plan.member ? 'You are a member' : 'You are on the free plan',
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            left == null
                ? 'Song sheets: as many as you want.'
                : left > 0
                    ? 'Song sheets this month: ${plan.sheetsThisMonth} made, '
                        '$left left.'
                    : 'You have used this month’s song sheets. They come '
                        'back on the first.',
            style: const TextStyle(
                color: AppColors.muted, fontSize: 12.5, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _Tier extends StatelessWidget {
  const _Tier({
    required this.name,
    required this.price,
    required this.accent,
    required this.lines,
  });

  final String name;
  final String price;
  final Color accent;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 15),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[accent.withValues(alpha: 0.07), AppColors.raised],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                price,
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(Icons.check_rounded, size: 14, color: accent),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      line,
                      style: const TextStyle(
                          color: AppColors.text, fontSize: 13, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The part most apps leave out.
class _Honest extends StatelessWidget {
  const _Honest();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.line),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'WHY IT IS SPLIT THIS WAY',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 9),
          Text(
            'Rooms, recording, takes and the Open Mic cost us almost nothing '
            'to run, so they are free and will stay free — charging for them '
            'would be charging for the reason to open the app.\n\n'
            'A song sheet is the one thing that costs real money each time. '
            'The free one skips a step called source separation: we measured '
            'both, and it agrees with the full one on 93% of chords. It is '
            'not a worse product, it is the same answer done cheaply.\n\n'
            'The full one pulls the instruments apart first. That is what '
            'gives you stems, the structure, and a sheet that scrolls in '
            'time — and it needs a graphics card for a few minutes per song, '
            'which is what you would be paying for.',
            style: TextStyle(
                color: AppColors.muted, fontSize: 12.5, height: 1.55),
          ),
        ],
      ),
    );
  }
}
