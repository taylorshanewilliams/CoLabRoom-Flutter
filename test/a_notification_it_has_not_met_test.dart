import 'package:colabroom/domain/music_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row of a notification type the build does not know must never take
/// the app down. It did: the server has written `song_ask` rows since
/// migration 0048, the app's parser threw on the first one anybody
/// received, and because every notification loads in one call the whole
/// workspace failed to open -- "We could not open the workspace" -- for a
/// notification. Every type is unknown to some build in the field, so the
/// parser's answer to a word it has not met is a shrug, not a refusal.
void main() {
  test('the types the app knows, by the server\'s names', () {
    expect(notificationTypeFromSql('invite_received'), NotificationType.inviteReceived);
    expect(notificationTypeFromSql('invite_accepted'), NotificationType.inviteAccepted);
    expect(notificationTypeFromSql('invite_declined'), NotificationType.inviteDeclined);
    expect(notificationTypeFromSql('project_update'), NotificationType.projectUpdate);
    expect(notificationTypeFromSql('analysis_ready'), NotificationType.analysisReady);
    expect(notificationTypeFromSql('song_ask'), NotificationType.songAsk);
  });

  test('a type it has not met is unfamiliar, never an error', () {
    expect(notificationTypeFromSql('room_closed'), NotificationType.unfamiliar);
    expect(notificationTypeFromSql(''), NotificationType.unfamiliar);
    expect(() => notificationTypeFromSql('anything_at_all'), returnsNormally);
  });
}
