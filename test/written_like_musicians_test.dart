import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/sounds.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/song_analysis_screen.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Written the way musicians write it.
///
/// From the audit of 17 September 2026. South Of Midnight's sheet said "Key
/// A# major", over A# and D# chords: B♭ major, written as nobody writes it.
/// The tour and Open Mic settings spelled one genre two ways, and the two
/// never matched. And "Sing Midnight Signal once" recorded into a new idea
/// instead of Midnight Signal.
void main() {
  group('flats in flat keys', () {
    test('which keys are written with flats', () {
      for (final key in <String>['A# major', 'Bb major', 'F major', 'D# major', 'G# major', 'C# major']) {
        expect(keyUsesFlats(key), isTrue, reason: key);
      }
      for (final key in <String>['D minor', 'G minor', 'C minor', 'F minor', 'A# minor']) {
        expect(keyUsesFlats(key), isTrue, reason: key);
      }
      // Six accidentals either way: written sharp, like F# major.
      expect(keyUsesFlats('D# minor'), isFalse);
      for (final key in <String>['C major', 'G major', 'D major', 'A major', 'E major', 'B major', 'F# major', 'A minor', 'E minor']) {
        expect(keyUsesFlats(key), isFalse, reason: key);
      }
      expect(keyUsesFlats(null), isFalse);
      expect(keyUsesFlats(''), isFalse);
    });

    test('the key and its chords are respelled', () {
      expect(spellInKey('A# major', 'A# major'), 'Bb major');
      expect(spellInKey('A#', 'A# major'), 'Bb');
      expect(spellInKey('D#m7/A#', 'A# major'), 'Ebm7/Bb');
      expect(spellInKey('Gm', 'A# major'), 'Gm');
    });

    test('sharp keys, and flats somebody wrote, are left alone', () {
      expect(spellInKey('F#m', 'D major'), 'F#m');
      expect(spellInKey('Bb', 'F major'), 'Bb');
      expect(spellInKey('A#', null), 'A#');
    });

    test("a minor key keeps its leading tone sharp", () {
      expect(spellInKey('C#dim', 'D minor'), 'C#dim');
      expect(spellInKey('A#', 'D minor'), 'Bb');
    });

    test('a slash bass is spelled as the chord tone it is', () {
      // The third of D is an F of some kind, so a flat key cannot call it Gb.
      expect(spellInKey('D/F#', 'D minor'), 'D/F#');
      expect(spellInKey('A/C#', 'D minor'), 'A/C#');
      // Basses the key already spelled right are spelled the same way still.
      expect(spellInKey('Bb/D', 'F major'), 'Bb/D');
      expect(spellInKey('Eb/G', 'Bb major'), 'Eb/G');
      expect(spellInKey('C/E', 'Eb major'), 'C/E');
      expect(spellInKey('Bbm7/F', 'Eb major'), 'Bbm7/F');
    });

    test('a bass that is not a chord tone follows the key', () {
      expect(spellInKey('C/Bb', 'Eb major'), 'C/Bb');
      expect(spellInKey('C/A#', 'Eb major'), 'C/Bb');
      // A degree rather than a note, and a quality with a slash in it.
      expect(spellInKey('G#:maj/3', 'Eb major'), 'Ab:maj/3');
      expect(spellInKey('C#6/9', 'Eb major'), 'Db6/9');
    });

    test('a flat bass somebody wrote is not corrected to a sharp', () {
      // The chord rule reads the same third in D/Gb and would call it F#.
      // Somebody typed that Gb, and a spelling somebody chose is theirs --
      // the same promise the key rule makes (review, 17 September 2026).
      expect(spellInKey('D/Gb', 'D minor'), 'D/Gb');
      expect(spellInKey('C+/Ab', 'Eb major'), 'C+/Ab');
    });
  });

  group('one word for one sound', () {
    test('spellings of one sound fold together', () {
      expect(soundWord('Hip Hop'), 'hip-hop');
      expect(soundWord('hip-hop'), 'hip-hop');
      expect(soundWord('  LoFi '), 'lo-fi');
      expect(soundWord('R & B'), 'r&b');
      expect(soundWord('drum and   bass'), 'drum and bass');
    });

    test('the list offered is already in the kept spelling, once each', () {
      expect(soundStarters.toSet().length, soundStarters.length);
      for (final word in soundStarters) {
        expect(soundWord(word), word);
      }
    });
  });

  testWidgets('"Sing it once" records into the song it names', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    var genericRecord = 0;
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SongsScreen(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
            onRecord: () => genericRecord += 1,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final card = find.byKey(const Key('waiting_card_tonight-first-sing-it'));
    expect(card, findsOneWidget);
    await tester.tap(find.descendant(of: card, matching: find.text('Record')));
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(genericRecord, 0, reason: 'the generic Record button starts a new idea');
    // Under whatever the recorder opens over it first.
    final screen = tester.widget<SongAnalysisScreen>(find.byType(SongAnalysisScreen, skipOffstage: false));
    expect(screen.project.title, 'Midnight Signal');
    expect(screen.autoRecord, isTrue);
  });
}
