/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     Musify is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about Musify, including how to contribute,
 *     please visit: https://github.com/gokadzev/Musify
 */

import 'dart:async';
import 'dart:math';

import 'package:musify/main.dart' show logger;
import 'package:musify/services/common_services.dart';
import 'package:musify/services/listening_stats_service.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/utilities/listening_stats_utils.dart';
import 'package:musify/utilities/map_utils.dart';

/// Songs played between two picks woven into the queue.
const smartShuffleInterval = 4;

/// Slots left untouched after the current song before a pick is woven in, so
/// that whatever the listener queued next is still played next.
const smartShuffleLookahead = 2;

/// Picks allowed to sit unplayed ahead of the current song. Keeps a long
/// listening session from turning into a queue of nothing but discoveries.
const smartShuffleMaxPendingPicks = 2;

/// Picks remembered so the same discovery is not proposed twice in a session.
const smartShuffleMemorySize = 50;

/// Weight of the recommendation ranking in a candidate's score. Kept below the
/// artist affinity, which tops out at 1, so that what the listener actually
/// plays outweighs the order the recommendation source happened to return.
const smartShufflePositionWeight = 0.5;

/// Score malus for a candidate whose artist is already in the queue. It also
/// replaces the affinity bonus: a favourite artist already lined up is not a
/// discovery, it is more of the same.
const smartShuffleSameArtistPenalty = 0.5;

/// Recommendations are a nice-to-have: playback never waits longer than this.
const smartShuffleFetchTimeout = Duration(seconds: 10);

/// What the audio handler exposes of its live queue to the weaver.
class SmartShuffleQueueState {
  const SmartShuffleQueueState({
    required this.queue,
    required this.history,
    required this.currentIndex,
    required this.isPlaying,
  });

  final List<Map> queue;
  final List<Map> history;
  final int currentIndex;
  final bool isPlaying;
}

/// Normalized artist name used as the key of the affinity map, or null when
/// the song carries no usable artist.
String? smartShuffleArtistKey(dynamic artist) {
  final name = artist?.toString().trim().toLowerCase();
  return name == null || name.isEmpty ? null : name;
}

/// Per-artist weight in `0..1` built from the listening stats top songs, the
/// most played artist scoring 1. An empty history yields an empty map, which
/// simply leaves candidates ranked by the recommendation order.
Map<String, double> smartShuffleArtistAffinity(Iterable<Map> topSongs) {
  final plays = <String, int>{};

  for (final song in topSongs) {
    final artist = smartShuffleArtistKey(song['artist']);
    if (artist == null) continue;
    final playCount = song['playCount'];
    final weight = playCount is int && playCount > 0 ? playCount : 1;
    plays[artist] = (plays[artist] ?? 0) + weight;
  }

  if (plays.isEmpty) return const {};

  final mostPlayed = plays.values.reduce(max);
  return plays.map((artist, count) => MapEntry(artist, count / mostPlayed));
}

/// Normalized artists of every song in [songs].
Set<String> smartShuffleArtists(Iterable<dynamic> songs) {
  final artists = <String>{};
  for (final song in songs) {
    if (song is! Map) continue;
    final artist = smartShuffleArtistKey(song['artist']);
    if (artist != null) artists.add(artist);
  }
  return artists;
}

/// Picks already woven in but not played yet.
int smartShufflePendingPicks(List<Map> queue, int currentIndex) {
  var pending = 0;
  for (var i = max(currentIndex + 1, 0); i < queue.length; i++) {
    if (queue[i]['isAutoPicked'] == true) pending++;
  }
  return pending;
}

/// Index at which a pick is woven in: far enough ahead not to hijack what the
/// listener queued next, close enough to be heard soon. A queue with nothing
/// left after the current song gets the pick appended, which is what keeps a
/// long session from running dry.
int smartShuffleInsertIndex({
  required int queueLength,
  required int currentIndex,
  int lookahead = smartShuffleLookahead,
}) {
  if (queueLength <= 0) return 0;

  final target = max(currentIndex + 1, 0) + lookahead;
  return min(target, queueLength);
}

/// Ranks [candidates] and returns the [limit] best ones.
///
/// Anything already queued, already played or already proposed is dropped; the
/// rest is scored on how close it sits to the top of the recommendation list,
/// how much the listener plays that artist, and whether that artist is already
/// represented in the queue. The ranking is deterministic: the randomness is
/// the recommendation source's job, not this one's.
List<Map> rankSmartShuffleCandidates(
  Iterable<dynamic> candidates, {
  required Set<String> excludedYtids,
  Map<String, double> artistAffinity = const {},
  Set<String> queuedArtists = const {},
  int limit = 1,
}) {
  if (limit <= 0) return const [];

  final songs = candidates.whereType<Map>().toList();
  final scored = <({Map song, double score, String ytid})>[];
  final seenYtids = <String>{};
  final span = songs.length <= 1 ? 1 : songs.length - 1;

  for (var position = 0; position < songs.length; position++) {
    final song = songs[position];
    final ytid = songYtid(song);
    if (ytid == null || excludedYtids.contains(ytid) || !seenYtids.add(ytid)) {
      continue;
    }

    var score = (1 - position / span) * smartShufflePositionWeight;
    final artist = smartShuffleArtistKey(song['artist']);
    if (artist != null) {
      score += queuedArtists.contains(artist)
          ? -smartShuffleSameArtistPenalty
          : artistAffinity[artist] ?? 0;
    }

    scored.add((song: song, score: score, ytid: ytid));
  }

  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.ytid.compareTo(b.ytid);
  });

  return scored.take(limit).map((entry) => entry.song).toList();
}

/// Weaves recommended songs into the queue that is already playing, instead of
/// replacing it: the listener keeps everything they lined up and hears a
/// discovery slipped in every few songs.
class SmartShuffleService {
  SmartShuffleService({
    Future<List> Function()? fetchRecommendations,
    List<Map> Function()? topSongs,
    bool Function()? isEnabled,
  }) : _fetchRecommendations = fetchRecommendations ?? getRecommendedSongs,
       _topSongs = topSongs ?? _listeningStatsTopSongs,
       _isEnabled = isEnabled ?? _smartShuffleIsOn;

  final Future<List> Function() _fetchRecommendations;
  final List<Map> Function() _topSongs;
  final bool Function() _isEnabled;

  /// Recommendations fetched but not woven in yet, so that a session costs one
  /// network round trip every handful of picks instead of one per pick.
  final List<Map> _pool = [];
  final List<String> _proposedYtids = [];
  int _songsSincePick = 0;
  bool _isWeaving = false;

  /// Songs played since the last pick landed in the queue.
  int get songsSincePick => _songsSincePick;

  /// Called when a song starts playing. Does nothing unless smart shuffle is
  /// on, and never makes the caller wait: the recommendation is fetched in the
  /// background and simply dropped if it fails, times out, or comes back after
  /// the listener moved on.
  Future<void> weaveIntoQueue({
    required SmartShuffleQueueState Function() snapshot,
    required Future<void> Function(Map song, int index) insertSong,
    int interval = smartShuffleInterval,
  }) async {
    if (!_isEnabled() || _isWeaving) return;

    final state = snapshot();
    if (state.queue.isEmpty) return;

    _songsSincePick++;
    if (_songsSincePick < interval) return;
    if (smartShufflePendingPicks(state.queue, state.currentIndex) >=
        smartShuffleMaxPendingPicks) {
      return;
    }

    _isWeaving = true;
    try {
      final pick = await _nextPick(state);
      if (pick == null) return;

      // The listener may have skipped, stopped or requeued while the
      // recommendation was in flight, so the queue is read again rather than
      // trusting the snapshot taken before the fetch.
      final current = snapshot();
      if (!current.isPlaying || current.queue.isEmpty) return;

      _rememberPick(pick);
      _songsSincePick = 0;

      await insertSong(
        pick,
        smartShuffleInsertIndex(
          queueLength: current.queue.length,
          currentIndex: current.currentIndex,
        ),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Error weaving a smart shuffle song',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _isWeaving = false;
    }
  }

  /// Forgets the pending picks and the pick countdown, so a brand new queue
  /// does not inherit the previous one's rhythm.
  void reset() {
    _pool.clear();
    _songsSincePick = 0;
  }

  Future<Map?> _nextPick(SmartShuffleQueueState state) async {
    final excludedYtids = _excludedYtids(state);
    final queuedArtists = smartShuffleArtists(state.queue);
    final artistAffinity = smartShuffleArtistAffinity(_topSongs());

    List<Map> rank() => rankSmartShuffleCandidates(
      _pool,
      excludedYtids: excludedYtids,
      artistAffinity: artistAffinity,
      queuedArtists: queuedArtists,
    );

    var picks = rank();
    if (picks.isEmpty) {
      await _refillPool();
      picks = rank();
    }
    if (picks.isEmpty) return null;

    final pick = picks.first;
    _pool.removeWhere((song) => songYtid(song) == songYtid(pick));
    return pick;
  }

  Future<void> _refillPool() async {
    try {
      final recommendations = await _fetchRecommendations().timeout(
        smartShuffleFetchTimeout,
      );

      _pool
        ..clear()
        ..addAll(recommendations.whereType<Map>());
    } on TimeoutException {
      logger.log('Smart shuffle recommendations timed out');
    }
  }

  Set<String> _excludedYtids(SmartShuffleQueueState state) {
    final excluded = <String>{..._proposedYtids};
    for (final songs in [state.queue, state.history]) {
      for (final song in songs) {
        final ytid = songYtid(song);
        if (ytid != null) excluded.add(ytid);
      }
    }
    return excluded;
  }

  void _rememberPick(Map song) {
    final ytid = songYtid(song);
    if (ytid == null) return;

    _proposedYtids.add(ytid);
    if (_proposedYtids.length > smartShuffleMemorySize) {
      _proposedYtids.removeRange(
        0,
        _proposedYtids.length - smartShuffleMemorySize,
      );
    }
  }
}

bool _smartShuffleIsOn() => smartShuffleEnabled.value && !offlineMode.value;

/// The artists the listener actually plays, this month first, with the year's
/// favourites behind them so a fresh month still has something to go on.
List<Map> _listeningStatsTopSongs() => [
  ...listeningStatsService.monthTopSongs(
    listeningStatsMonthKey(DateTime.now()),
  ),
  ...listeningStatsService.yearTopSongs(),
];

final smartShuffleService = SmartShuffleService();
