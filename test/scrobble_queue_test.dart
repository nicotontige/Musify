import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/scrobble.dart';
import 'package:musify/services/scrobble_queue.dart';

/// The offline queue is what makes scrobbling usable in a car: listens have to
/// survive a dead connection and be offered again later, without hammering the
/// service in between.
void main() {
  Scrobble listenAt(int second) => Scrobble(
    title: 'Track $second',
    artist: 'Daft Punk',
    playedAt: DateTime.fromMillisecondsSinceEpoch(second * 1000, isUtc: true),
  );

  test('keeps a listen across restarts', () async {
    final store = _MemoryStore();
    await ScrobbleQueue('q', store: store).add(listenAt(1));

    final restarted = ScrobbleQueue('q', store: store);
    await restarted.load();

    expect(restarted.length, 1);
    expect(store.written['q'], hasLength(1));
  });

  test('drops the oldest listens once it is full', () async {
    final queue = ScrobbleQueue('q', store: _MemoryStore());
    for (var second = 0; second < ScrobbleQueue.maxLength + 5; second++) {
      await queue.add(listenAt(second));
    }

    expect(queue.length, ScrobbleQueue.maxLength);

    final service = _FakeService();
    await queue.flush(service.send);
    expect(service.sent.first.timestamp, 5);
  });

  test('submits in batches, oldest first, and empties the queue', () async {
    final store = _MemoryStore();
    final queue = ScrobbleQueue('q', store: store);
    for (var second = 0; second < 120; second++) {
      await queue.add(listenAt(second));
    }

    final service = _FakeService();
    await queue.flush(service.send);

    expect(service.batches.map((batch) => batch.length), [50, 50, 20]);
    expect(service.sent.first.timestamp, 0);
    expect(service.sent.last.timestamp, 119);
    expect(queue.length, 0);
    expect(store.written['q'], isEmpty);
  });

  test('keeps the listens the service could not take', () async {
    final queue = ScrobbleQueue('q', store: _MemoryStore());
    await queue.add(listenAt(1));

    final service = _FakeService()..answer = ScrobbleSubmission.retryLater;
    await queue.flush(service.send);

    expect(queue.length, 1);
    expect(service.batches, hasLength(1));
  });

  test('waits before trying again, then retries', () async {
    final queue = ScrobbleQueue('q', store: _MemoryStore());
    await queue.add(listenAt(1));

    final service = _FakeService()..answer = ScrobbleSubmission.retryLater;
    final start = DateTime(2026);
    await queue.flush(service.send, now: start);

    // Too soon: the service is left alone.
    await queue.flush(service.send, now: start.add(const Duration(seconds: 30)));
    expect(service.batches, hasLength(1));

    service.answer = ScrobbleSubmission.accepted;
    await queue.flush(service.send, now: start.add(const Duration(minutes: 2)));
    expect(service.batches, hasLength(2));
    expect(queue.length, 0);
  });

  test('the backoff grows with each failure', () async {
    final queue = ScrobbleQueue('q', store: _MemoryStore());
    await queue.add(listenAt(1));

    final service = _FakeService()..answer = ScrobbleSubmission.retryLater;
    final start = DateTime(2026);
    await queue.flush(service.send, now: start);
    final firstDelay = queue.nextAttempt!.difference(start);

    final second = start.add(firstDelay);
    await queue.flush(service.send, now: second);
    final secondDelay = queue.nextAttempt!.difference(second);

    expect(firstDelay, ScrobbleQueue.firstRetryDelay);
    expect(secondDelay, greaterThan(firstDelay));
    expect(secondDelay, lessThanOrEqualTo(ScrobbleQueue.maxRetryDelay));
  });

  test('a retry asked for by the user ignores the backoff', () async {
    final queue = ScrobbleQueue('q', store: _MemoryStore());
    await queue.add(listenAt(1));

    final service = _FakeService()..answer = ScrobbleSubmission.retryLater;
    final start = DateTime(2026);
    await queue.flush(service.send, now: start);

    queue.allowImmediateRetry();
    service.answer = ScrobbleSubmission.accepted;
    await queue.flush(service.send, now: start);

    expect(service.batches, hasLength(2));
    expect(queue.length, 0);
  });

  test('drops what the service will never accept', () async {
    final queue = ScrobbleQueue('q', store: _MemoryStore());
    await queue.add(listenAt(1));

    final service = _FakeService()..answer = ScrobbleSubmission.rejected;
    await queue.flush(service.send);

    expect(queue.length, 0);
  });

  test('clears everything when an account is disconnected', () async {
    final store = _MemoryStore();
    final queue = ScrobbleQueue('q', store: store);
    await queue.add(listenAt(1));

    await queue.clear();

    expect(queue.length, 0);
    expect(store.written['q'], isEmpty);
  });
}

class _MemoryStore implements ScrobbleStore {
  final Map<String, List<Map<String, dynamic>>> written = {};

  @override
  Future<List<dynamic>> read(String key) async => written[key] ?? const [];

  @override
  Future<void> write(String key, List<Map<String, dynamic>> listens) async {
    written[key] = listens;
  }
}

class _FakeService {
  final List<List<Scrobble>> batches = [];
  ScrobbleSubmission answer = ScrobbleSubmission.accepted;

  List<Scrobble> get sent => batches.expand((batch) => batch).toList();

  Future<ScrobbleSubmission> send(List<Scrobble> batch) async {
    batches.add(batch);
    return answer;
  }
}
