import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/player_face.dart';
import '../../widgets/problem_report.dart';

/// Who you have blocked, and the way back.
///
/// The reason this screen exists is not symmetry. A block you cannot review
/// is a block people hesitate to use — if the only way to undo it is to find
/// somebody you have made invisible, the decision feels permanent, and a
/// safety control that feels permanent is one people avoid at the moment they
/// most need it.
///
/// You cannot see who has blocked *you*, and there is no screen for that
/// anywhere. That asymmetry is deliberate: the quietness is what makes
/// blocking safe to do.
class BlockedPeopleScreen extends StatefulWidget {
  const BlockedPeopleScreen({required this.repository, super.key});

  final MusicRepository repository;

  @override
  State<BlockedPeopleScreen> createState() => _BlockedPeopleScreenState();
}

class _BlockedPeopleScreenState extends State<BlockedPeopleScreen> {
  List<BlockedPerson>? _people;
  String? _error;

  @override
  void initState() {
    super.initState();
    CurrentRoute.enter('Blocked people');
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final people = await widget.repository.peopleIBlocked();
      if (mounted) setState(() => _people = people);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _people = const <BlockedPerson>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'people_i_blocked',
          route: 'Blocked people',
        );
      });
    }
  }

  Future<void> _unblock(BlockedPerson person) async {
    try {
      await widget.repository.unblockUser(person.id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('${person.displayName} is unblocked.'),
        ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(reportAndDescribe(
            error,
            service: 'app',
            stage: 'unblock_user',
            route: 'Blocked people',
          )),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: const Text('Blocked people', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: people == null
            ? const Center(child: CircularProgressIndicator(color: AppColors.gold))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                children: <Widget>[
                  if (_error != null) ...<Widget>[
                    ProblemNote(_error!, fontSize: 13),
                    const SizedBox(height: 14),
                  ],
                  if (people.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 40, 10, 0),
                      child: Text(
                        'You have not blocked anybody.\n\nBlocking somebody '
                        'stops them finding you, asking you, or inviting you '
                        'to anything — and they are never told.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.muted, fontSize: 13.5, height: 1.5),
                      ),
                    )
                  else ...<Widget>[
                    for (final person in people)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: AppColors.raised,
                          clipBehavior: Clip.antiAlias,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: AppColors.line),
                          ),
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(12, 10, 8, 10),
                            child: Row(
                              children: <Widget>[
                                PlayerFace(
                                    name: person.displayName, size: 32),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    person.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.text,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(_unblock(person)),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.cyan,
                                    textStyle: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700),
                                  ),
                                  child: const Text('Unblock'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    const Text(
                      'Unblocking lets them find you in Open Mic again. It '
                      'does not tell them anything either.',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 12.5, height: 1.45),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
