import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/calls.dart';
import '../../services/user_facing_error.dart';

/// Asked once, before somebody's first call.
///
/// A month and a year rather than an "I am 18" box: calls for 13-17 come next,
/// through a parent or guardian, and the app has to know when a 16-year-old
/// turns 18 without asking again. The words say why it is asked and who sees
/// it, because a birth date asked for with no reason reads as data collection.
///
/// Returns the standing it saved, or null if the person closed it. An
/// under-13 answer closes it with [CallStanding.refused] rather than an error
/// beside a picker still open for an older year (audit, 17 September 2026):
/// the caller says so, and the server never lets the question be asked again
/// on that account (0138).
///
/// Lesson links ask it too, and save the same answer (0139), so [heading] and
/// [why] can say which of the two somebody is standing in front of, and
/// [stage] and [route] say which of the two a save that failed came from. A
/// question that only breaks on the lesson path would otherwise be filed as a
/// calls problem, and the week a new gate ships is the week that reading has
/// to be right. The defaults are a call's.
Future<CallStanding?> askBirthMonth(
  BuildContext context,
  MusicRepository repository, {
  String heading = 'Before your first call',
  String why = 'Which month and year were you born? Calls are for people 18 and over '
      'for now; calls for 13 to 17 with a parent or guardian are coming. '
      'Nobody else sees this, and you only say it once.',
  String stage = 'calls.birth_month',
  String route = 'Call',
}) {
  return showModalBottomSheet<CallStanding>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BirthMonthSheet(
      repository: repository,
      heading: heading,
      why: why,
      stage: stage,
      route: route,
    ),
  );
}

const List<String> _months = <String>[
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

class _BirthMonthSheet extends StatefulWidget {
  const _BirthMonthSheet({
    required this.repository,
    required this.heading,
    required this.why,
    required this.stage,
    required this.route,
  });

  final MusicRepository repository;
  final String heading;
  final String why;
  final String stage;
  final String route;

  @override
  State<_BirthMonthSheet> createState() => _BirthMonthSheetState();
}

class _BirthMonthSheetState extends State<_BirthMonthSheet> {
  int? _month;
  int? _year;
  String? _problem;
  bool _busy = false;

  Future<void> _save() async {
    final month = _month;
    final year = _year;
    if (month == null || year == null || _busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final standing = await widget.repository.setMyBirthMonth(year: year, month: month);
      if (!mounted) return;
      Navigator.of(context).pop(standing);
    } catch (error) {
      if (!mounted) return;
      // Refused because this account already answered under 13, on another
      // phone or on an app from before 0138: close rather than leave the
      // picker open for a try that can never be taken.
      if (isRefusal(error) && await _refusedAlready()) {
        if (mounted) Navigator.of(context).pop(CallStanding.refused);
        return;
      }
      if (!mounted) return;
      setState(() {
        _problem = isRefusal(error)
            ? describeForUser(error)
            : reportAndDescribe(error, service: 'app', stage: widget.stage, route: widget.route);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _refusedAlready() async {
    try {
      return await widget.repository.myCallStanding() == CallStanding.refused;
    } catch (_) {
      // The refusal is still said in the sheet.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final thisYear = DateTime.now().year;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 0, 22, 22 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.heading,
                style: const TextStyle(color: AppColors.text, fontSize: 21, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                widget.why,
                style: const TextStyle(color: AppColors.muted, fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<int>(
                      key: const Key('birth_month'),
                      initialValue: _month,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Month', border: OutlineInputBorder()),
                      items: <DropdownMenuItem<int>>[
                        for (var i = 0; i < _months.length; i++)
                          DropdownMenuItem<int>(value: i + 1, child: Text(_months[i])),
                      ],
                      onChanged: (value) => setState(() => _month = value),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<int>(
                      key: const Key('birth_year'),
                      initialValue: _year,
                      isExpanded: true,
                      menuMaxHeight: 320,
                      decoration: const InputDecoration(labelText: 'Year', border: OutlineInputBorder()),
                      items: <DropdownMenuItem<int>>[
                        for (var year = thisYear; year >= thisYear - 100; year--)
                          DropdownMenuItem<int>(value: year, child: Text('$year')),
                      ],
                      onChanged: (value) => setState(() => _year = value),
                    ),
                  ),
                ],
              ),
              if (_problem case final problem?) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  problem,
                  key: const Key('birth_problem'),
                  style: const TextStyle(color: AppColors.orange, fontSize: 13.5, height: 1.4),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton(
                key: const Key('birth_save'),
                onPressed: _month == null || _year == null || _busy ? null : () => unawaited(_save()),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.ink,
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
