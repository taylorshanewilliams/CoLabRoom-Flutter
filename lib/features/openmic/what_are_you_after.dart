import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/musical_roles.dart';

/// Which of the three things in this room you are looking at.
enum OpenMicLooking {
  /// People, ordered by how close they are to what you asked for.
  people,

  /// Songs that are short of something.
  songs,

  /// Things people have finished and chosen to show.
  finished,
}

/// What you are looking at, as one value.
///
/// The Open Mic used to hold this in four widgets — a segmented button, a set
/// of ticked chips, and two text fields — which is why the screen had to show
/// all four before it could show a person. Gathered into one object, the whole
/// query fits in a sentence, and a sentence is something a screen can print in
/// one line and put a chevron after.
@immutable
class OpenMicQuery {
  const OpenMicQuery({
    this.looking = OpenMicLooking.people,
    this.parts = const <String>{},
    this.sounds = '',
    this.city = '',
  });

  final OpenMicLooking looking;

  /// Roles, as stored strings. More than one, because "a singer who plays
  /// guitar" is one person and was two searches.
  final Set<String> parts;
  final String sounds;
  final String city;

  bool get isSongs => looking == OpenMicLooking.songs;
  bool get isFinished => looking == OpenMicLooking.finished;

  OpenMicQuery copyWith({
    OpenMicLooking? looking,
    Set<String>? parts,
    String? sounds,
    String? city,
  }) {
    return OpenMicQuery(
      looking: looking ?? this.looking,
      parts: parts ?? this.parts,
      sounds: sounds ?? this.sounds,
      city: city ?? this.city,
    );
  }

  /// The one line the screen prints where the filters used to be.
  ///
  /// It has to be a statement rather than a label — "Bass players near Leeds"
  /// says what you are looking at, and a control saying "Bass" only says what
  /// you pressed. Which matters most for the thing that used to be a bug:
  /// the same chip meant *who plays this* under one tab and *who needs this*
  /// under another, and nothing on screen said which way it pointed.
  String get sentence {
    if (isFinished) return 'Things people have finished';
    final family = RoleFamily.matching(parts);
    if (isSongs) {
      if (parts.isEmpty) return 'Songs asking for somebody';
      if (family != null) {
        return 'Songs that need ${family.label.toLowerCase()}';
      }
      final first = MusicalRole.parse(parts.first);
      return parts.length == 1
          ? 'Songs that need ${first.need}'
          : 'Songs that need ${first.need} and more';
    }
    final who =
        parts.isEmpty
            ? 'Everybody'
            : family != null
            ? family.label
            : parts.length == 1
            ? MusicalRole.parse(parts.first).plural
            : '${MusicalRole.parse(parts.first).plural} and more';
    if (city.trim().isEmpty) {
      return parts.isEmpty ? 'Everybody who is here' : who;
    }
    return '$who near ${city.trim()}';
  }

  /// The quiet line under it, which says what the order means.
  ///
  /// Kept because it is the sentence that stops "closest first" from reading
  /// as a ranking of who is better.
  String get caption {
    if (isFinished) return 'Newest first';
    if (isSongs) return 'Newest first — tap to change';
    final kind = sounds.trim();
    return kind.isEmpty
        ? 'Closest first — nobody is hidden'
        : 'Closest first · $kind';
  }
}

/// One question per screen, and back is free.
///
/// Everything the Open Mic used to lay out at once lives behind the sentence
/// now: four doors, then three to six roles, and the two text fields as rows
/// that show their own value the way a phone's settings list does. Two taps
/// reaches any role in the app.
///
/// **Every level is somewhere to stop.** The first row inside a door is
/// "anyone in voices and words", so nobody is made to pick a leaf to get an
/// answer — which is the difference between a trail and a form.
///
/// Changes are applied as they are made rather than on a Done button: the
/// room behind the sheet re-sorts while you are still deciding, so narrowing
/// is something you watch happen instead of something you submit.
Future<void> showWhatAreYouAfter(
  BuildContext context, {
  required OpenMicQuery query,
  required ValueChanged<OpenMicQuery> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.raised,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder:
        (sheetContext) => _WhatAreYouAfter(query: query, onChanged: onChanged),
  );
}

class _WhatAreYouAfter extends StatefulWidget {
  const _WhatAreYouAfter({required this.query, required this.onChanged});

  final OpenMicQuery query;
  final ValueChanged<OpenMicQuery> onChanged;

  @override
  State<_WhatAreYouAfter> createState() => _WhatAreYouAfterState();
}

class _WhatAreYouAfterState extends State<_WhatAreYouAfter> {
  late OpenMicQuery _query = widget.query;

  /// Which door is open, and null for the first screen.
  RoleFamily? _inside;

  /// A text question, when one is being asked instead of the list.
  _Field? _typing;
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _apply(OpenMicQuery next, {bool close = false}) {
    setState(() => _query = next);
    widget.onChanged(next);
    if (close) Navigator.of(context).maybePop();
  }

  void _pick(Iterable<MusicalRole> roles) {
    _apply(
      _query.copyWith(
        parts: <String>{for (final role in roles) role.value},
        // Picking a role while looking at finished work means you wanted to
        // search, not to browse the showcase. Silently leaving the view on
        // "finished" would make the pick do nothing.
        looking: _query.isFinished ? OpenMicLooking.people : _query.looking,
      ),
      close: true,
    );
  }

  void _ask(_Field field) {
    _text.text = field == _Field.city ? _query.city : _query.sounds;
    setState(() => _typing = field);
  }

  void _saveTyped() {
    final value = _text.text.trim();
    _apply(
      _typing == _Field.city
          ? _query.copyWith(city: value)
          : _query.copyWith(sounds: value),
    );
    setState(() => _typing = null);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 18,
        ),
        // Scrolling, because the first screen is nine rows and somebody
        // reading at 1.3x has a shorter sheet than the one this was drawn
        // for. The layout suite caught it overflowing by 95 pixels, which is
        // exactly the failure that ships as "it looks fine on my phone".
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children:
                _typing != null
                    ? _typingScreen()
                    : _inside != null
                    ? _insideDoor(_inside!)
                    : _firstScreen(),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ screens

  List<Widget> _firstScreen() {
    return <Widget>[
      const _Title('What are you after?'),
      // The direction, at the moment of deciding and nowhere else. On the
      // screen behind, it was a tab, and the same chip meant opposite things
      // depending on which tab was selected.
      _Direction(
        looking: _query.looking,
        onChanged: (looking) => _apply(_query.copyWith(looking: looking)),
      ),
      const SizedBox(height: 8),
      _Row(
        label: 'Everybody',
        selected: _query.parts.isEmpty && !_query.isFinished,
        onTap:
            () => _apply(
              _query.copyWith(
                parts: const <String>{},
                looking:
                    _query.isFinished ? OpenMicLooking.people : _query.looking,
              ),
              close: true,
            ),
      ),
      for (final family in RoleFamily.values)
        _Row(
          label: family.label,
          icon: family.icon,
          chevron: true,
          value: _chosenIn(family),
          onTap: () => setState(() => _inside = family),
        ),
      const SizedBox(height: 10),
      // The two old text fields, as rows that carry their own answer. A
      // phone's settings list has said "Wi-Fi ... HomeNetwork" for fifteen
      // years for a reason: you can read the value without opening the row.
      _Row(
        label: 'Kind of music',
        value: _query.sounds.trim().isEmpty ? 'Any' : _query.sounds.trim(),
        chevron: true,
        onTap: () => _ask(_Field.sounds),
      ),
      if (!_query.isSongs)
        _Row(
          label: 'Where',
          value: _query.city.trim().isEmpty ? 'Anywhere' : _query.city.trim(),
          chevron: true,
          onTap: () => _ask(_Field.city),
        ),
      const SizedBox(height: 10),
      // Not a tab any more. A showcase is not a marketplace, and it was
      // taking a third of the width of the only control on the screen to say
      // so — while the songs on it belong on the cards of the people who
      // made them.
      _Row(
        label: 'Hear what people have finished',
        icon: Icons.auto_awesome_rounded,
        selected: _query.isFinished,
        onTap:
            () => _apply(
              _query.copyWith(looking: OpenMicLooking.finished),
              close: true,
            ),
      ),
    ];
  }

  List<Widget> _insideDoor(RoleFamily family) {
    return <Widget>[
      _Back(label: family.label, onTap: () => setState(() => _inside = null)),
      // Somewhere to stop. Wanting "a voice" is a real thing to want, and
      // making somebody choose between five kinds of voice to get an answer
      // is a form asking a question the person does not have.
      _Row(
        label: 'Anyone in ${family.label.toLowerCase()}',
        onTap: () => _pick(family.members),
      ),
      for (final role in family.members)
        _Row(
          label: role.label,
          icon: role.icon,
          value: role.note,
          selected: _query.parts.contains(role.value),
          onTap: () => _pick(<MusicalRole>[role]),
        ),
    ];
  }

  List<Widget> _typingScreen() {
    final city = _typing == _Field.city;
    return <Widget>[
      _Back(
        label: city ? 'Where' : 'Kind of music',
        onTap: () => setState(() => _typing = null),
      ),
      TextField(
        controller: _text,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _saveTyped(),
        decoration: InputDecoration(
          hintText: city ? 'A town, or anywhere' : 'Anything at all',
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(onPressed: _saveTyped, child: const Text('Done')),
      ),
    ];
  }

  /// What is ticked behind a door, for the right-hand side of its row.
  String? _chosenIn(RoleFamily family) {
    final chosen = family.members
        .where((role) => _query.parts.contains(role.value))
        .toList(growable: false);
    if (chosen.isEmpty) return null;
    if (chosen.length == family.members.length) return 'Anyone';
    return chosen.length == 1
        ? chosen.first.label
        : '${chosen.first.label} +${chosen.length - 1}';
  }
}

enum _Field { sounds, city }

/// A settings row: what it is on the left, where it stands on the right.
class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.onTap,
    this.value,
    this.icon,
    this.chevron = false,
    this.selected = false,
  });

  final String label;
  final String? value;
  final IconData? icon;
  final bool chevron;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.line, width: 0.5)),
        ),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(
                icon,
                size: 18,
                color: selected ? AppColors.cyan : AppColors.muted,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.cyan : AppColors.text,
                  fontSize: 15,
                ),
              ),
            ),
            if (value != null)
              Flexible(
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ),
            if (selected && !chevron)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.check_rounded,
                  size: 17,
                  color: AppColors.cyan,
                ),
              ),
            if (chevron)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColors.muted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
      ),
    );
  }
}

class _Back extends StatelessWidget {
  const _Back({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.chevron_left_rounded,
                    size: 20,
                    color: AppColors.cyan,
                  ),
                  Text(
                    'Back',
                    style: TextStyle(color: AppColors.cyan, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who plays it, or who needs it.
///
/// Two words that decide what every row below them means. It lives inside the
/// sheet on purpose: on the screen it was a tab, which meant you could be
/// looking at a filtered list without the thing that inverted it anywhere in
/// sight.
class _Direction extends StatelessWidget {
  const _Direction({required this.looking, required this.onChanged});

  final OpenMicLooking looking;
  final ValueChanged<OpenMicLooking> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _half('Who plays it', OpenMicLooking.people),
        const SizedBox(width: 8),
        _half('Who needs it', OpenMicLooking.songs),
      ],
    );
  }

  Widget _half(String label, OpenMicLooking value) {
    // Finished is neither, and lighting up one of the two while looking at
    // the showcase would say something untrue about where you are.
    final on = looking == value;
    return Expanded(
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: on ? AppColors.cyan.withValues(alpha: 0.12) : null,
            border: Border.all(color: on ? AppColors.cyan : AppColors.line),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: on ? AppColors.cyan : AppColors.muted,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
