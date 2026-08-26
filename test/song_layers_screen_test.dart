import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_layer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The test that would have caught the crash a person found instead.
///
/// SongLayersScreen's predecessor opened a modal sheet from initState, which
/// reads inherited widgets off a context that is not mounted yet. It threw
/// before its own first `await`, so every catch inside it was bypassed, the
/// failing future was discarded, and the screen sat on a progress ring
/// forever with no error. Pumping the widget reproduces that in about a
/// second — the only reason it took a phone is that nothing could pump it.
///
/// So these are deliberately shallow. They do not check that layers mix
/// correctly or that a fader moves; they check that the screen can be built,
/// settled, rebuilt and disposed without throwing, which is the entire class
/// of bug that was escaping.

class _EmptyLayers extends SongLayerService {
  _EmptyLayers() : super(client: null);

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async =>
      const <SharedLayer>[];

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _FailingLayers extends SongLayerService {
  _FailingLayers() : super(client: null);

  @override
  Future<List<SharedLayer>> listLayers(String projectId) async {
    throw StateError('the network is not here');
  }

  @override
  Future<void> markOpened(Iterable<String> layerIds) async {}
}

class _NoAnalysis extends SongAnalysisService {
  _NoAnalysis() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async =>
      const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
}

/// A song that has been analyzed and never overdubbed — the state almost
/// every song in a real account is in.
class _AnalyzedSong extends SongAnalysisService {
  _AnalyzedSong() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async => SongAnalysisBundle(
        reference: ReferenceTrack(
          projectId: projectId,
          fileId: 'file-1',
          storagePath: 'room-1/project-1/analysis/reference.m4a',
          displayName: 'The recording',
          state: SongAnalysisState.ready,
        ),
        lyricCues: const <LyricSyncCue>[],
        chordCues: const <ChordCue>[],
      );

  @override
  Future<String> ensureLocalReference(ReferenceTrack reference) async =>
      '/tmp/reference.m4a';
}

class _AnalysisThatWillNotLoad extends SongAnalysisService {
  _AnalysisThatWillNotLoad() : super(client: null);

  @override
  Future<SongAnalysisBundle> load(String projectId) async {
    throw StateError('storage said no');
  }
}

Widget _screen({
  SongLayerService? layers,
  SongAnalysisService? analysis,
}) {
  return MaterialApp(
    home: SongLayersScreen(
      roomId: 'room-1',
      projectId: 'project-1',
      songTitle: 'Mountains',
      layerService: layers ?? _EmptyLayers(),
      analysisService: analysis ?? _NoAnalysis(),
    ),
  );
}

void main() {
  testWidgets('an analyzed song shows its recording before any take exists',
      (tester) async {
    // The bug this exists for: hasLayers counted only the *shared* takes, and
    // gated the empty state, the list and the play button alike. So a song
    // that had been analyzed but never overdubbed fetched its recording,
    // downloaded it, and then drew "No takes yet" over the top of it with
    // nothing to press. Every analyzed song in the account did this.
    await tester.pumpWidget(_screen(analysis: _AnalyzedSong()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('The recording'), findsOneWidget);
    expect(find.text('No takes yet'), findsNothing);
  });

  testWidgets('an analyzed song can be played before any take exists',
      (tester) async {
    // Without this the recording could be listed and still not heard, which
    // is the same failure one layer further in.
    await tester.pumpWidget(_screen(analysis: _AnalyzedSong()));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('a song with neither takes nor a recording is still empty',
      (tester) async {
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    expect(find.text('No takes yet'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
  });

  testWidgets('a song with no takes builds and settles without throwing',
      (tester) async {
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No takes yet'), findsOneWidget);
    expect(find.text('Record the first take'), findsOneWidget);
  });

  testWidgets('the song title is shown so you know what you are adding to',
      (tester) async {
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    expect(find.text('Mountains'), findsOneWidget);
  });

  testWidgets('a failure fetching takes is shown, not swallowed',
      (tester) async {
    // The screen must not sit on a spinner forever when the network is gone.
    // That was the exact shape of the bug this file exists for.
    await tester.pumpWidget(_screen(layers: _FailingLayers()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('the network is not here'), findsOneWidget);
  });

  testWidgets('a recording that will not load says so and the screen survives',
      (tester) async {
    // A song with a recording on it showed an empty screen and no reason,
    // because that path had a bare catch on it. The note is the fix, and the
    // takes must still load around it.
    await tester.pumpWidget(_screen(analysis: _AnalysisThatWillNotLoad()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(find.text('No takes yet'), findsOneWidget);
  });

  testWidgets('it can be disposed while its first load is still in flight',
      (tester) async {
    // Opening the screen and immediately going back is ordinary behaviour and
    // a reliable way to find setState-after-dispose.
    await tester.pumpWidget(_screen());
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
