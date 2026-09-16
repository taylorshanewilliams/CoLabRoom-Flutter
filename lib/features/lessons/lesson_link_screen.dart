import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/lesson_link.dart';
import '../../services/invite_link.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/qr_code.dart';
import 'lesson_poster.dart';

/// A teacher's lesson link: one QR code, and a room of their own with the
/// teacher for every student who opens it.
///
/// Taylor, 16 September 2026: "a way for teachers to start learning rooms
/// ... they can email out or share a qr code or whatever, and the student
/// could join right into their room." One code on the studio wall, in a
/// newsletter, in a text -- and no student ever lands in a room with
/// another student's takes, because each of them gets their own.
///
/// The screen is the code. Before there is one it asks a single question,
/// what you teach, because that is what every student's room will be called.
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
  LessonLink? _link;
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
      final link = await widget.repository.myLessonLink();
      if (!mounted) return;
      setState(() {
        _link = link;
        _loading = false;
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
      final link = await widget.repository.openLessonLink(_title.text);
      if (mounted) setState(() => _link = link);
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.open', route: 'Lesson link'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off your lesson link?'),
        content: const Text(
          'Nobody new can join with it, and the QR code stops opening anything. '
          'Students who already joined keep their rooms with you.',
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
      await widget.repository.closeLessonLink();
      if (mounted) setState(() => _link = null);
    } catch (error) {
      _say(reportAndDescribe(error, service: 'app', stage: 'lesson_link.close', route: 'Lesson link'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(LessonLink link) async {
    await Clipboard.setData(ClipboardData(text: lessonLink(link.code)));
    _say('Link copied. Paste it into an email or a text.');
  }

  Future<void> _share(LessonLink link) async {
    await SharePlus.instance.share(ShareParams(
      subject: link.title,
      text: '${link.title}: open this to get your own lesson room with me on CoLabRoom.\n'
          '${lessonLink(link.code)}',
    ));
  }

  Future<void> _poster(LessonLink link) async {
    try {
      await LessonPoster.print(title: link.title, code: link.code, teacher: widget.teacherName);
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

  @override
  Widget build(BuildContext context) {
    final link = _link;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Lesson link'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: const Key('lesson_link_list'),
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 32),
                children: link == null ? _start() : _code(link),
              ),
      ),
    );
  }

  List<Widget> _start() => <Widget>[
        const Text(
          'One code for all your students',
          style: TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25),
        ),
        const SizedBox(height: 10),
        const Text(
          'Put it on your wall, in an email or a text. Everybody who opens it '
          'gets their own room with you: just the two of you, with the song '
          'sheet, Follow me, and what you worked on last time.',
          style: TextStyle(color: AppColors.muted, fontSize: 14, height: 1.45),
        ),
        const SizedBox(height: 22),
        TextField(
          key: const Key('lesson_title'),
          controller: _title,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: AppColors.text, fontSize: 15),
          decoration: const InputDecoration(
            labelText: 'What you teach',
            hintText: 'Guitar lessons',
            helperText: 'Each student\'s room is called this, with their name.',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => unawaited(_make()),
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
          child: const Text('Make my lesson link'),
        ),
      ];

  List<Widget> _code(LessonLink link) {
    final address = lessonLink(link.code);
    final joined = switch (link.students) {
      0 => 'Nobody has joined yet',
      1 => '1 student has joined',
      _ => '${link.students} students have joined',
    };
    return <Widget>[
      Text(
        link.title,
        key: const Key('lesson_link_title'),
        style: const TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25),
      ),
      const SizedBox(height: 4),
      Text(joined, key: const Key('lesson_joined'), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      const SizedBox(height: 22),
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
      const SizedBox(height: 28),
      Center(
        child: TextButton(
          key: const Key('lesson_close'),
          onPressed: _busy ? null : () => unawaited(_close()),
          child: const Text('Turn this link off', style: TextStyle(color: AppColors.muted)),
        ),
      ),
    ];
  }
}
