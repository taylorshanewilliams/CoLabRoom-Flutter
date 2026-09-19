import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/calls.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/openmic/ask_somebody_not_here.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/features/rooms/setlist_pack.dart';
import 'package:colabroom/features/workspace/chord_sheet_export.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/services/project_export_service.dart';
import 'package:colabroom/services/share_origin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sharing works from an iPad.
///
/// An iPad shows the system share sheet as a popover, and a popover has to
/// hang off a rectangle in the window -- the control that was tapped.
/// share_plus carries that as `ShareParams.sharePositionOrigin`, and not one
/// of the app's seven share calls passed one: every share in the app opened
/// in the middle of the screen pointing at nothing, whatever had been
/// pressed.
///
/// None of this can be *proved* here. Nobody on the project has an iPad, no
/// simulator runs on this machine, and the behaviour being fixed lives in
/// UIKit. What these tests hold is the part that is ours: that a rectangle is
/// worked out from the control somebody actually touched, that it is never
/// empty, and that every share call in the app carries one.
///
/// The device check is a person with an iPad: share a lesson link, a set, a
/// chart and a cut, and see the sheet arrive out of the button each time
/// rather than out of the middle of the screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('where the share sheet points', () {
    testWidgets('a control on screen reports its own rectangle',
        (tester) async {
      late BuildContext button;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(builder: (context) {
              button = context;
              return ElevatedButton(
                key: const Key('the_button'),
                onPressed: () {},
                child: const Text('Send it'),
              );
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final origin = shareOrigin(button);
      expect(origin.isEmpty, isFalse);
      expect(origin, tester.getRect(find.byKey(const Key('the_button'))));
      // In the window's coordinates, which is what the iOS side converts
      // from. A local rectangle would sit at the origin.
      expect(origin.top, greaterThan(0));
    });

    testWidgets('a control that was never laid out falls back to the middle',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

      final origin = shareOriginOf(GlobalKey());
      expect(origin.isEmpty, isFalse);
      expect(origin.center, _middleOf(tester));
    });

    testWidgets('and so does one whose screen has gone', (tester) async {
      late BuildContext left;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          left = context;
          return const SizedBox();
        }),
      ));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

      final origin = shareOrigin(left);
      expect(origin.isEmpty, isFalse);
      expect(origin.center, _middleOf(tester));
    });

    test('with no context at all there is still something to point at', () {
      // A service called off a menu that has already closed, say. An empty
      // rectangle is the one answer UIKit cannot use.
      expect(shareOrigin(null).isEmpty, isFalse);
    });
  });

  group('every share says where it was asked for', () {
    // Read off the source, like button_labels_keep_their_font_test does, and
    // for the same reason: the seven call sites all compiled, passed their
    // tests and worked on every phone. Nothing at runtime is wrong until the
    // app is opened on an iPad, and there is no widget assertion for a
    // parameter nobody passed. Reading the file is cruder and actually
    // checks it.
    test('no SharePlus call leaves the origin out', () {
      final offenders = <String>[];
      var calls = 0;

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        for (final args
            in _argumentsOf('SharePlus.instance.share(', entity.readAsStringSync())) {
          calls += 1;
          if (!args.contains('sharePositionOrigin:')) offenders.add(path);
        }
      }

      // The seven the audit found. A new one is welcome; a new one without an
      // origin is not.
      expect(calls, greaterThanOrEqualTo(7));
      expect(
        offenders,
        isEmpty,
        reason: 'These share without saying where from, so on an iPad the '
            'sheet points at nothing. Pass sharePositionOrigin -- '
            'shareOrigin(context) for a control, or a Rect handed down by '
            'the caller where the code has no context:\n  '
            '${offenders.join('\n  ')}',
      );
    });
  });

  group('the rectangle reaches the share sheet', () {
    test('a song shared from the workspace', () async {
      final shares = _recordShares();
      await ProjectExportService.shareSong(_song(), origin: _somewhere);
      expect(shares.lastOrigin, _somewhere);
    });

    test('a set shared as text', () async {
      final shares = _recordShares();
      await SetlistPack.shareText(
        _setlist(),
        const <SetlistPackSong>[],
        origin: _somewhere,
      );
      expect(shares.lastOrigin, _somewhere);
    });

    test('a chart sent as a ChordPro file', () async {
      // The file is built in memory and share_plus writes it to a temporary
      // directory before handing it over, which is the one share in the app
      // that touches the disk on its way out.
      _useATemporaryDirectory();
      final shares = _recordShares();
      await ChordSheetExport.shareChordPro(
        project: _song(),
        lines: const <MusicianSheetLine>[],
        transpose: 0,
        origin: _somewhere,
      );
      expect(shares.lastOrigin, _somewhere);
    });
  });

  group('and it is the control that was tapped', () {
    testWidgets('the lesson link', (tester) async {
      final shares = _recordShares();
      final repository = InMemoryMusicRepository.seeded()
        ..callStanding = CallStanding.adult;
      await _pump(tester, repository,
          LessonLinkScreen(repository: repository), const Size(390, 1100));

      await tester.enterText(
          find.byKey(const Key('lesson_title')), 'Guitar lessons');
      await tester.tap(find.byKey(const Key('lesson_make')));
      await tester.pumpAndSettle();

      final button = find.byKey(const Key('lesson_share'));
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(shares.lastOrigin, tester.getRect(button));
      expect(shares.lastOrigin!.isEmpty, isFalse);
    });

    testWidgets('the ask to somebody who is not here', (tester) async {
      final shares = _recordShares();
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: AskSomebodyNotHere(
            repository: InMemoryMusicRepository.seeded(),
            myName: 'Taylor',
            about: 'bass',
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      await tester.enterText(find.byType(TextField), 'sam@example.com');
      await tester.tap(find.text('Write the message'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      final button = find.widgetWithText(FilledButton, 'Send it');
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(shares.lastOrigin, tester.getRect(button));
      expect(shares.lastOrigin!.isEmpty, isFalse);
    });

    testWidgets('and a set, which shares from the menu it was chosen in',
        (tester) async {
      // The options menu rather than a button of its own: the menu is still
      // on screen when the choice comes back, which is why it can be the
      // anchor at all. An empty set, so that the share is the only thing
      // this has to get through.
      final shares = _recordShares();
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final set = await controller.createSetlist('Friday practice');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SetlistDetailScreen(setlistId: set.id),
        ),
      ));
      await tester.pumpAndSettle();

      final menu = find.byTooltip('Setlist options');
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share by text or email'));
      await tester.pumpAndSettle();

      // The whole tap target, which is a few pixels around the icon the
      // tooltip is measured on. What matters is that it is that control up
      // in the app bar and not the screen.
      final icon = tester.getRect(menu);
      final origin = shares.lastOrigin!;
      expect(origin.isEmpty, isFalse);
      expect(origin.expandToInclude(icon), origin);
      expect(origin.width, lessThan(56));
    });
  });
}

/// A rectangle with nothing special about it, to follow from one end to the
/// other.
const Rect _somewhere = Rect.fromLTWH(12, 34, 56, 78);

Offset _middleOf(WidgetTester tester) {
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Offset(screen.width / 2, screen.height / 2);
}

Future<void> _pump(
  WidgetTester tester,
  InMemoryMusicRepository repository,
  Widget home,
  Size size,
) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: home),
  ));
  await tester.pumpAndSettle();
}

DateTime get _when => DateTime.utc(2026, 9, 19);

SongProject _song() => SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'account-1',
      title: 'Midnight Signal',
      createdAt: _when,
      updatedAt: _when,
    );

Setlist _setlist() => Setlist(
      id: 'set-1',
      ownerId: 'account-1',
      name: 'Friday practice',
      createdAt: _when,
      updatedAt: _when,
    );

/// The share sheet, written down instead of shown.
class _Shares {
  final List<Map<Object?, Object?>> calls = <Map<Object?, Object?>>[];

  /// The rectangle the last share handed the platform, or null where it
  /// handed over none -- which is the bug this file is about.
  Rect? get lastOrigin {
    if (calls.isEmpty) return null;
    final arguments = calls.last;
    final left = arguments['originX'] as double?;
    final top = arguments['originY'] as double?;
    final width = arguments['originWidth'] as double?;
    final height = arguments['originHeight'] as double?;
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    return Rect.fromLTWH(left, top, width, height);
  }
}

const MethodChannel _shareChannel =
    MethodChannel('dev.fluttercommunity.plus/share');

_Shares _recordShares() {
  final shares = _Shares();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_shareChannel, (MethodCall call) async {
    shares.calls.add(call.arguments as Map<Object?, Object?>);
    return '';
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_shareChannel, null));
  return shares;
}

const MethodChannel _pathProvider =
    MethodChannel('plugins.flutter.io/path_provider');

void _useATemporaryDirectory() {
  final directory = Directory.systemTemp.createTempSync('colabroom_share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      _pathProvider, (MethodCall call) async => directory.path);
  addTearDown(() {
    messenger.setMockMethodCallHandler(_pathProvider, null);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
}

/// The argument text of every `needle` call in [source], with `//` comments
/// taken out first so that prose about this rule does not read as an
/// obedient call site.
///
/// Parenthesis matching, skipping string literals so a bracket inside a
/// message does not end the call early.
Iterable<String> _argumentsOf(String needle, String source) sync* {
  final text = _withoutLineComments(source);
  var at = text.indexOf(needle);
  while (at != -1) {
    final open = at + needle.length;
    var depth = 1;
    var i = open;
    String? quote;
    while (i < text.length && depth > 0) {
      final ch = text[i];
      if (quote != null) {
        if (ch == r'\') {
          i += 2;
          continue;
        }
        if (ch == quote) quote = null;
      } else if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '(') {
        depth += 1;
      } else if (ch == ')') {
        depth -= 1;
      }
      i += 1;
    }
    yield text.substring(open, i);
    at = text.indexOf(needle, i);
  }
}

String _withoutLineComments(String source) {
  final out = StringBuffer();
  for (final line in source.split('\n')) {
    out.writeln(_stripLineComment(line));
  }
  return out.toString();
}

String _stripLineComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i += 1) {
    final ch = line[i];
    if (quote != null) {
      if (ch == r'\') {
        i += 1;
        continue;
      }
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      continue;
    }
    if (ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}
