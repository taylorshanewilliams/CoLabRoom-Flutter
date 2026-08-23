import 'dart:async';
import 'dart:io';

import 'package:colabroom/services/song_analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isConnectivityFailure', () {
    test('recognises a phone that lost DNS while its screen was off', () {
      // Verbatim from the screenshot that started this. An Android device
      // entering doze drops name resolution, and this used to end a
      // multi-minute analysis outright.
      const reported =
          "ClientException with SocketFailed host lookup: 'gzcoclsfvazfhcheefhz.supabase.co' "
          '(OS Error: No address associated with hostname, errno = 7)';
      expect(isConnectivityFailure(StateError(reported)), isTrue);
    });

    test('recognises the ordinary transport failures by type', () {
      expect(isConnectivityFailure(const SocketException('nope')), isTrue);
      expect(isConnectivityFailure(TimeoutException('nope')), isTrue);
    });

    test('recognises a connection that dropped mid-request', () {
      expect(isConnectivityFailure(Exception('Connection closed before full header')), isTrue);
      expect(isConnectivityFailure(Exception('Connection refused')), isTrue);
      expect(isConnectivityFailure(Exception('Network is unreachable')), isTrue);
    });

    test('does not mistake the service saying no for the network being gone', () {
      // This distinction decides whether a real analysis gets silently
      // replaced by the much worse on-device one.
      expect(
        isConnectivityFailure(StateError('That recording does not belong to this project.')),
        isFalse,
      );
      expect(isConnectivityFailure(StateError('RunPod separation failed: out of memory')), isFalse);
      expect(isConnectivityFailure(StateError('Chord service failed (500)')), isFalse);
    });
  });

  group('separationPollDelay', () {
    test('asks quickly at first, then eases off', () {
      // A cached analysis or a warm worker really can answer in seconds.
      expect(separationPollDelay(0), const Duration(seconds: 4));
      expect(separationPollDelay(9), const Duration(seconds: 4));
      expect(separationPollDelay(10), const Duration(seconds: 8));
      expect(separationPollDelay(24), const Duration(seconds: 8));
      expect(separationPollDelay(25), const Duration(seconds: 15));
      expect(separationPollDelay(400), const Duration(seconds: 15));
    });

    test('reaches the timeout in far fewer wakeups than a flat interval', () {
      // The point of the backoff: same ceiling, a third of the radio wakes.
      var elapsed = Duration.zero;
      var attempts = 0;
      while (elapsed < separationTimeout) {
        elapsed += separationPollDelay(attempts);
        attempts += 1;
      }
      expect(attempts, lessThan(60));
      // A flat four seconds would have been 150.
      expect(attempts * 4, lessThan(150 * 4));
    });
  });

  group('separationProgress', () {
    test('moves through the range reserved for separation', () {
      expect(separationProgress(Duration.zero).fraction, closeTo(0.15, 1e-9));
      expect(separationProgress(separationTimeout).fraction, closeTo(0.50, 1e-9));
    });

    test('stops claiming the wait is typical once it is not', () {
      expect(separationProgress(const Duration(seconds: 10)).label,
          'Separating the instruments');
      expect(separationProgress(const Duration(minutes: 1)).label,
          contains('waking up the GPU'));
      expect(separationProgress(const Duration(minutes: 4)).label, contains('Long takes'));
    });

    test('never runs past the end of its range', () {
      expect(separationProgress(const Duration(hours: 1)).fraction, closeTo(0.50, 1e-9));
    });
  });
}
