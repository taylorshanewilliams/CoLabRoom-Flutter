import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/musical_roles.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/offer_notifications.dart';
import '../../widgets/problem_report.dart';
import '../../services/user_facing_error.dart';
import 'interludes.dart';

/// The first two minutes, and the four facts the app cannot work without.
///
/// Open Mic matches people on `plays`, `city` and `soundsLike`. Nothing has
/// ever asked for any of them. `BeFound` says the consequence out loud —
/// "almost nobody in production is findable… nobody says what they play
/// either, which is the second lock on the same door" — so the room a new
/// person walks into has one person in it, and the feature the whole app is
/// pointed at looks broken when it is merely empty.
///
/// That is not a discovery problem, it is an empty-column problem, and the
/// only moment anybody will fill four columns in is before they have anything
/// else to do.
///
/// **So it has to not feel like a form.** Five taps is nothing; a form is the
/// thing people decline, because work before you have seen what you came for
/// is work you say no to. Every question here is one line and one tap, every
/// one can be skipped, and between them the app does something worth
/// watching — see [Interlude]. Nobody reads an onboarding. They will tap
/// through one that is fun to look at.
/// Why this flow is running.
enum WelcomeMode {
  /// The first time, before anybody has anything else to do.
  firstRun,

  /// Asked for, from the Account screen, at any time afterwards.
  ///
  /// The same questions, filled in with what you already said — which turns
  /// them from *tell us about yourself* into *here is what we have, change
  /// anything* — with a short tour of what the app does woven between them.
  ///
  /// Both jobs at once, deliberately. Somebody who comes here to change their
  /// instruments gets shown what Open Mic is for on the way past, and somebody
  /// who comes here because they are lost ends up with a filled-in profile.
  /// Neither is a detour from the other.
  tour,
}

class WelcomeFlow extends StatefulWidget {
  const WelcomeFlow({
    required this.repository,
    required this.displayName,
    this.mode = WelcomeMode.firstRun,
    super.key,
  });

  final MusicRepository repository;
  final String displayName;
  final WelcomeMode mode;

  /// Bumped to ask again.
  ///
  /// Everybody who already has the app has never been asked any of this, so
  /// their `plays`, `city` and `soundsLike` are empty and Open Mic cannot see
  /// them. Changing this string is the whole mechanism: the old key stops
  /// being read, every existing install looks like a fresh one, and the flow
  /// runs once more.
  ///
  /// Do it deliberately and rarely. It is the one thing in this app that can
  /// interrupt every user at once, and a version that shipped a bump by
  /// accident would put a questionnaire in front of people who had already
  /// answered it.
  static const String _seenKey = 'welcome_flow_seen_v2';

  /// Shows this once, ever, and never blocks a returning person.
  ///
  /// Written before the flow rather than after it, so somebody who force
  /// quits halfway through is not met by the same five questions every time
  /// they open the app. A half-filled profile is a much smaller problem than
  /// an app that will not let you past its own welcome.
  static Future<void> offerOnce(
    BuildContext context, {
    required MusicRepository repository,
    required String displayName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seenKey) ?? false) return;
    await prefs.setBool(_seenKey, true);

    // Somebody already using the app is not new, and telling them "Welcome,
    // Taylor. Four questions." reads as the app having forgotten them. They
    // get the tour instead: the same questions, holding whatever they have
    // already said, with what the app does woven between them.
    //
    // Which is also the better outcome for the thing this is for. A returning
    // person with an empty `plays` still ends up filling it in; they just are
    // not greeted like a stranger on the way.
    final returning = await _hasBeenHere(repository);
    if (!context.mounted) return;

    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      settings: const RouteSettings(name: 'Welcome'),
      builder: (_) => WelcomeFlow(
        repository: repository,
        displayName: displayName,
        mode: returning ? WelcomeMode.tour : WelcomeMode.firstRun,
      ),
    ));
  }

  /// Whether this account has been using the app already.
  ///
  /// Anything at all on the shelf counts. A profile is the wrong signal —
  /// nothing has ever asked for one, so a person who has been here for weeks
  /// has exactly the same empty profile as somebody who signed up a minute
  /// ago, which is the whole reason this flow exists.
  ///
  /// Best effort: a repository that cannot answer gets the first-run
  /// greeting, which is wrong for a returning person and harmless.
  static Future<bool> _hasBeenHere(MusicRepository repository) async {
    try {
      final rooms = await repository.loadRooms();
      return rooms.any((room) => room.projects.isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  /// Run it again, from wherever somebody asked.
  static Future<void> show(
    BuildContext context, {
    required MusicRepository repository,
    required String displayName,
  }) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      settings: const RouteSettings(name: 'Tour'),
      builder: (_) => WelcomeFlow(
        repository: repository,
        displayName: displayName,
        mode: WelcomeMode.tour,
      ),
    ));
  }

  @override
  State<WelcomeFlow> createState() => _WelcomeFlowState();
}

/// One screen in the sequence.
///
/// A list rather than an index, because the two modes are different lengths
/// and different orders, and arithmetic over "stage 3" stopped meaning
/// anything the moment a tour card sat between two questions.
enum _Stage {
  hello,
  aboutSongs,
  plays,
  aboutRooms,
  where,
  aboutOpenMic,
  sounds,
  findable,
}

class _WelcomeFlowState extends State<WelcomeFlow> {
  int _stage = 0;
  Interlude _next = Interlude.sticks;
  Interlude? _playing;

  final Set<MusicalRole> _plays = <MusicalRole>{};
  final Set<String> _sounds = <String>{};
  final TextEditingController _city = TextEditingController();
  final TextEditingController _sound = TextEditingController();
  bool _findable = true;
  bool _saving = false;
  String? _error;

  /// The first run stays four questions. Adding the tour to it would be
  /// exactly the wall this flow was written to avoid — somebody who has not
  /// seen the app yet has nothing to hang a tour on.
  late final List<_Stage> _order = widget.mode == WelcomeMode.firstRun
      ? const <_Stage>[
          _Stage.hello,
          _Stage.plays,
          _Stage.where,
          _Stage.sounds,
          _Stage.findable,
        ]
      : const <_Stage>[
          _Stage.hello,
          _Stage.aboutSongs,
          _Stage.plays,
          _Stage.aboutRooms,
          _Stage.where,
          _Stage.aboutOpenMic,
          _Stage.sounds,
          _Stage.findable,
        ];

  @override
  void initState() {
    super.initState();
    if (widget.mode == WelcomeMode.tour) unawaited(_loadWhatTheySaid());
  }

  /// What is already on the profile, so nothing has to be typed twice.
  ///
  /// Best effort and silent. Somebody who came here to be shown around should
  /// not be met by an error about a profile fetch; the worst case is a form
  /// that starts empty, which is exactly what the first run does anyway.
  Future<void> _loadWhatTheySaid() async {
    try {
      final me =
          await widget.repository.loadMusician(widget.repository.currentUserId);
      if (me == null || !mounted) return;
      setState(() {
        _plays
          ..clear()
          ..addAll(me.plays
              .map(_roleFor)
              .whereType<MusicalRole>());
        _sounds
          ..clear()
          ..addAll(me.soundsLike);
        _city.text = me.city ?? '';
        _findable = me.discoverable ?? false;
      });
    } catch (_) {
      // Nothing to say about it. See above.
    }
  }

  /// A stored value back to the role it names, or null for one this build does
  /// not know — `plays` is production data and may hold a word retired since.
  MusicalRole? _roleFor(String value) {
    for (final role in MusicalRole.values) {
      if (role.value == value) return role;
    }
    return null;
  }

  @override
  void dispose() {
    _city.dispose();
    _sound.dispose();
    super.dispose();
  }

  void _advance() {
    if (_stage >= _order.length - 1) {
      unawaited(_finish());
      return;
    }
    // Somebody who has asked for less motion gets less motion. The interlude
    // is the best thing here and it is still not worth making a person ill.
    if (MediaQuery.of(context).disableAnimations) {
      setState(() => _stage += 1);
      return;
    }
    setState(() => _playing = _next);
  }

  void _onMidpoint() {
    setState(() {
      _stage += 1;
      _next = _next.next;
    });
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // Taken before anything pops. Both outlive this widget; `context` does
    // not, and the snackbar has to be shown after the flow has gone.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.repository.setOpenMicPresence(
        discoverable: _findable,
        city: _city.text.trim(),
        plays: _plays.map((role) => role.value).toList(growable: false),
        soundsLike: _sounds.toList(growable: false),
      );
      if (!mounted) return;

      // After every question and before the flow closes.
      //
      // After the questions because a permission prompt is the one thing here
      // that cannot be undone by tapping again, and it is worth far more once
      // somebody has said what they play — the reason can name their own
      // answer back to them.
      //
      // Before the close because `offerNotifications` checks `context.mounted`
      // before it shows anything, and popping first unmounts this widget. It
      // was being called on a dead context and doing nothing at all, silently,
      // which is exactly the shape of bug that never gets noticed: the prompt
      // not appearing looks identical to the prompt having been declined.
      await offerNotifications(
        context,
        title: 'Want to know when somebody answers?',
        because: _plays.isEmpty
            ? 'We will tell you when somebody offers to play on your songs, '
                'and when a Room you are in gets something new.'
            : 'We will tell you when somebody needs '
                '${_plays.first.label.toLowerCase()} on a song, and when '
                'somebody offers to play on yours.',
      );
      navigator.pop();

      // Where to find this again, said once, at the only moment it means
      // anything — the flow has just closed, the Account button is on screen,
      // and somebody has just been shown that these questions are painless.
      // Said on the way out rather than as a card of its own, because a
      // screen whose entire content is "by the way, you can do this again"
      // is a screen that earns a tap and gives nothing back.
      if (widget.mode == WelcomeMode.firstRun) {
        messenger.showSnackBar(const SnackBar(
          duration: Duration(seconds: 7),
          content: Text(
            'Saved. Account → Show me around takes you back through this any '
            'time, with a tour of the app.',
          ),
        ));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = reportAndDescribe(error, service: 'app', route: 'Welcome');
      });
    }
  }

  void _skipAll() {
    // Nothing saved, nothing asked. Somebody who wants to see the app is
    // owed the app.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      body: Stack(
        children: <Widget>[
          SafeArea(
            // A column, centred, at every width.
            //
            // Nothing here wants a monitor. Sixteen genre chips spread across
            // 1900 pixels is a search result, not a question, and a heading
            // set at 27px in the corner of that much empty navy reads as an
            // error page. On a phone this constraint does nothing at all; on
            // a desk it is the difference between a form and a card.
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: <Widget>[
                    _Progress(
                      stage: _stage,
                      of: _order.length,
                      onSkip: _skipAll,
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: KeyedSubtree(
                          key: ValueKey<int>(_stage),
                          child: _card(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_playing != null)
            Positioned.fill(
              child: InterludeCurtain(
                key: ValueKey<Interlude>(_playing!),
                kind: _playing!,
                onMidpoint: _onMidpoint,
                onDone: () => setState(() => _playing = null),
              ),
            ),
        ],
      ),
    );
  }

  Widget _card() => switch (_order[_stage]) {
        _Stage.hello => _Hello(
            name: widget.displayName,
            tour: widget.mode == WelcomeMode.tour,
            onStart: _advance,
          ),
        _Stage.aboutSongs => _About(
            icon: Icons.library_music_rounded,
            title: 'A song is one place',
            line: 'Words, chords and every take you record, together.',
            onNext: _advance,
          ),
        _Stage.aboutRooms => _About(
            icon: Icons.groups_2_rounded,
            title: 'You choose who hears it',
            line: 'Every song has an audience, from nobody to everybody. '
                'You can move it any time.',
            onNext: _advance,
          ),
        _Stage.aboutOpenMic => _About(
            icon: Icons.mic_external_on_rounded,
            title: 'Say what a song needs',
            line: 'Put it on the Open Mic and somebody who plays that thing '
                'can answer.',
            onNext: _advance,
          ),
        _Stage.plays => _WhatYouPlay(
            chosen: _plays,
            onToggle: (role) => setState(() {
              _plays.contains(role) ? _plays.remove(role) : _plays.add(role);
            }),
            onNext: _advance,
          ),
        _Stage.where => _WhereYouAre(controller: _city, onNext: _advance),
        _Stage.sounds => _WhatYouSoundLike(
            chosen: _sounds,
            field: _sound,
            onToggle: (tag) => setState(() {
              _sounds.contains(tag) ? _sounds.remove(tag) : _sounds.add(tag);
            }),
            onNext: _advance,
          ),
        _Stage.findable => _CanTheyFindYou(
            tour: widget.mode == WelcomeMode.tour,
            findable: _findable,
            saving: _saving,
            error: _error,
            plays: _plays,
            city: _city.text.trim(),
            onChanged: (value) => setState(() => _findable = value),
            onFinish: _advance,
          ),
      };
}

// ------------------------------------------------------------------ chrome

class _Progress extends StatelessWidget {
  const _Progress({required this.stage, required this.of, required this.onSkip});

  final int stage;
  final int of;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 4),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < of; i += 1)
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              margin: const EdgeInsets.only(right: 6),
              height: 4,
              width: i == stage ? 26 : 12,
              decoration: BoxDecoration(
                color: i <= stage ? AppColors.cyan : AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          const Spacer(),
          TextButton(
            onPressed: onSkip,
            style: TextButton.styleFrom(foregroundColor: AppColors.muted),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
  }
}

/// The question, in the largest type on the screen, and nothing under it.
class _Ask extends StatelessWidget {
  const _Ask(this.question, {this.hint});

  final String question;

  /// Only where the question genuinely needs it. Most do not.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          question,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 27,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        if (hint != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            hint!,
            style: const TextStyle(color: AppColors.muted, fontSize: 13.5),
          ),
        ],
      ],
    );
  }
}

/// A chip that feels like a button being pressed.
///
/// Scale rather than a colour change alone, because the whole bet of this
/// flow is that answering is enjoyable, and a chip that only recolours reads
/// as a checkbox.
class _Tap extends StatefulWidget {
  const _Tap({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_Tap> createState() => _TapState();
}

class _TapState extends State<_Tap> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.94 : 1,
        duration: const Duration(milliseconds: 90),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          // 48 tall, which is Material's minimum and Apple's with room over.
          // The audit found this app's own toolbars at 38 and 33.
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.selected ? AppColors.cyan : AppColors.raised,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: widget.selected ? AppColors.cyan : AppColors.line,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Icon(widget.icon,
                    size: 17,
                    color: widget.selected ? AppColors.ink : AppColors.muted),
                const SizedBox(width: 7),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  // Dark on cyan, which is 11:1. White on cyan would be 1.8:1
                  // and is the mistake the contrast rule exists to catch.
                  color: widget.selected ? AppColors.ink : AppColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Onward extends StatelessWidget {
  const _Onward({required this.label, required this.onTap, this.busy = false});

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: FilledButton(
        onPressed: busy ? null : onTap,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.cyan,
          foregroundColor: AppColors.ink,
          disabledBackgroundColor: AppColors.line,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: AppColors.ink),
              )
            // Styled here rather than through `styleFrom(textStyle:)`, which
            // *replaces* the button's resolved text style instead of merging
            // into it — and takes the font family with it.
            : Text(
                label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
              ),
      ),
    );
  }
}

const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(20, 10, 20, 20);

// ------------------------------------------------------------------- cards

class _Hello extends StatelessWidget {
  const _Hello({
    required this.name,
    required this.onStart,
    this.tour = false,
  });

  final String name;
  final VoidCallback onStart;
  final bool tour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Spacer(),
          const BrandMark(),
          const SizedBox(height: 22),
          _Ask(
            tour
                ? 'A look around.'
                : (name.trim().isEmpty
                    ? 'Welcome.'
                    : 'Welcome, ${name.trim()}.'),
            // The only sentence in the flow that explains anything, and it
            // exists to promise how short this is.
            hint: tour
                ? 'What the app does, and everything you told us — change '
                    'anything as we go.'
                : 'Four questions. Then the app knows who to put in front of '
                    'you.',
          ),
          const Spacer(),
          _Onward(label: tour ? 'Show me' : "Let's go", onTap: onStart),
        ],
      ),
    );
  }
}

class _WhatYouPlay extends StatelessWidget {
  const _WhatYouPlay({
    required this.chosen,
    required this.onToggle,
    required this.onNext,
  });

  final Set<MusicalRole> chosen;
  final ValueChanged<MusicalRole> onToggle;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _Ask('What do you play?'),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final family in RoleFamily.values) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 8),
                      child: Row(
                        children: <Widget>[
                          Icon(family.icon, size: 15, color: AppColors.muted),
                          const SizedBox(width: 7),
                          Text(
                            family.label,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final role in family.members)
                          _Tap(
                            label: role.label,
                            selected: chosen.contains(role),
                            onTap: () => onToggle(role),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Onward(
            label: chosen.isEmpty ? 'Not yet' : 'Next',
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _WhereYouAre extends StatelessWidget {
  const _WhereYouAre({required this.controller, required this.onNext});

  final TextEditingController controller;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _Ask(
            'Where are you?',
            hint: 'Used to put nearby people first. Never shown as anything '
                'more precise than a town.',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onNext(),
            style: const TextStyle(color: AppColors.text, fontSize: 18),
            decoration: InputDecoration(
              hintText: 'Town or city',
              hintStyle: const TextStyle(color: AppColors.muted),
              filled: true,
              fillColor: AppColors.raised,
              prefixIcon: const Icon(Icons.place_outlined,
                  color: AppColors.muted, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const Spacer(),
          _Onward(label: 'Next', onTap: onNext),
        ],
      ),
    );
  }
}

class _WhatYouSoundLike extends StatefulWidget {
  const _WhatYouSoundLike({
    required this.chosen,
    required this.field,
    required this.onToggle,
    required this.onNext,
  });

  final Set<String> chosen;
  final TextEditingController field;
  final ValueChanged<String> onToggle;
  final VoidCallback onNext;

  @override
  State<_WhatYouSoundLike> createState() => _WhatYouSoundLikeState();
}

class _WhatYouSoundLikeState extends State<_WhatYouSoundLike> {
  /// Somewhere to start, not a taxonomy.
  ///
  /// `soundsLike` is free text on purpose — "nobody earns a genre, so this
  /// can order a list without ever ranking a person" — so these are only here
  /// because an empty box with no examples is the question people skip.
  static const List<String> _starters = <String>[
    'indie', 'folk', 'rock', 'metal', 'punk', 'hip-hop',
    'r&b', 'soul', 'country', 'jazz', 'blues', 'electronic',
    'pop', 'worship', 'lo-fi', 'acoustic',
  ];

  void _add() {
    final text = widget.field.text.trim().toLowerCase();
    if (text.isEmpty) return;
    widget.onToggle(text);
    widget.field.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final typed = widget.chosen.where((t) => !_starters.contains(t)).toList();
    return Padding(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _Ask(
            'Who do you sound like?',
            hint: 'Bands, or just words. This is what makes "like-minded" '
                'mean anything.',
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: widget.field,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                  style: const TextStyle(color: AppColors.text, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Add a band or a word',
                    hintStyle: const TextStyle(color: AppColors.muted),
                    filled: true,
                    fillColor: AppColors.raised,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _add,
                tooltip: 'Add this',
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.raised,
                  foregroundColor: AppColors.cyan,
                  minimumSize: const Size(48, 48),
                ),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final tag in typed)
                    _Tap(
                      label: tag,
                      selected: true,
                      icon: Icons.close_rounded,
                      onTap: () => widget.onToggle(tag),
                    ),
                  for (final tag in _starters)
                    _Tap(
                      label: tag,
                      selected: widget.chosen.contains(tag),
                      onTap: () => widget.onToggle(tag),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Onward(
            label: widget.chosen.isEmpty ? 'Not yet' : 'Next',
            onTap: widget.onNext,
          ),
        ],
      ),
    );
  }
}

class _CanTheyFindYou extends StatelessWidget {
  const _CanTheyFindYou({
    required this.tour,
    required this.findable,
    required this.saving,
    required this.error,
    required this.plays,
    required this.city,
    required this.onChanged,
    required this.onFinish,
  });

  final bool tour;
  final bool findable;
  final bool saving;
  final String? error;
  final Set<MusicalRole> plays;
  final String city;
  final ValueChanged<bool> onChanged;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    // Their own answers, read back. This is the last screen before a privacy
    // switch, and the switch means nothing unless somebody can see what it
    // would publish.
    final what = plays.isEmpty
        ? 'what you play'
        : plays.map((role) => role.label).join(', ');

    return Padding(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _Ask('Can people find you?'),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.raised,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'They would see $what'
                  '${city.isEmpty ? '' : ', and that you are near $city'}.',
                  style: const TextStyle(
                      color: AppColors.text, fontSize: 15, height: 1.45),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your songs stay private until you put one out there. '
                  'You can turn this off any time.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 13, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: _Tap(
                  label: 'Yes, find me',
                  selected: findable,
                  onTap: () => onChanged(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Tap(
                  label: 'Not yet',
                  selected: !findable,
                  onTap: () => onChanged(false),
                ),
              ),
            ],
          ),
          const Spacer(),
          if (error != null) ...<Widget>[
            ProblemNote(error!, route: 'Welcome'),
            const SizedBox(height: 10),
          ],
          _Onward(
            label: tour ? 'Save it' : 'Start playing',
            onTap: onFinish,
            busy: saving,
          ),
        ],
      ),
    );
  }
}

/// One thing the app does, in a sentence.
///
/// Deliberately thin. Three of these is the entire walkthrough, because a
/// tour that has to be read is a tour that gets skipped — and the sentence is
/// only here to give the question after it something to hang on.
class _About extends StatelessWidget {
  const _About({
    required this.icon,
    required this.title,
    required this.line,
    required this.onNext,
  });

  final IconData icon;
  final String title;
  final String line;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Spacer(),
          Container(
            height: 84,
            width: 84,
            decoration: BoxDecoration(
              color: AppColors.cyan.withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: AppColors.cyan),
          ),
          const SizedBox(height: 22),
          _Ask(title, hint: line),
          const Spacer(),
          _Onward(label: 'Next', onTap: onNext),
        ],
      ),
    );
  }
}
