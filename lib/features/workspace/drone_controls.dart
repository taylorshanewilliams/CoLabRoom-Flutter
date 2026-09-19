import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/drone.dart';
import '../../services/drone_player.dart';
import '../../services/music_reference.dart' show keyRootPitch, keyUsesFlats, noteName;
import 'drone_store.dart';
import 'tuner_reference_store.dart';

/// One held note, and everything a screen needs to offer it.
///
/// The drone belongs to the screen rather than to the sheet the buttons are
/// on: somebody turns it on, closes the sheet and plays the song over it, so
/// it has to outlive the sheet and stop when Perform or the tuner is left
/// (Every Musician, Same Song, 17 September 2026). A screen makes one of
/// these, hands it to [DroneControls], and disposes it.
///
/// It decides nothing about the music. The note it offers first is the song's
/// own 1 — what the band said the key is, or failing that what the analysis
/// heard — and a song that has neither offers only a note somebody picks.
class DroneVoice extends ChangeNotifier {
  DroneVoice({
    DronePlayer? player,
    String? songKey,
    int a4 = TunerReferenceStore.standard,
    DroneSettings settings = const DroneSettings(),
  })  : player = player ?? WavDronePlayer(),
        _songKey = songKey,
        _a4 = a4,
        _settings = settings;

  /// Owned from here on: [dispose] stops and disposes it, whoever made it.
  final DronePlayer player;

  final String? _songKey;
  int _a4;
  DroneSettings _settings;
  int? _chosen;
  bool _on = false;

  /// Whether the level or the fifth was moved before the kept ones arrived, so
  /// a slow read cannot undo the press. The same guard the tuner's reference
  /// has, and for the same reason: on a cold launch the first touch can land
  /// before preferences have opened.
  bool _touched = false;

  /// Let go of. Every await below re-checks it: the screens fire [load]
  /// without waiting for it, and a sheet dismissed before preferences have
  /// opened would otherwise come back to a notifier that has been disposed.
  bool _disposed = false;

  /// The two seconds of a starting pitch, which nothing on screen counts.
  Timer? _pitchTimer;
  bool _pitchSounding = false;

  DroneSettings get settings => _settings;
  bool get on => _on;

  /// Whether anything this voice makes is coming out of the loudspeaker now:
  /// the held drone, or a starting pitch still ringing.
  ///
  /// The tuner asks. Its microphone is a couple of centimetres from that
  /// loudspeaker, so while this is true the needle would be reading the drone
  /// back rather than the string in somebody's hands.
  bool get sounding => _on || _pitchSounding;

  /// The pitch class the song counts from, or null when nothing says.
  int? get tonic => keyRootPitch(_songKey);

  /// The note picked by hand, or null for the song's 1.
  int? get chosen => _chosen;

  /// The note that will sound: the picked one, or the song's 1.
  int? get note => _chosen ?? tonic;

  /// Whether there is a note to sound at all.
  bool get canSound => note != null;

  /// What the note is called, spelled the way the song's key spells it, so a
  /// drone under a song in E♭ is not offered as a D♯.
  ///
  /// With printed accidentals, like the tuner's own note above it and the key
  /// reference: the parsers read ASCII, screens do not.
  String nameOf(int pitchClass) => noteName(
        pitchClass,
        flats: keyUsesFlats(_songKey),
      ).replaceAll('#', '♯').replaceAll('b', '♭');

  double? get hz {
    final pitchClass = note;
    return pitchClass == null ? null : droneHz(pitchClass, a4: _a4.toDouble());
  }

  /// Reads back how loud this device's drone is, and whether it has its fifth.
  ///
  /// The reference pitch is not read here. The tuner already has it on screen
  /// and can move it, so it pushes it through [setReference] instead — two
  /// reads racing each other would let a slow one undo a press.
  Future<void> load() async {
    final kept = await DroneStore.load();
    if (_disposed || _touched || kept == _settings) return;
    final was = _settings;
    _settings = kept;
    notifyListeners();
    if (!_on) return;
    // Only how loud it is changed, so the drone moves rather than starting
    // again. A preference arriving late is not a reason to re-attack a note
    // somebody is already tuning to, and rebuilding the loop for it would be
    // half a minute of tone built for nothing.
    if (kept.fifth == was.fifth) {
      unawaited(player.setLevel(kept.volume));
    } else {
      unawaited(_sound());
    }
  }

  /// What the tuner calls A, when a screen that has the drone also has the
  /// tuner's reference on it and moves it.
  void setReference(int a4) {
    if (_disposed || a4 == _a4) return;
    _a4 = a4;
    notifyListeners();
    if (_on) unawaited(_sound());
  }

  Future<void> setOn(bool on) async {
    if (_disposed) return;
    if (on && !canSound) return;
    if (on == _on) return;
    _on = on;
    notifyListeners();
    if (on) {
      await _sound();
    } else {
      await player.stop();
    }
  }

  /// Picks a note, or hands the drone back to the song's 1 with a null.
  Future<void> choose(int? pitchClass) async {
    if (_disposed || pitchClass == _chosen) return;
    _chosen = pitchClass;
    notifyListeners();
    if (_on) await _sound();
  }

  Future<void> setFifth(bool fifth) async {
    if (_disposed || fifth == _settings.fifth) return;
    _touched = true;
    _settings = _settings.copyWith(fifth: fifth);
    notifyListeners();
    unawaited(DroneStore.save(_settings));
    if (_on) await _sound();
  }

  /// Moves the level while the slider is still under a finger. The drone is
  /// not restarted: a drone that re-attacked on every step would be a row of
  /// notes, not a level.
  Future<void> setLevel(int level) async {
    if (_disposed) return;
    final within = level.clamp(0, 100);
    if (within == _settings.level) return;
    _touched = true;
    _settings = _settings.copyWith(level: within);
    notifyListeners();
    await player.setLevel(_settings.volume);
  }

  /// The finger came off the slider, so this is a choice worth keeping.
  void keepLevel() => unawaited(DroneStore.save(_settings));

  /// Sounds the note once, for about two seconds.
  Future<void> startingPitch() async {
    final at = hz;
    if (_disposed || at == null) return;
    // How long it will be ringing for, so the tuner knows to stop believing
    // its own microphone. Nothing shows this and nothing counts it down.
    _pitchTimer?.cancel();
    _pitchSounding = true;
    notifyListeners();
    _pitchTimer = Timer(
      Duration(milliseconds: (startingPitchSeconds * 1000).round()),
      () {
        _pitchSounding = false;
        if (!_disposed) notifyListeners();
      },
    );
    await player.sound(
      hz: at,
      fifth: _settings.fifth,
      level: _settings.volume,
    );
  }

  Future<void> _sound() async {
    final at = hz;
    if (_disposed || at == null) return;
    await player.hold(
      hz: at,
      fifth: _settings.fifth,
      level: _settings.volume,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _pitchTimer?.cancel();
    _pitchSounding = false;
    // Stopped before it is let go of, the way Perform's click is: a drone left
    // sounding after the screen has gone is a tone nobody has a button for.
    final held = player;
    unawaited(held.stop().then((_) => held.dispose()));
    super.dispose();
  }
}

/// The drone and the starting pitch, as the few controls they need.
///
/// The same controls on the tuner sheet and in Perform, because it is the same
/// sound: a note to tune against before anybody plays, and a note to find a
/// first entry from. Nothing counts, nothing is timed and nothing is scored —
/// a drone is on or it is not.
class DroneControls extends StatelessWidget {
  const DroneControls({required this.voice, super.key});

  final DroneVoice voice;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final sounding = voice.on;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // A Wrap, not a Row: the phone's own text size is honoured rather
            // than clamped, and at the largest of them a switch, a word and a
            // note menu do not fit across a phone.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: <Widget>[
                // Merged, so the switch is read as "Drone" rather than as a
                // switch with no name beside a word with no control.
                MergeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Switch(
                        key: const Key('drone_on'),
                        value: sounding,
                        activeThumbColor: AppColors.gold,
                        onChanged: voice.canSound
                            ? (value) => voice.setOn(value)
                            : null,
                      ),
                      const SizedBox(width: 2),
                      const Text(
                        'Drone',
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                _NoteMenu(voice: voice),
              ],
            ),
            const SizedBox(height: 2),
            // How loud it sits under the song. No number beside it: how loud a
            // drone is under your own voice is something you hear.
            Row(
              children: <Widget>[
                const Icon(Icons.volume_mute_rounded,
                    size: 16, color: AppColors.muted),
                Expanded(
                  child: Slider(
                    key: const Key('drone_level'),
                    value: voice.settings.level.toDouble(),
                    max: 100,
                    divisions: 10,
                    activeColor: AppColors.gold,
                    // Named where it would otherwise be a nameless slider
                    // between two icons. Said in the ten steps it moves in,
                    // because a screen reader has nothing else to go on.
                    semanticFormatterCallback: (value) =>
                        'Drone level ${(value / 10).round()} of 10',
                    onChanged: (value) => voice.setLevel(value.round()),
                    onChangeEnd: (_) => voice.keepLevel(),
                  ),
                ),
                const Icon(Icons.volume_up_rounded,
                    size: 16, color: AppColors.muted),
              ],
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: <Widget>[
                TextButton.icon(
                  key: const Key('drone_starting_pitch'),
                  onPressed:
                      voice.canSound ? () => voice.startingPitch() : null,
                  icon: const Icon(Icons.graphic_eq_rounded, size: 17),
                  label: const Text('Starting pitch'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                ),
                TextButton.icon(
                  key: const Key('drone_fifth'),
                  onPressed: () => voice.setFifth(!voice.settings.fifth),
                  icon: Icon(
                    voice.settings.fifth
                        ? Icons.check_rounded
                        : Icons.add_rounded,
                    size: 17,
                  ),
                  label: const Text('Fifth'),
                  style: TextButton.styleFrom(
                    foregroundColor: voice.settings.fifth
                        ? AppColors.gold
                        : AppColors.muted,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Which note is held: the song's own 1, or one somebody picks.
///
/// A song whose key nobody has said and whose recording was never analysed has
/// no 1 to offer, so the menu opens empty and asks. That is the honest answer:
/// nothing about a person or their song is inferred here, and a drone on a
/// guessed key is worse than no drone.
class _NoteMenu extends StatelessWidget {
  const _NoteMenu({required this.voice});

  final DroneVoice voice;

  @override
  Widget build(BuildContext context) {
    final tonic = voice.tonic;
    return DropdownButton<int?>(
      key: const Key('drone_note'),
      value: voice.chosen,
      hint: const Text(
        'Pick a note',
        style: TextStyle(color: AppColors.muted, fontSize: 13),
      ),
      dropdownColor: AppColors.deepNavy,
      underline: const SizedBox.shrink(),
      style: const TextStyle(color: AppColors.text, fontSize: 13),
      onChanged: (value) => voice.choose(value),
      items: <DropdownMenuItem<int?>>[
        if (tonic != null)
          DropdownMenuItem<int?>(
            value: null,
            child: Text('The 1 (${voice.nameOf(tonic)})'),
          ),
        for (var pitchClass = 0; pitchClass < 12; pitchClass += 1)
          DropdownMenuItem<int?>(
            value: pitchClass,
            child: Text(voice.nameOf(pitchClass)),
          ),
      ],
    );
  }
}
