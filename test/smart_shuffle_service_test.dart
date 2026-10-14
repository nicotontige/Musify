import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/services/smart_shuffle_service.dart';

/// Smart shuffle (gokadzev/Musify#827) slips recommendations into the queue
/// that is already playing. What matters here is that it never touches the
/// songs the listener lined up, never proposes something they just heard, and
/// never does anything at all while the setting is off.
void main() {
  late Directory temporaryDirectory;

  setUpAll(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'musify_smart_shuffle_test',
    );
    Hive.init(temporaryDirectory.path);
    await Hive.openBox('settings');
    await Hive.openBox('user');
  });

  tearDownAll(() async {
    await Hive.close();
    await temporaryDirectory.delete(recursive: true);
  });

  Map song(String ytid, {String? artist}) => {
    'ytid': ytid,
    'title': ytid,
    if (artist != null) 'artist': artist,
  };

  group('smartShuffleArtistAffinity', () {
    test('scores the most played artist 1 and the others below', () {
      final affinity = smartShuffleArtistAffinity([
        {'artist': 'Portishead', 'playCount': 10},
        {'artist': 'portishead ', 'playCount': 10},
        {'artist': 'Air', 'playCount': 5},
      ]);

      expect(affinity['portishead'], 1.0);
      expect(affinity['air'], 0.25);
    });

    test('ignores songs without an artist and untracked play counts', () {
      final affinity = smartShuffleArtistAffinity([
        {'artist': '  '},
        {'title': 'no artist at all'},
        {'artist': 'Air'},
      ]);

      expect(affinity, {'air': 1.0});
    });

    test('an empty listening history yields no affinity', () {
      expect(smartShuffleArtistAffinity(const []), isEmpty);
    });
  });

  group('rankSmartShuffleCandidates', () {
    test('drops excluded, duplicate and unidentified candidates', () {
      final picks = rankSmartShuffleCandidates(
        [
          song('queued'),
          {'title': 'no ytid'},
          song('fresh'),
          song('fresh'),
          'not a song',
        ],
        excludedYtids: {'queued'},
        limit: 5,
      );

      expect(picks.map((pick) => pick['ytid']), ['fresh']);
    });

    test('follows the recommendation order when nothing is known', () {
      final picks = rankSmartShuffleCandidates(
        [song('first'), song('second'), song('third')],
        excludedYtids: const {},
        limit: 3,
      );

      expect(picks.map((pick) => pick['ytid']), ['first', 'second', 'third']);
    });

    test('promotes an artist the listener plays a lot', () {
      final picks = rankSmartShuffleCandidates(
        [
          song('unknown', artist: 'Someone Else'),
          song('loved', artist: 'Portishead'),
        ],
        excludedYtids: const {},
        artistAffinity: const {'portishead': 1},
        limit: 2,
      );

      expect(picks.first['ytid'], 'loved');
    });

    test('demotes an artist already represented in the queue', () {
      final picks = rankSmartShuffleCandidates(
        [
          song('sameArtist', artist: 'Portishead'),
          song('newArtist', artist: 'Air'),
        ],
        excludedYtids: const {},
        artistAffinity: const {'portishead': 1, 'air': 0.3},
        queuedArtists: const {'portishead'},
        limit: 2,
      );

      expect(picks.first['ytid'], 'newArtist');
    });

    test('breaks ties by id so the ranking is reproducible', () {
      final candidates = [song('b'), song('a')];

      expect(
        rankSmartShuffleCandidates(
          candidates,
          excludedYtids: const {},
        ).first['ytid'],
        'b',
      );
      expect(
        rankSmartShuffleCandidates(
          candidates.reversed,
          excludedYtids: const {},
        ).first['ytid'],
        'a',
      );
    });

    test('returns nothing when asked for nothing', () {
      expect(
        rankSmartShuffleCandidates(
          [song('a')],
          excludedYtids: const {},
          limit: 0,
        ),
        isEmpty,
      );
    });
  });

  group('smartShuffleInsertIndex', () {
    test('leaves the next few queued songs alone', () {
      expect(
        smartShuffleInsertIndex(queueLength: 10, currentIndex: 2),
        2 + 1 + smartShuffleLookahead,
      );
    });

    test('appends when the queue is about to run out', () {
      expect(smartShuffleInsertIndex(queueLength: 4, currentIndex: 3), 4);
      expect(smartShuffleInsertIndex(queueLength: 4, currentIndex: 2), 4);
    });

    test('never lands before the current song', () {
      expect(smartShuffleInsertIndex(queueLength: 5, currentIndex: -1), 2);
      expect(smartShuffleInsertIndex(queueLength: 0, currentIndex: 0), 0);
    });
  });

  group('smartShufflePendingPicks', () {
    test('counts only the picks still ahead of the current song', () {
      final queue = [
        {'ytid': 'played', 'isAutoPicked': true},
        {'ytid': 'current'},
        {'ytid': 'queued'},
        {'ytid': 'pick', 'isAutoPicked': true},
      ];

      expect(smartShufflePendingPicks(queue, 1), 1);
      expect(smartShufflePendingPicks(queue, -1), 2);
      expect(smartShufflePendingPicks(queue, 3), 0);
    });
  });

  group('weaveIntoQueue', () {
    late List<Map> queue;
    late List<Map> history;
    late int currentIndex;
    late bool isPlaying;
    late int fetchCount;

    setUp(() {
      queue = [song('a'), song('b'), song('c')];
      history = [];
      currentIndex = 0;
      isPlaying = true;
      fetchCount = 0;
    });

    SmartShuffleQueueState snapshot() => SmartShuffleQueueState(
      queue: queue,
      history: history,
      currentIndex: currentIndex,
      isPlaying: isPlaying,
    );

    Future<void> insertSong(Map pick, int index) async {
      queue.insert(index, {...pick, 'isAutoPicked': true});
      if (index <= currentIndex) currentIndex++;
    }

    Future<List> defaultFetch() async {
      fetchCount++;
      return [song('rec1'), song('rec2'), song('rec3')];
    }

    SmartShuffleService service({
      Future<List> Function()? fetchRecommendations,
      List<Map> Function()? topSongs,
    }) => SmartShuffleService(
      fetchRecommendations: fetchRecommendations ?? defaultFetch,
      topSongs: topSongs ?? () => const [],
      isEnabled: () => true,
    );

    Future<void> playSongs(SmartShuffleService weaver, int count) async {
      for (var i = 0; i < count; i++) {
        await weaver.weaveIntoQueue(
          snapshot: snapshot,
          insertSong: insertSong,
          interval: 2,
        );
      }
    }

    test('is off by default and leaves the queue untouched', () async {
      // No `isEnabled` override: this exercises the real setting, which ships
      // disabled, and must behave exactly like a build without the feature.
      expect(smartShuffleEnabled.value, isFalse);

      final weaver = SmartShuffleService(
        fetchRecommendations: defaultFetch,
        topSongs: () => const [],
      );
      await playSongs(weaver, 10);

      expect(queue.map((entry) => entry['ytid']), ['a', 'b', 'c']);
      expect(fetchCount, 0);
    });

    test(
      'weaves a pick in after the interval, behind the queued songs',
      () async {
        final weaver = service();

        await playSongs(weaver, 1);
        expect(queue.length, 3, reason: 'too early for a pick');

        await playSongs(weaver, 1);

        expect(queue.map((entry) => entry['ytid']), ['a', 'b', 'c', 'rec1']);
        expect(queue.last['isAutoPicked'], isTrue);
        expect(weaver.songsSincePick, 0);
        expect(fetchCount, 1);
      },
    );

    test(
      'reuses the fetched pool instead of asking the network again',
      () async {
        final weaver = service();

        await playSongs(weaver, 2);
        queue.removeWhere((entry) => entry['isAutoPicked'] == true);
        await playSongs(weaver, 2);

        expect(queue.map((entry) => entry['ytid']), contains('rec2'));
        expect(fetchCount, 1);
      },
    );

    test('never proposes a song that is queued or already played', () async {
      final weaver = service();
      history = [song('rec1')];
      queue = [song('a'), song('rec2')];

      await playSongs(weaver, 2);

      expect(queue.map((entry) => entry['ytid']), ['a', 'rec2', 'rec3']);
    });

    test('stops once enough picks are waiting ahead', () async {
      final weaver = service();

      await playSongs(weaver, 2 * (smartShuffleMaxPendingPicks + 1));

      expect(
        queue.where((entry) => entry['isAutoPicked'] == true).length,
        smartShuffleMaxPendingPicks,
      );
    });

    test('falls back to the normal behaviour when the fetch fails', () async {
      final weaver = service(
        fetchRecommendations: () async => throw Exception('no route to host'),
      );

      await playSongs(weaver, 4);

      expect(queue.map((entry) => entry['ytid']), ['a', 'b', 'c']);
    });

    test('drops a pick that arrives after playback stopped', () async {
      final weaver = service(
        fetchRecommendations: () async {
          isPlaying = false;
          return [song('rec1')];
        },
      );

      await playSongs(weaver, 2);

      expect(queue.map((entry) => entry['ytid']), ['a', 'b', 'c']);
    });

    test('ranks the pool with the listener favourite artists', () async {
      final weaver = service(
        fetchRecommendations: () async => [
          song('filler', artist: 'Someone Else'),
          song('loved', artist: 'Portishead'),
        ],
        topSongs: () => [
          {'artist': 'Portishead', 'playCount': 20},
        ],
      );

      await playSongs(weaver, 2);

      expect(queue.last['ytid'], 'loved');
    });

    test('reset forgets the pool and the countdown', () async {
      final weaver = service()..reset();

      await playSongs(weaver, 1);
      weaver.reset();
      await playSongs(weaver, 1);

      expect(queue.length, 3);
      expect(weaver.songsSincePick, 1);
    });
  });
}
