import 'package:flutter_test/flutter_test.dart';
import 'package:musify/utilities/scrobble_rules.dart';

/// The thresholds Last.fm and ListenBrainz ask every client to respect before
/// a play is reported as a listen.
void main() {
  group('scrobbleThreshold', () {
    test('never scrobbles a track shorter than 30 seconds', () {
      expect(scrobbleThreshold(const Duration(seconds: 29)), isNull);
      expect(scrobbleThreshold(const Duration(seconds: 1)), isNull);
    });

    test('asks for half of a short enough track', () {
      expect(
        scrobbleThreshold(const Duration(seconds: 30)),
        const Duration(seconds: 15),
      );
      expect(
        scrobbleThreshold(const Duration(minutes: 3)),
        const Duration(seconds: 90),
      );
    });

    test('caps a long track at four minutes', () {
      expect(
        scrobbleThreshold(const Duration(minutes: 10)),
        const Duration(minutes: 4),
      );
      expect(
        scrobbleThreshold(const Duration(hours: 1)),
        const Duration(minutes: 4),
      );
    });

    test('falls back to four minutes when the duration is unknown', () {
      expect(scrobbleThreshold(null), const Duration(minutes: 4));
      expect(scrobbleThreshold(Duration.zero), const Duration(minutes: 4));
    });
  });

  group('isScrobbleEligible', () {
    test('needs the threshold to be reached', () {
      const trackDuration = Duration(minutes: 3);
      expect(
        isScrobbleEligible(
          listened: const Duration(seconds: 89),
          trackDuration: trackDuration,
        ),
        isFalse,
      );
      expect(
        isScrobbleEligible(
          listened: const Duration(seconds: 90),
          trackDuration: trackDuration,
        ),
        isTrue,
      );
    });

    test('a jingle played on repeat is never scrobbled', () {
      expect(
        isScrobbleEligible(
          listened: const Duration(minutes: 30),
          trackDuration: const Duration(seconds: 20),
        ),
        isFalse,
      );
    });
  });
}
