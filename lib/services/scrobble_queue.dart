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

import 'package:musify/models/scrobble.dart';
import 'package:musify/services/data_manager.dart';

/// What a service answered for a batch of listens.
enum ScrobbleSubmission {
  /// The listens were taken; drop them.
  accepted,

  /// Nothing is wrong with the listens, the service could not be reached or
  /// asked us to come back later; keep them and back off.
  retryLater,

  /// The service refused the listens and always will (bad credentials, a
  /// malformed request); dropping them is the only way out of the loop.
  rejected,
}

typedef ScrobbleSender =
    Future<ScrobbleSubmission> Function(List<Scrobble> batch);

/// Where a queue keeps its listens between runs of the app.
abstract class ScrobbleStore {
  Future<List<dynamic>> read(String key);
  Future<void> write(String key, List<Map<String, dynamic>> listens);
}

/// Listens live in `userNoBackup`: they are device-local and short-lived, and
/// have no business travelling in a backup file the user may share.
class HiveScrobbleStore implements ScrobbleStore {
  const HiveScrobbleStore();

  @override
  Future<List<dynamic>> read(String key) async {
    final stored = await getData('userNoBackup', key, defaultValue: const []);
    return stored is List ? stored : const [];
  }

  @override
  Future<void> write(String key, List<Map<String, dynamic>> listens) =>
      addOrUpdateData<List>('userNoBackup', key, listens);
}

/// A persisted, bounded queue of listens waiting to reach one service.
///
/// Playback happens offline far more often than the rest of the app does — in
/// a car, in a basement — so a listen that cannot be sent right away is kept
/// on disk and offered again later instead of being lost.
class ScrobbleQueue {
  ScrobbleQueue(
    this.storageKey, {
    this.store = const HiveScrobbleStore(),
  });

  /// Older listens are dropped past this point. Last.fm refuses anything more
  /// than two weeks old anyway, so an unbounded queue only grows a file that
  /// will never be accepted.
  static const maxLength = 200;

  /// Last.fm takes at most 50 scrobbles per request; ListenBrainz takes far
  /// more, but the same batch keeps both paths identical.
  static const batchSize = 50;

  static const firstRetryDelay = Duration(minutes: 1);
  static const maxRetryDelay = Duration(hours: 2);

  final String storageKey;
  final ScrobbleStore store;
  final List<Scrobble> _pending = [];

  bool _loaded = false;
  bool _sending = false;
  int _consecutiveFailures = 0;
  DateTime? _nextAttempt;

  int get length => _pending.length;

  /// When the next attempt is allowed, as decided by the backoff. Exposed for
  /// tests and for the settings screen.
  DateTime? get nextAttempt => _nextAttempt;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    final stored = await store.read(storageKey);
    for (final entry in stored) {
      if (entry is Map) _pending.add(Scrobble.fromJson(entry));
    }
    _trim();
  }

  Future<void> add(Scrobble scrobble) async {
    await load();
    _pending.add(scrobble);
    _trim();
    await _persist();
  }

  /// Hands the queued listens to [send], oldest first, until it stops taking
  /// them. Submitting the backlog before anything newer is what the Last.fm
  /// protocol asks for, and it keeps a profile in chronological order.
  Future<void> flush(ScrobbleSender send, {DateTime? now}) async {
    await load();
    if (_sending || _pending.isEmpty) return;

    final currentTime = now ?? DateTime.now();
    final nextAttempt = _nextAttempt;
    if (nextAttempt != null && currentTime.isBefore(nextAttempt)) return;

    _sending = true;
    var changed = false;
    try {
      while (_pending.isNotEmpty) {
        final batch = _pending.take(batchSize).toList();
        final result = await send(batch);

        if (result == ScrobbleSubmission.retryLater) {
          _backOff(currentTime);
          break;
        }

        // The queue can be emptied underneath us by a disconnection while a
        // batch is in flight, so never remove more than is still there.
        _pending.removeRange(0, batch.length.clamp(0, _pending.length));
        changed = true;

        if (result == ScrobbleSubmission.rejected) {
          // Keep the rest of the queue: a single malformed listen must not
          // take the ones behind it down with it.
          continue;
        }

        _consecutiveFailures = 0;
        _nextAttempt = null;
      }
    } finally {
      _sending = false;
      if (changed) await _persist();
    }
  }

  /// Drops the backoff so the next [flush] goes out immediately, for when the
  /// user asks for a retry rather than waiting for one.
  void allowImmediateRetry() {
    _consecutiveFailures = 0;
    _nextAttempt = null;
  }

  Future<void> clear() async {
    await load();
    _pending.clear();
    _consecutiveFailures = 0;
    _nextAttempt = null;
    await _persist();
  }

  void _backOff(DateTime from) {
    _consecutiveFailures++;
    var delay =
        firstRetryDelay * (1 << (_consecutiveFailures - 1).clamp(0, 10));
    if (delay > maxRetryDelay) delay = maxRetryDelay;
    _nextAttempt = from.add(delay);
  }

  void _trim() {
    if (_pending.length <= maxLength) return;
    _pending.removeRange(0, _pending.length - maxLength);
  }

  Future<void> _persist() => store.write(
    storageKey,
    _pending.map((listen) => listen.toJson()).toList(),
  );
}
