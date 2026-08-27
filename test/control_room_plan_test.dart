import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/control_room/control_room_screen.dart';
import 'package:flutter_test/flutter_test.dart';

SongProject _song(
  String title, {
  required int minutesAgo,
  bool recording = true,
  SongAnalysisState? state = SongAnalysisState.uploaded,
}) {
  final when = DateTime(2026, 8, 27, 12).subtract(Duration(minutes: minutesAgo));
  return SongProject(
    id: title,
    roomId: 'room',
    accountId: 'account',
    title: title,
    createdAt: when,
    updatedAt: when,
    hasAudioReference: recording,
    analysisState: recording ? state : null,
  );
}

MusicRoom _room(List<SongProject> projects) => MusicRoom(
      id: 'room',
      accountId: 'account',
      name: 'South Dean',
      icon: '🎸',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      projects: projects,
    );

void main() {
  group('ControlRoomPlan', () {
    test('a song with no recording never appears', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[
          _song('Lyrics only', minutesAgo: 1, recording: false),
          _song('Ladder', minutesAgo: 20),
        ]),
      ]);
      expect(plan.total, 1);
      expect(plan.lead?.project.title, 'Ladder');
    });

    test('an account of only unrecorded songs opens on the empty room', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[
          _song('Words', minutesAgo: 1, recording: false),
          _song('More words', minutesAgo: 2, recording: false),
        ]),
      ]);
      expect(plan.lead, isNull);
      expect(plan.total, 0);
    });

    test('leads with the newest recording that has no sheet', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[
          _song('Older', minutesAgo: 90),
          _song('Newest', minutesAgo: 2),
          _song('Finished',
              minutesAgo: 1, state: SongAnalysisState.ready),
        ]),
      ]);
      expect(plan.lead?.project.title, 'Newest');
      expect(plan.leadIsSheet, isFalse);
      // The lead is never repeated in the pile it came from.
      expect(plan.waiting.map((entry) => entry.project.title), <String>['Older']);
      expect(plan.sheets.map((entry) => entry.project.title), <String>['Finished']);
    });

    test('with nothing waiting it leads with the last sheet touched', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[
          _song('Older sheet', minutesAgo: 60, state: SongAnalysisState.ready),
          _song('Newer sheet', minutesAgo: 5, state: SongAnalysisState.ready),
        ]),
      ]);
      expect(plan.lead?.project.title, 'Newer sheet');
      expect(plan.leadIsSheet, isTrue);
      expect(plan.sheets.map((entry) => entry.project.title),
          <String>['Older sheet']);
    });

    test('a run in flight is its own pile, not one you are asked to start', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[
          _song('Running', minutesAgo: 1, state: SongAnalysisState.processing),
          _song('Queued', minutesAgo: 2, state: SongAnalysisState.queued),
          _song('Waiting', minutesAgo: 3),
        ]),
      ]);
      expect(plan.working.map((entry) => entry.project.title),
          <String>['Running', 'Queued']);
      // The lead is the one somebody can act on, not the one already running.
      expect(plan.lead?.project.title, 'Waiting');
    });

    test('a failed run waits with the rest rather than hiding', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[
          _song('Broke', minutesAgo: 1, state: SongAnalysisState.failed),
          _song('Fine', minutesAgo: 30),
        ]),
      ]);
      expect(plan.lead?.project.title, 'Broke');
      expect(plan.leadIsSheet, isFalse);
      expect(plan.waiting.map((entry) => entry.project.title), <String>['Fine']);
    });

    test('songs from every catalog land in the same room', () {
      final plan = ControlRoomPlan.from(<MusicRoom>[
        _room(<SongProject>[_song('One', minutesAgo: 10)]),
        _room(<SongProject>[_song('Two', minutesAgo: 5)]),
      ]);
      expect(plan.total, 2);
      expect(plan.lead?.project.title, 'Two');
    });
  });
}
