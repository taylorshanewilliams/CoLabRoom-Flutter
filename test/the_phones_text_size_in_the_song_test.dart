import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/moment_note.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/moment_notes.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/lessons/lesson_link_screen.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/features/workspace/tuner_sheet.dart';
import 'package:colabroom/services/click_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The text is the size your phone says it is, inside a song.
///
/// Every Musician, Same Song, 17 September 2026: the phone's own text size is
/// honoured, never clamped. The slice before this one took the 0.8-1.3 clamp
/// off ColabRoomApp and left one behind, on the song workspace, because that
/// is where people spend most of their time and its header overflowed at
/// twice normal. This file is the other half: everything a song opens into,
/// at the size a partially sighted musician actually reads at.
///
/// Overflow is an exception in a widget test, so `takeException` catches the
/// yellow stripes as well as the crashes. The rule being asserted is the one
/// the render harness states: text wraps or the screen scrolls, nothing is cut
/// off and nothing is shrunk to fit.
///
/// 2.0 rather than some number nobody can name: it is roughly the middle of
/// iOS's accessibility sizes, which reach Flutter as 1.64, 1.94, 2.35, 2.76
/// and 3.12.
/// Everything Flutter complained about since the last boot, in full — the
/// one-line summary alone costs an investigation to locate.
final List<FlutterErrorDetails> _complaints = <FlutterErrorDetails>[];

String _why(String what) {
  if (_complaints.isEmpty) return '$what did not draw';
  final first = _complaints.first.toString();
  final detail = first.length > 2600 ? first.substring(0, 2600) : first;
  return '''$what did not draw:

$detail''';
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

/// A phone with its text set to [textScale], and every complaint recorded.
///
/// Both settings go on the view and the dispatcher rather than into a
/// MediaQuery wrapped around whatever is pumped: MaterialApp builds its own
/// MediaQuery from the test window, so anything wrapped outside is discarded
/// and every "large text" case would silently run at 1.0.
void _phone(
  WidgetTester tester, {
  required double textScale,
  Size size = const Size(390, 844),
}) {
  _complaints.clear();
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _complaints.add(details);
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _bootScreen(
  WidgetTester tester,
  Widget screen, {
  required double textScale,
  MusicBetaController? controller,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  _phone(tester, textScale: textScale);
  final app = MaterialApp(theme: CoLabRoomTheme.dark(), home: screen);
  await tester.pumpWidget(
    controller == null ? app : BetaScope(controller: controller, child: app),
  );
  await _frames(tester);
}

/// Takes the tree down, so screens that started a player or a poll are
/// disposed before the test ends rather than leaving a timer behind.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _frames(tester);
}

Future<bool> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return false;
  await tester.ensureVisible(finder.last);
  await _frames(tester);
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// Nothing on screen is drawing words into a box too small for them.
///
/// Overflow — the yellow stripes — is an exception, so `takeException` sees
/// it. Text in a fixed-size box is not: RenderParagraph paints the lines that
/// fit and drops the rest, silently, which is how a label can lose the bottom
/// third of its letters while every test in this file and the whole render
/// harness stay green. The rule this slice asserts is "nothing is clipped", so
/// it is measured rather than inferred from the absence of a complaint.
///
/// Each paragraph is laid out again with its own spans, scaler, maxLines and
/// wrapping, at the width it was given, and compared with the box it was drawn
/// into. A paragraph that asked for an ellipsis or a fade has chosen to
/// shorten itself and says so on screen, so it is left alone; one that did
/// not, and does not fit, is cut off.
void _noTextIsClipped(WidgetTester tester, String where) {
  final cut = <String>[];
  for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (!paragraph.hasSize) continue;
    final words = paragraph.text.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: false,
    );
    if (words.trim().isEmpty) continue;
    // An icon is a RichText too, drawn in a private-use glyph nobody reads.
    if (words.runes.every((rune) => rune >= 0xE000 && rune <= 0xF8FF)) continue;
    if (paragraph.overflow == TextOverflow.ellipsis ||
        paragraph.overflow == TextOverflow.fade) {
      continue;
    }
    final painter = TextPainter(
      text: paragraph.text,
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      maxLines: paragraph.maxLines,
      strutStyle: paragraph.strutStyle,
      textWidthBasis: paragraph.textWidthBasis,
      textHeightBehavior: paragraph.textHeightBehavior,
      locale: paragraph.locale,
    )..layout(
        maxWidth: paragraph.softWrap ? paragraph.size.width : double.infinity,
      );
    final needsHigh = painter.height;
    final needsWide = painter.width;
    painter.dispose();
    if (needsHigh > paragraph.size.height + 0.5 ||
        needsWide > paragraph.size.width + 0.5) {
      cut.add('  "$words" is drawn in a box '
          '${paragraph.size.width.toStringAsFixed(1)} by '
          '${paragraph.size.height.toStringAsFixed(1)} and needs '
          '${needsWide.toStringAsFixed(1)} by '
          '${needsHigh.toStringAsFixed(1)}');
    }
  }
  expect(cut, isEmpty,
      reason: 'words are cut off on $where:\n${cut.join('\n')}');
}

/// Pops whatever sheet or dialog is open, if one is.
Future<void> _dismiss(WidgetTester tester) async {
  if (find.byType(Navigator).evaluate().isEmpty) return;
  final state = tester.state<NavigatorState>(find.byType(Navigator).last);
  if (!state.canPop()) return;
  state.pop();
  await _frames(tester);
}

// ------------------------------------------------------------------ a song
//
// A long line with a chord on every word, which is the shape Perform is
// hardest at: the chord names are wider than the words they sit over, and
// there are enough of them to run off several screens.

const String _longLine =
    'Turning in the wind again and waiting for the morning light to come';

const List<String> _chordNames = <String>[
  'G:maj',
  'D/F#',
  'Am7',
  'Cmaj7',
  'Bbdim',
];

SongProject _project(String id) {
  final now = DateTime(2026, 9, 17);
  return SongProject(
    id: id,
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane In The Rain',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: id,
        authorId: 'user-1',
        authorName: 'Taylor',
        body: _longLine,
        colorValue: 0xFFFF8A4C,
        createdAt: now,
        position: 1,
      ),
    ],
  );
}

SongAnalysisBundle _analysis(String id) {
  final words = _longLine.split(' ');
  return SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: id,
      fileId: 'file',
      storagePath: 'room/$id/reference.m4a',
      displayName: 'Weathervane.m4a',
      state: SongAnalysisState.ready,
      durationMs: 40000,
      musicalKey: 'G',
      transcriptText: _longLine,
      transcriptWords: <TranscriptWord>[
        for (var i = 0; i < words.length; i += 1)
          TranscriptWord(
            word: words[i],
            startMs: 5000 + i * 400,
            endMs: 5000 + i * 400 + 350,
          ),
      ],
      // A real beat grid, so the bar picker, the loop and the count-in all
      // have bars to count.
      bpm: 150,
      beatsPerBar: 4,
      downbeatsMs: <int>[for (var i = 0; i < 24; i += 1) i * 1600],
    ),
    lyricCues: const <LyricSyncCue>[],
    chordCues: <ChordCue>[
      for (var i = 0; i < words.length; i += 1)
        ChordCue(
          id: i + 1,
          startMs: 5000 + i * 400,
          endMs: 5000 + i * 400 + 350,
          chord: _chordNames[i % _chordNames.length],
          confidence: 0.9,
        ),
    ],
  );
}

/// One note, as the microphone would hand it over: a sine wave at [hz], and
/// then the same thing as the 16-bit samples the ear reads.
Float64List _tone(double hz, {int samples = 4096, int rate = 44100}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i += 1) {
    out[i] = math.sin(2 * math.pi * hz * i / rate) * 0.4;
  }
  return out;
}

Uint8List _pcm16(Float64List floats) {
  final bytes = ByteData(floats.length * 2);
  for (var i = 0; i < floats.length; i += 1) {
    bytes.setInt16(
        i * 2, (floats[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// A count-in that makes no sound, because there is no audio here.
class _SilentClick implements ClickPlayer {
  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
    List<int> accents = const <int>[],
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('a long chord line in Perform wraps rather than overflowing',
      (tester) async {
    // The hard one. Every word carries a chord, and a chord name is wider
    // than most words — so at twice normal the row is several screens wide
    // if nothing folds it.
    await _bootScreen(
      tester,
      LivePerformanceScreen(
        project: _project('live-2x'),
        analysis: _analysis('live-2x'),
      ),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull, reason: _why('Perform'));
    _noTextIsClipped(tester, 'Perform');

    // And the words themselves are still there: a line that "fits" because
    // every word after the third was dropped is not a line that wrapped.
    expect(find.text('Turning'), findsOneWidget);
    expect(find.text('come'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('a chord in Perform sits above its word, not on it',
      (tester) async {
    // Not an overflow test — that one passes either way, which is the whole
    // problem. The row a chord is drawn in was a fixed 16.5 pixels times this
    // person's own sheet zoom, and the reader's phone scales the chord name
    // on top of that. So the box stayed put while the name inside it grew,
    // and at twice normal the chord was painted down over the word it belongs
    // to. A chord sheet whose chords sit on the wrong syllable is worse than
    // one with no chords at all.
    await _bootScreen(
      tester,
      LivePerformanceScreen(
        project: _project('live-align'),
        analysis: _analysis('live-align'),
      ),
      textScale: 2.0,
    );

    final chord = find.text('G');
    final word = find.text('Turning');
    expect(chord, findsWidgets, reason: 'the first chord is not on screen');
    expect(word, findsOneWidget, reason: 'the first word is not on screen');

    final chordBox = tester.getRect(chord.first);
    final wordBox = tester.getRect(word.first);
    expect(
      chordBox.bottom,
      lessThanOrEqualTo(wordBox.top),
      reason: 'the chord is drawn at $chordBox and the word it belongs to at '
          '$wordBox — the chord row is not as tall as the chord',
    );
    final large = chordBox.height;
    await _close(tester);

    // And it grew with the text rather than being squashed back into the old
    // box, which is what "nothing is shrunk to fit" means here.
    await _bootScreen(
      tester,
      LivePerformanceScreen(
        project: _project('live-align'),
        analysis: _analysis('live-align'),
      ),
      textScale: 1.0,
    );
    final small = tester.getRect(find.text('G').first).height;
    expect(
      large,
      greaterThan(small * 1.6),
      reason: 'the chord was $small tall at 1x and $large at 2x — it is being '
          'scaled back down to fit',
    );
    await _close(tester);
  });

  testWidgets('Perform holds its panels at the largest text size',
      (tester) async {
    await _bootScreen(
      tester,
      LivePerformanceScreen(
        project: _project('live-panels'),
        analysis: _analysis('live-panels'),
      ),
      textScale: 2.0,
    );

    // The controls a player reaches for on stage: the words-or-sheet menu,
    // the count-in settings, the bar picker and the practice row.
    for (final key in <String>[
      'live_toggle_chords',
      'live_source_menu',
      'live_countdown_settings',
      'live_loop_bars',
      'live_practice_row',
    ]) {
      expect(await _tapKey(tester, key), isTrue, reason: '$key is gone');
      expect(tester.takeException(), isNull, reason: _why(key));
      _noTextIsClipped(tester, key);
      await _dismiss(tester);
      expect(tester.takeException(), isNull, reason: _why('closing $key'));
    }
    await _close(tester);
  });

  for (final phone in const <String, Size>{
    'upright': Size(390, 844),
    'on its side': Size(844, 390),
  }.entries) {
    testWidgets('the count-in holds at the largest text size, ${phone.key}',
        (tester) async {
      // A number drawn at 118 pixels over the whole screen, with a row of
      // dots and a line of words under it. On its side, which is how Perform
      // is held on a stand, that number and the two rows under it are taller
      // than the phone once the text is turned up.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'live_countdown_enabled': true,
        'live_countdown_seconds': 5,
      });
      _phone(tester, textScale: 3.12, size: phone.value);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: _project('count-in'),
          analysis: _analysis('count-in'),
          click: _SilentClick(),
        ),
      ));
      await _frames(tester);

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      expect(find.byKey(const Key('live_count_in')), findsOneWidget,
          reason: 'pressing play did not count the band in');
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull, reason: _why('the count-in'));
      await _close(tester);
    });
  }

  testWidgets('the song sheet and its panels hold at the largest text size',
      (tester) async {
    // In a scroll view, which is where the workspace puts it: the sheet is a
    // page, not a screen, and it is taller than a phone at any text size.
    await _bootScreen(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('sheet-2x'),
            bundle: _analysis('sheet-2x'),
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull, reason: _why('the song sheet'));
    _noTextIsClipped(tester, 'the song sheet');

    // The key badge opens the key sheet, which is also where the readings
    // live — numbers, a horn's part, a capo, sargam. "Read as" opens the same
    // choice from the toolbar, and Edit chords changes the whole sheet's
    // shape.
    for (final key in <String>[
      'song_sheet_key_badge',
      'song_sheet_read_as',
      'toggle_chord_editing',
    ]) {
      expect(await _tapKey(tester, key), isTrue, reason: '$key is gone');
      expect(tester.takeException(), isNull, reason: _why(key));
      _noTextIsClipped(tester, key);
      await _dismiss(tester);
    }

    // And a chord, which opens the reference sheet with the shapes on it.
    final chord = find.byKey(const Key('edit_chord_1'));
    expect(chord, findsOneWidget, reason: 'no chord on the sheet to tap');
    await tester.ensureVisible(chord);
    await _frames(tester);
    await tester.tap(chord, warnIfMissed: false);
    await _frames(tester);
    expect(tester.takeException(), isNull, reason: _why('a chord reference'));
    _noTextIsClipped(tester, 'a chord reference');
    await _close(tester);
  });

  // The three screens a song is read from, on the two shapes of phone the
  // rest of this file does not use, at the largest text iOS can ask for.
  //
  // 3.12 rather than 2.0 because iOS's five accessibility sizes reach Flutter
  // as 1.64, 1.94, 2.35, 2.76 and 3.12, and the last of them is a real
  // setting a real person uses. On its side because that is how Perform is
  // held on a music stand, and small because 360 wide is the narrowest phone
  // still in use. Each of the three found something the 390-wide portrait
  // cases did not.
  for (final phone in const <String, Size>{
    'a small phone': Size(360, 690),
    'a phone on its side': Size(844, 390),
  }.entries) {
    testWidgets('the song holds at the largest iOS text size on ${phone.key}',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      _phone(tester, textScale: 3.12, size: phone.value);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: _project('largest'),
          analysis: _analysis('largest'),
        ),
      ));
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: _why('Perform'));
      _noTextIsClipped(tester, 'Perform at 3.12');
      await _close(tester);

      _phone(tester, textScale: 3.12, size: phone.value);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SongSheetPanel(
              project: _project('largest'),
              bundle: _analysis('largest'),
              onReviewLyrics: null,
              onOpenLive: null,
            ),
          ),
        ),
      ));
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: _why('the song sheet'));
      _noTextIsClipped(tester, 'the song sheet at 3.12');
      await _close(tester);

      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final room = controller.rooms.first;
      _phone(tester, textScale: 3.12, size: phone.value);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: SongLayersScreen(
            roomId: room.id,
            projectId: room.projects.first.id,
            songTitle: room.projects.first.title,
          ),
        ),
      ));
      await _frames(tester);
      expect(tester.takeException(), isNull, reason: _why('Takes'));
      _noTextIsClipped(tester, 'Takes at 3.12');
      await _close(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  testWidgets('Takes holds at the largest text size', (tester) async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    final room = controller.rooms.first;
    await _bootScreen(
      tester,
      SongLayersScreen(
        roomId: room.id,
        projectId: room.projects.first.id,
        songTitle: room.projects.first.title,
      ),
      textScale: 2.0,
      controller: controller,
    );
    expect(tester.takeException(), isNull, reason: _why('Takes'));
    _noTextIsClipped(tester, 'Takes');
    await _close(tester);
  });

  testWidgets('a set holds at the largest text size', (tester) async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    final set = await controller.createSetlist('Friday practice at the hall');
    await controller.addProjectsToSetlist(
      set,
      <String>[
        for (final project in controller.rooms.first.projects) project.id,
      ],
    );
    await _bootScreen(
      tester,
      SetlistDetailScreen(setlistId: set.id),
      textScale: 2.0,
      controller: controller,
    );
    expect(tester.takeException(), isNull, reason: _why('a set'));
    _noTextIsClipped(tester, 'a set');
    await _close(tester);
  });

  testWidgets('the Open Mic song page holds at the largest text size',
      (tester) async {
    // Somebody else's song, which is the version most people see and the one
    // carrying the ask: what it wants, who has offered, and the way to answer.
    final repository = InMemoryMusicRepository.seeded();
    final feed = await repository.openMicFeed();
    expect(feed, isNotEmpty, reason: 'the preview has no Open Mic songs');
    await _bootScreen(
      tester,
      OpenMicSongScreen(projectId: feed.first.id, repository: repository),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull, reason: _why('an Open Mic song'));
    _noTextIsClipped(tester, 'an Open Mic song');
    expect(find.text('Offer to play on this'), findsOneWidget,
        reason: 'the ask card had no way to answer it');
    await _close(tester);
  });

  testWidgets('the notes on a moment hold at the largest text size',
      (tester) async {
    final now = DateTime(2026, 9, 17);
    await _bootScreen(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: MomentNoteList(
            currentUserId: 'me',
            labelFor: (note) => 'Second take, the one with the bridge',
            notes: <MomentNote>[
              MomentNote(
                id: 'n1',
                projectId: 'p',
                layerId: 'l',
                atMs: 93000,
                body: 'The change into the chorus is early here — come in on '
                    'the second beat and let the guitar finish its phrase.',
                authorId: 'me',
                authorName: 'Taylor Shane Williams',
                createdAt: now,
              ),
              MomentNote(
                id: 'n2',
                projectId: 'p',
                layerId: 'l',
                atMs: 121000,
                body: 'Nice.',
                authorId: 'other',
                authorName: 'Mara Delacroix-Fontaine',
                createdAt: now,
              ),
            ],
            onOpen: (_) {},
            onDelete: (_) {},
            onListen: (_) {},
            onCopyLink: (_) {},
          ),
        ),
      ),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull, reason: _why('the moment notes'));
    _noTextIsClipped(tester, 'the moment notes');
    await _close(tester);
  });

  testWidgets('the lesson link screen holds at the largest text size',
      (tester) async {
    await _bootScreen(
      tester,
      LessonLinkScreen(repository: InMemoryMusicRepository.seeded()),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull, reason: _why('the lesson link'));
    _noTextIsClipped(tester, 'the lesson link');
    await _close(tester);
  });

  testWidgets('the tuner holds at the largest text size', (tester) async {
    // Including the sentence it asks before the microphone turns on, which is
    // four paragraphs in a dialog and is the one screen in the app where
    // being able to read all of it is the entire point.
    await _bootScreen(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => TunerSheet.show(context),
            child: const Text('Tuner'),
          ),
        ),
      ),
      textScale: 2.0,
    );
    await tester.tap(find.text('Tuner'));
    await _frames(tester);
    expect(tester.takeException(), isNull, reason: _why('the tuner'));
    _noTextIsClipped(tester, 'the microphone sentence');
    await _close(tester);
  });

  testWidgets('the tuner holds with a note on it at the largest text size',
      (tester) async {
    // The dialog above is only the way in. What a player actually stands in
    // front of is this: one enormous note, a needle, and the reference row
    // under it. Fed a real A so the note is drawn rather than the ear icon.
    // A fresh stream each time: a tuner listens once, and a stream that has
    // already been listened to hands the second sheet nothing.
    Future<double> noteHeightAt(double textScale) async {
      final strings = StreamController<Uint8List>();
      addTearDown(strings.close);
      await _bootScreen(
        tester,
        Scaffold(body: TunerSheet(openStream: () async => strings.stream)),
        textScale: textScale,
      );
      // Three frames, so the median has something to be the median of.
      for (var frame = 0; frame < 3; frame += 1) {
        strings.add(_pcm16(_tone(440)));
        await tester.pump();
      }
      await _frames(tester);
      expect(find.byKey(const Key('tuner_note')), findsOneWidget,
          reason: 'the tuner heard an A at $textScale and drew nothing');
      expect(tester.takeException(), isNull, reason: _why('the tuner'));
      _noTextIsClipped(tester, 'the tuner with a note on it at $textScale');
      final high = tester.getRect(find.byKey(const Key('tuner_note'))).height;
      await _close(tester);
      return high;
    }

    final large = await noteHeightAt(2.0);
    // And the note grew with the reader's text size rather than staying at
    // the 78 pixels it was drawn at: it was a RichText, which ignores the
    // phone's setting outright.
    final small = await noteHeightAt(1.0);
    expect(large, greaterThan(small * 1.6),
        reason: 'the note was $small tall at 1x and $large at 2x');
  });

  testWidgets('the song workspace and its toolbar hold at the largest sizes',
      (tester) async {
    // The band of pills under the song's name is the only way into Perform
    // and Takes, and its labels sat in a box of exactly 24 pixels. Nothing
    // ever complained: a fixed box clips rather than overflows.
    for (final scale in <double>[2.0, 3.12]) {
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      final song = await controller.createSong(
        controller.rooms.first,
        'Weathervane In The Rain',
      );
      await controller.load();
      await controller.repository.addContribution(
        project: controller.projectById(song.id)!,
        body: _longLine,
      );
      await controller.load();
      await _bootScreen(
        tester,
        SongWorkspaceScreen(projectId: song.id),
        textScale: scale,
        controller: controller,
      );
      expect(tester.takeException(), isNull, reason: _why('the workspace'));
      _noTextIsClipped(tester, 'the song workspace at $scale');
      expect(find.byKey(const Key('workspace_live_button')), findsOneWidget,
          reason: 'the way into Perform is gone at $scale');
      await _close(tester);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the words scroll at the same lines a minute at every text size', () {
    // Not a layout test. The three manual speeds are lines a minute written
    // down as pixels, so they have to be multiplied by how much bigger the
    // words are — and "how much bigger" used to be only this person's own
    // plus and minus buttons in Perform, never the size their phone is set
    // to. With the clamp gone that is a factor of up to 3.12, so a reader at
    // the largest iOS size scrolled at a third of everybody else's speed.
    expect(manualScrollSpeed(LiveScrollMode.medium, words: 1), 17.0);
    expect(manualScrollSpeed(LiveScrollMode.medium, words: 2), 34.0);
    expect(manualScrollSpeed(LiveScrollMode.slow, words: 3.12),
        closeTo(9.5 * 3.12, 0.001));
    // Synced follows the recording and timed re-derives its own speed from
    // the distance left and the time left, so neither is scaled here.
    expect(manualScrollSpeed(LiveScrollMode.synced, words: 2), 0.0);
    expect(manualScrollSpeed(LiveScrollMode.timed, words: 2), 0.0);
  });
}
