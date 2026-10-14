import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/lastfm_client.dart';

/// Last.fm refuses every call whose signature it cannot reproduce, and the
/// rules are easy to get subtly wrong, so they are pinned here.
void main() {
  group('lastFmApiSignature', () {
    test('matches the example from the Last.fm documentation', () {
      expect(
        lastFmApiSignature({
          'api_key': 'xxxxxxxx',
          'method': 'auth.getSession',
          'token': 'xxxxxxx',
        }, 'mysecret'),
        '68afb32bee072407a63b6c41f3e1e2b4',
      );
    });

    test('sorts the parameters by name and leaves the format out', () {
      const expected = '16c703f48f9bbed3f1aab4d78d8c21b2';

      expect(
        lastFmApiSignature({
          'track': 'One More Time',
          'artist': 'Daft Punk',
          'timestamp': '1000',
          'method': 'track.scrobble',
          'api_key': 'key',
          'format': 'json',
        }, 'secret'),
        expected,
      );
      expect(
        lastFmApiSignature({
          'api_key': 'key',
          'artist': 'Daft Punk',
          'method': 'track.scrobble',
          'timestamp': '1000',
          'track': 'One More Time',
        }, 'secret'),
        expected,
      );
    });
  });
}
