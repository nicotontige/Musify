import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/scrobble.dart';

void main() {
  final playedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  group('Scrobble.fromSong', () {
    test('reads a song map', () {
      final listen = Scrobble.fromSong({
        'ytid': 'abc',
        'title': 'One More Time',
        'artist': 'Daft Punk',
        'album': 'Discovery',
        'duration': 320,
      }, playedAt: playedAt);

      expect(listen, isNotNull);
      expect(listen!.title, 'One More Time');
      expect(listen.artist, 'Daft Punk');
      expect(listen.album, 'Discovery');
      expect(listen.duration, const Duration(seconds: 320));
      expect(listen.timestamp, 1700000000);
    });

    test('ignores the stringified nulls song maps carry', () {
      final listen = Scrobble.fromSong({
        'title': 'Around the World',
        'artist': 'Daft Punk',
        'album': 'null',
      }, playedAt: playedAt);

      expect(listen?.album, isNull);
      expect(listen?.duration, isNull);
    });

    test('drops the topic channel suffix from the artist', () {
      final listen = Scrobble.fromSong({
        'title': 'Veridis Quo',
        'artist': 'Daft Punk - Topic',
      }, playedAt: playedAt);

      expect(listen?.artist, 'Daft Punk');
    });

    test('falls back to the video author when there is no artist', () {
      final listen = Scrobble.fromSong({
        'title': 'Veridis Quo',
        'artist': 'null',
        'videoAuthor': 'Daft Punk',
      }, playedAt: playedAt);

      expect(listen?.artist, 'Daft Punk');
    });

    test('refuses what cannot be scrobbled', () {
      expect(
        Scrobble.fromSong({
          'title': 'Lofi radio',
          'artist': 'Someone',
          'isLive': true,
        }, playedAt: playedAt),
        isNull,
      );
      expect(
        Scrobble.fromSong({'title': 'Nameless'}, playedAt: playedAt),
        isNull,
      );
    });
  });

  test('survives a round trip through the queue storage', () {
    final listen = Scrobble.fromSong({
      'title': 'One More Time',
      'artist': 'Daft Punk',
      'album': 'Discovery',
      'duration': 320,
    }, playedAt: playedAt)!;

    final restored = Scrobble.fromJson(listen.toJson());

    expect(restored.title, listen.title);
    expect(restored.artist, listen.artist);
    expect(restored.album, listen.album);
    expect(restored.duration, listen.duration);
    expect(restored.timestamp, listen.timestamp);
  });
}
