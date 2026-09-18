import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/lesson_link.dart';
import '../../services/invite_link.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/qr_code.dart';
import 'lesson_poster.dart';
import 'with_birth_month.dart';
import '../../services/copy_text.dart';

/// A teacher's lesson links: a QR code each, and a room of their own with
/// the teacher for every student who opens one.
///
/// Taylor, 16 September 2026: "a way for teachers to start learning rooms
/// ... they can email out or share a qr code or whatever, and the student
/// could join right into their room." One code on the studio wall, in a
/// newsletter, in a text -- and no student ever lands in a room with
/// another student's takes, because each of them gets their own.
///
/// Every Musician, Same Song, 17 September 2026 (slice 16): a teacher keeps
/// several, each named for what it opens, because Tuesday beginners and the
/// jazz combo cannot share a poster. And a link can be a class: everybody
/// who opens it also lands in one room with the whole class, to listen, and
/// still records in their own room with the teacher.
///
/// Before there is a link the screen asks a single question, what you teach,
/// because that is what every student's room will be called. After that it
/// is the list, and each link opens onto its code.
class LessonLinkScreen extends StatefulWidget {
  const LessonLinkScreen({required this.repository, this.teacherName = '', super.key});

  final MusicRepository repository;

  /// Who teaches, for the poster ("with Taylor"). Left off when unknown.
  final String teacherName;

  @override
  State<LessonLinkScreen> createState() => _LessonLinkScreenState();
}

class _LessonLinkScreenState extends State<LessonLinkScreen> {
  final TextEditingController _title = TextEditingController();
  List<LessonLink> _links = const <LessonLink>[];

  /// The link whose code is on screen, or null for the list.
  LessonLink? _open;

  /// The form for another link, on top of a list that already has some.
  bool _making = false;

  /// The form's answer to "a class?".
  bool _asClass = false;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final links = await widget.repository.myLessonLinks();
      if (!mounted) return;
      setState(() {
        _links = links;
        _loading = false;
        // The one on screen, as it is now.
        final open = _open;
        if (open != null) {
          _open = null;
          for (final link in links) {
            if (link.id == open.id) _open = link;
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.load', route: 'Lesson link'));
    }
  }

  Future<void> _make() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Both ends of a lesson link are adults for now (0139), so the server
      // may want a birth month before it makes one.
      final link = await withBirthMonth(
        () => widget.repository.openLessonLink(_title.text, asClass: _asClass),
        context: context,
        repository: widget.repository,
      );
      if (!mounted) return;
      _title.clear();
      setState(() {
        _links = <LessonLink>[..._links, link];
        _open = link;
        _making = false;
        _asClass = false;
      });
    } on NothingSaidAboutAge {
      // The birth month question was closed. No link was made, and there is
      // nothing to say about it.
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.open', route: 'Lesson link'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setClass(LessonLink link, bool asClass) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await withBirthMonth(
        () => widget.repository.setLessonLinkClass(link.id, asClass: asClass),
        context: context,
        repository: widget.repository,
      );
      // Read back rather than guessed at: the room's name is the server's to
      // choose ("Jazz studio 2" beside a room already called that).
      await _load();
    } on NothingSaidAboutAge {
      // Nothing changed, and nothing is said about it.
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.class', route: 'Lesson link'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(LessonLink link) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Turn off ${link.title}?'),
        content: Text(
          'Nobody new can join with it, and the QR code stops opening anything. '
          'Students who already joined keep their rooms with you'
          '${link.isClass ? ', and the class room stays' : ''}.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep it')),
          FilledButton(
            key: const Key('lesson_close_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Turn it off'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.repository.closeLessonLink(link.id);
      if (!mounted) return;
      setState(() {
        _links = _links.where((each) => each.id != link.id).toList(growable: false);
        _open = null;
      });
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.close', route: 'Lesson link'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(LessonLink link) =>
      copyAndSay(context, lessonLink(link.code), 'Link copied. Paste it into an email or a text.');

  Future<void> _share(LessonLink link) async {
    final what = link.isClass
        ? 'open this to join the class on CoLabRoom, and get your own lesson room with me.'
        : 'open this to get your own lesson room with me on CoLabRoom.';
    await SharePlus.instance.share(ShareParams(
      subject: link.title,
      text: '${link.title}: $what\n${lessonLink(link.code)}',
    ));
  }

  Future<void> _poster(LessonLink link) async {
    try {
      await LessonPoster.print(
        title: link.title,
        code: link.code,
        teacher: widget.teacherName,
        className: link.classRoomName,
      );
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.poster', route: 'Lesson link'));
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Whether the screen is showing something other than the list, which
  /// back returns to before it leaves the screen.
  bool get _inside => _open != null || (_making && _links.isNotEmpty);

  void _backToList() => setState(() {
        _open = null;
        _making = false;
      });

  @override
  Widget build(BuildContext context) {
    final open = _open;
    final List<Widget> children;
    if (open != null) {
      children = _code(open);
    } else if (_links.isEmpty || _making) {
      children = _start();
    } else {
      children = _list();
    }
    return PopScope(
      canPop: !_inside,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToList();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: _inside ? BackButton(onPressed: _backToList) : null,
          title: const Text('Lesson links'),
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  key: const Key('lesson_link_list'),
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 32),
                  children: children,
                ),
        ),
      ),
    );
  }

  List<Widget> _start() {
    final first = _links.isEmpty;
    return <Widget>[
      Text(
        first ? 'One code for all your students' : 'Another link',
        style: const TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25),
      ),
      const SizedBox(height: 10),
      Text(
        first
            ? 'Put it on your wall, in an email or a text. Everybody who opens it '
                'gets their own room with you: just the two of you, with the song '
                'sheet, Follow me, and what you worked on last time.'
            : 'A second code, for another class or another day. Everybody who '
                'opens it gets their own room with you, named for this link.',
        style: const TextStyle(color: AppColors.muted, fontSize: 14, height: 1.45),
      ),
      if (first) ...<Widget>[
        const SizedBox(height: 12),
        // Said before the link exists, because it decides whether a teacher
        // wants one at all (Every Musician, Same Song, 17 September 2026:
        // adult students first, until there is a guardian step).
        const Text(
          lessonLinksAreForStudents18AndOver,
          key: Key('lesson_adults'),
          style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.45),
        ),
      ],
      const SizedBox(height: 22),
      TextField(
        key: const Key('lesson_title'),
        controller: _title,
        maxLength: 60,
        textCapitalization: TextCapitalization.sentences,
        style: const TextStyle(color: AppColors.text, fontSize: 15),
        decoration: InputDecoration(
          labelText: 'What you teach',
          hintText: first ? 'Guitar lessons' : 'Tuesday beginners',
          helperText: 'Each student\'s room is called this, with their name.',
          // Wraps rather than stopping at an ellipsis, which a helper does
          // by default and which cut this sentence off on a phone (audit,
          // 17 September 2026).
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => unawaited(_make()),
      ),
      const SizedBox(height: 6),
      _classSwitch(
        key: const Key('lesson_class_switch'),
        value: _asClass,
        onChanged: _busy ? null : (value) => setState(() => _asClass = value),
      ),
      const SizedBox(height: 14),
      FilledButton(
        key: const Key('lesson_make'),
        onPressed: _busy ? null : () => unawaited(_make()),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.ink,
        ),
        child: Text(first ? 'Make my lesson link' : 'Make the link'),
      ),
    ];
  }

  /// A class, or not. On a link that already is one the sentence names the
  /// room, so a teacher can see which room a poster opens into.
  Widget _classSwitch({
    required Key key,
    required bool value,
    required ValueChanged<bool>? onChanged,
    String? className,
  }) {
    return SwitchListTile(
      key: key,
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      title: const Text('A class', style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w700)),
      subtitle: Text(
        className != null
            ? 'Everybody who opens it lands in $className with the whole class, '
                'and in their own room with you.'
            : 'Everybody who opens it also lands in one room with the whole '
                'class, to listen. They still record in their own room with you.',
        style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
      ),
    );
  }

  List<Widget> _list() {
    return <Widget>[
      for (final link in _links) ...<Widget>[
        _LinkRow(link: link, onTap: () => setState(() => _open = link)),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 6),
      const Text(
        lessonLinksAreForStudents18AndOver,
        key: Key('lesson_adults'),
        style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 18),
      // Eight is the cap (0148). Said where the button would be, in the
      // server's words, rather than as a button that is refused when pressed.
      if (_links.length >= lessonLinksOpenAtOnce)
        const Text(
          lessonLinksAreCapped,
          key: Key('lesson_capped'),
          style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.45),
        )
      else
        OutlinedButton.icon(
          key: const Key('lesson_new'),
          onPressed: _busy ? null : () => setState(() => _making = true),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New link'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
    ];
  }

  List<Widget> _code(LessonLink link) {
    final address = lessonLink(link.code);
    return <Widget>[
      Text(
        link.title,
        key: const Key('lesson_link_title'),
        style: const TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25),
      ),
      const SizedBox(height: 4),
      Text(_joined(link), key: const Key('lesson_joined'), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      const SizedBox(height: 10),
      // And again beside the code itself, which is the thing being shared.
      const Text(
        lessonLinksAreForStudents18AndOver,
        key: Key('lesson_adults'),
        style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 18),
      Center(
        child: QrCode(
          key: const Key('lesson_qr'),
          data: address,
          size: 220,
          label: 'QR code that opens your lesson link',
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'Students scan it with their phone camera.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted, fontSize: 12.5),
      ),
      const SizedBox(height: 18),
      Text(
        'Or they type the code in CoLabRoom, under Join with a code:',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
      ),
      const SizedBox(height: 4),
      SelectableText(
        lessonCodeSaid(link.code),
        key: const Key('lesson_code'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.gold,
          fontSize: 24,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
      const SizedBox(height: 22),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: <Widget>[
          FilledButton.icon(
            key: const Key('lesson_share'),
            onPressed: () => unawaited(_share(link)),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('Share the link'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: AppColors.ink),
          ),
          OutlinedButton.icon(
            key: const Key('lesson_copy'),
            onPressed: () => unawaited(_copy(link)),
            icon: const Icon(Icons.link_rounded, size: 18),
            label: const Text('Copy link'),
          ),
          // For the wall: the same code, on a page big enough to scan from
          // across a room.
          OutlinedButton.icon(
            key: const Key('lesson_poster'),
            onPressed: () => unawaited(_poster(link)),
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Print a poster'),
          ),
        ],
      ),
      const SizedBox(height: 10),
      SelectableText(
        address,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
      ),
      const SizedBox(height: 22),
      _classSwitch(
        key: const Key('lesson_class'),
        value: link.isClass,
        className: link.classRoomName,
        onChanged: _busy ? null : (value) => unawaited(_setClass(link, value)),
      ),
      const SizedBox(height: 18),
      Center(
        child: TextButton(
          key: const Key('lesson_close'),
          onPressed: _busy ? null : () => unawaited(_close(link)),
          child: const Text('Turn this link off', style: TextStyle(color: AppColors.muted)),
        ),
      ),
    ];
  }

  /// Whether the poster has worked yet, and nothing more: no number (Every
  /// Musician, Same Song, 17 September 2026: no counts anywhere). A teacher
  /// who wants the names has them, as rooms, under Your music.
  static String _joined(LessonLink link) =>
      link.students == 0 ? 'Nobody has joined yet' : 'Students have joined';
}

/// One link in the list: its name, and whether it is a class. Tapping it
/// opens the code.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.link, required this.onTap});

  final LessonLink link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.raised,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        key: Key('lesson_link_row_${link.code}'),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: const Icon(Icons.qr_code_2_rounded, color: AppColors.gold),
        title: Text(
          link.title,
          style: const TextStyle(color: AppColors.text, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        subtitle: link.isClass
            ? const Text('Class', style: TextStyle(color: AppColors.muted, fontSize: 13))
            : null,
        trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ),
    );
  }
}
