import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every Musician, Same Song, 17 September 2026, world traditions item 3.
///
/// A room says what its song is sung in (0163) and the transcriber is told.
/// Until now only the fallback and the offer to listen again were told; the
/// first listen — the transcription inside the analysis job, where nearly
/// every transcript in this app comes from — guessed. Now it is told too,
/// and the words come back knowing what they were heard in (0167).
///
/// Nothing on the page says so. The one thing that changes for a musician is
/// that the sheet stops offering to pay to hear a song again in the language
/// it was already heard in.
void main() {
  group('what the transcriber hears a tag as', () {
    test('is the language, without the script or the region', () {
      expect(languageOf('ar-EG'), 'ar');
      expect(languageOf('pt-BR'), 'pt');
      expect(languageOf('zh-Hans-CN'), 'zh');
      expect(languageOf(null), isNull);
    });

    test('and is its own spelling where the transcriber has one', () {
      // This app's list stores the Bokmål tag and Whisper only knows 'no'.
      // Both are the same instruction, so a song declared 'nb' whose words
      // were heard in 'no' was heard in the language it says it is sung in.
      expect(languageOf('nb'), 'no');
      expect(languageOf('nb-NO'), 'no');
      expect(languageOf('yue'), 'zh');
      expect(languageOf('fil'), 'tl');
    });
  });

  group('once the words know what they were heard in', () {
    testWidgets('saying that same language offers nothing', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _ListensAgain(heardIn: 'ar');
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();

      await _sayArabic(tester);

      // The room had not said before — so this is a new answer — but the
      // first listen was told it anyway and these are already the Arabic
      // words. Listening again would spend money to write down the same
      // thing, and saying so would claim the words are older than they are.
      expect(service.said, 'ar');
      expect(find.byKey(const Key('listen_again_question')), findsNothing);
      expect(service.listened, 0);
    });

    testWidgets('and a region on the tag is still that same language',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // Whisper is told 'pt' whether the song says 'pt' or 'pt-BR', so a
      // transcript heard in 'pt' is the answer to both. Compared the way the
      // transcriber sees it, or every Brazilian song would be offered a
      // re-listen that changes nothing.
      final service = _ListensAgain(heardIn: 'pt');
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();

      await _say(
        tester,
        search: 'pt-BR',
        option: const Key('song_language_typed_tag'),
      );

      expect(service.said, 'pt-BR');
      expect(find.byKey(const Key('listen_again_question')), findsNothing);
    });

    testWidgets('but a different language is still worth offering',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // The words were heard in Spanish — which is exactly the failure this
      // whole feature exists for, a song the transcriber guessed wrong about.
      final service = _ListensAgain(heardIn: 'es');
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();

      await _sayArabic(tester);

      expect(find.byKey(const Key('listen_again_question')), findsOneWidget);
      // Still asked rather than done: it costs money and replaces words
      // somebody may have corrected by hand.
      expect(service.listened, 0);
    });

    testWidgets('and words that cannot say are offered exactly as before',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // Every transcript made before this change, and every one made by a
      // worker image that predates it. "Not known" is not "the right one":
      // the offer stands, which is what this song would have got yesterday.
      final service = _ListensAgain(heardIn: null);
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();

      await _sayArabic(tester);

      expect(find.byKey(const Key('listen_again_question')), findsOneWidget);
    });
  });
}

Future<void> _sayArabic(WidgetTester tester) => _say(
      tester,
      search: 'Arabic',
      option: const Key('song_language_ar'),
    );

/// Taps the line under the sheet's title and answers the question.
Future<void> _say(
  WidgetTester tester, {
  required String search,
  required Key option,
}) async {
  await tester.tap(find.byKey(const Key('song_sheet_sung_in')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('song_language_search')), search);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(option));
  await tester.pumpAndSettle();
}

/// The sheet panel, wired the way SongAnalysisScreen wires it: the song
/// carries the answer, so saying it changes the project the panel holds.
class _Panel extends StatefulWidget {
  const _Panel({required this.service});

  final _ListensAgain service;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  late SongProject _project = _song();
  late SongAnalysisBundle _bundle = widget.service.bundle;

  @override
  Widget build(BuildContext context) {
    return SongSheetPanel(
      project: _project,
      bundle: _bundle,
      onReviewLyrics: null,
      onOpenLive: null,
      analysisService: widget.service,
      onSetLanguage: (language) async {
        widget.service.said = language;
        setState(() => _project = _project.copyWith(language: language));
      },
      onAnalysisChanged: (bundle) => setState(() => _bundle = bundle),
    );
  }
}

Widget _panel(_ListensAgain service) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: _Panel(service: service)),
      ),
    );

/// An analysis service holding one transcript, which may or may not know
/// what language it was heard in.
class _ListensAgain extends SongAnalysisService {
  _ListensAgain({required String? heardIn})
      : bundle = SongAnalysisBundle(
          reference: ReferenceTrack(
            projectId: 'song-1',
            fileId: 'file-1',
            storagePath: 'room/song/reference.wav',
            displayName: 'reference.wav',
            state: SongAnalysisState.ready,
            durationMs: 4000,
            transcriptText: 'the night passes over the river',
            transcriptWords: const <TranscriptWord>[
              TranscriptWord(word: 'the', startMs: 0, endMs: 900),
              TranscriptWord(word: 'night', startMs: 1000, endMs: 1900),
            ],
            transcriptLanguage: heardIn,
          ),
          lyricCues: const <LyricSyncCue>[],
          chordCues: const <ChordCue>[
            ChordCue(id: 1, startMs: 0, endMs: 1900, chord: 'G', confidence: 0.9),
          ],
        ),
        super(client: null);

  final SongAnalysisBundle bundle;

  String? said;
  int listened = 0;

  @override
  Future<SongAnalysisBundle> load(String projectId) async => bundle;

  @override
  Future<SongAnalysisBundle> transcribeAgain({
    required SongProject project,
    required SongAnalysisBundle bundle,
  }) async {
    listened += 1;
    return this.bundle;
  }
}

SongProject _song() {
  final now = DateTime(2026, 9, 19);
  return SongProject(
    id: 'song-1',
    roomId: 'room-1',
    accountId: 'account-1',
    title: 'A Song',
    createdAt: now,
    updatedAt: now,
  );
}
