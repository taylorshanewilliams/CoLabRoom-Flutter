import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/profile_face.dart';
import '../openmic/musician_profile_screen.dart';
import 'your_code_screen.dart';
import '../../widgets/note_that_fits.dart';

/// Somebody's card, opened from the code on their phone.
///
/// Taylor, 16 September 2026: "say you meet someone at a concert, or open mic
/// night, or anywhere, you could just scan each other's codes and become
/// friends in the app."
///
/// A scan lands here and does nothing else. The face and the name are there
/// so you can check it is the person in front of you -- a photo of a code is
/// not a person -- and adding is a tap, which is a request they answer. If
/// they have already scanned yours, the tap is the second yes and you are
/// connected on the spot. "Show my code" is on the same page because the
/// natural next move, standing there, is to hold yours up.
class AddPersonScreen extends StatefulWidget {
  const AddPersonScreen({required this.code, required this.repository, super.key});

  /// As it arrived: from the address, or typed.
  final String code;
  final MusicRepository repository;

  @override
  State<AddPersonScreen> createState() => _AddPersonScreenState();
}

class _AddPersonScreenState extends State<AddPersonScreen> {
  MetPerson? _person;
  String? _problem;
  String? _said;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final person = await widget.repository.personWithMeetingCode(widget.code);
      if (!mounted) return;
      setState(() {
        _person = person;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _problem = isRefusal(error)
            ? describeForUser(error)
            : reportAndDescribe(error, service: 'app', stage: 'meeting.open', route: 'Add somebody');
        _loading = false;
      });
    }
  }

  Future<void> _add(MetPerson person) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final connected = await widget.repository.requestConnection(person.personId);
      if (!mounted) return;
      setState(() {
        _person = MetPerson(
          personId: person.personId,
          displayName: person.displayName,
          avatarPath: person.avatarPath,
          plays: person.plays,
          standing: connected ? ConnectionStanding.accepted : ConnectionStanding.pending,
        );
        _said = connected
            ? 'You and ${person.displayName} are connected.'
            : 'Asked. You are connected once ${person.displayName} says yes, or scans your code.';
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showNote(
          isRefusal(error)
              ? describeForUser(error)
              : reportAndDescribe(error, service: 'app', stage: 'meeting.add', route: 'Add somebody'),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMyCode() {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: AppRoutes.yourCode),
      builder: (_) => YourCodeScreen(repository: widget.repository),
    )));
  }

  void _openTheirPage(MetPerson person) {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.musician(person.personId)),
      builder: (_) => MusicianProfileScreen(profileId: person.personId, repository: widget.repository),
    )));
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Add somebody')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: const Key('add_person_list'),
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
                children: person == null ? _nobody() : _card(person),
              ),
      ),
    );
  }

  List<Widget> _nobody() => <Widget>[
        const Icon(Icons.qr_code_2_rounded, size: 56, color: AppColors.muted),
        const SizedBox(height: 14),
        Text(
          _problem ?? 'That code does not open anybody.',
          key: const Key('add_person_problem'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.text, fontSize: 16, height: 1.4),
        ),
        const SizedBox(height: 22),
        Center(
          child: OutlinedButton.icon(
            key: const Key('add_person_my_code'),
            onPressed: _showMyCode,
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: const Text('Show my code'),
          ),
        ),
      ];

  List<Widget> _card(MetPerson person) {
    final controller = BetaScope.of(context);
    final name = person.displayName;
    return <Widget>[
      Center(
        child: ProfileFace(
          name: name,
          seed: person.personId,
          bytes: controller.avatarBytesFor(person.avatarPath),
          size: 96,
        ),
      ),
      const SizedBox(height: 14),
      Text(
        name,
        key: const Key('add_person_name'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.text, fontSize: 24, fontWeight: FontWeight.w800),
      ),
      if (person.plays.isNotEmpty) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          person.plays.join(' · '),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted, fontSize: 14),
        ),
      ],
      const SizedBox(height: 26),
      ..._action(person),
      if (_said case final said?) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          said,
          key: const Key('add_person_said'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.4),
        ),
      ],
      const SizedBox(height: 28),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: <Widget>[
          OutlinedButton.icon(
            key: const Key('add_person_my_code'),
            onPressed: _showMyCode,
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: const Text('Show my code'),
          ),
          TextButton(
            key: const Key('add_person_page'),
            onPressed: () => _openTheirPage(person),
            child: Text('$name\'s page'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _action(MetPerson person) {
    final name = person.displayName;
    final gold = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(50),
      backgroundColor: AppColors.gold,
      foregroundColor: AppColors.ink,
    );
    return switch (person.standing) {
      ConnectionStanding.accepted => <Widget>[
          if (_said == null)
            Text(
              'You and $name are already connected.',
              key: const Key('add_person_connected'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text, fontSize: 15),
            )
          else
            const Icon(Icons.check_circle_rounded, key: Key('add_person_connected'), color: AppColors.gold, size: 36),
        ],
      ConnectionStanding.pending when person.askedYou => <Widget>[
          FilledButton(
            key: const Key('add_person_add'),
            onPressed: _busy ? null : () => unawaited(_add(person)),
            style: gold,
            child: Text('Add $name back'),
          ),
          const SizedBox(height: 8),
          Text(
            '$name already asked to add you.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 13),
          ),
        ],
      ConnectionStanding.pending => <Widget>[
          FilledButton(
            key: const Key('add_person_add'),
            onPressed: null,
            style: gold,
            child: const Text('Asked'),
          ),
          if (_said == null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'You are connected once $name says yes, or scans your code.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
        ],
      ConnectionStanding.none => <Widget>[
          FilledButton(
            key: const Key('add_person_add'),
            onPressed: _busy ? null : () => unawaited(_add(person)),
            style: gold,
            child: Text('Add $name'),
          ),
        ],
    };
  }
}
