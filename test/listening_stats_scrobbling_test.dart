import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musify/services/listening_stats_service.dart';
import 'package:musify/services/scrobbling_service.dart';
import 'package:musify/services/settings_manager.dart';

/// Scrobbling hangs off the listening session, not off the audio handler, and
/// it has to work even when the local listening stats are turned off.
void main() {
  late Directory dir;
  const song = {'ytid': 'aaa', 'title': 'One More Time', 'artist': 'Daft Punk'};

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('musify_scrobble_test');
    Hive.init(dir.path);
    await Hive.openBox('settings');
    await Hive.openBox('user');
    // Local stats off: only the scrobbling side keeps the session alive.
    wrappedEnabled.value = false;
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  ({ListeningStatsService service, _FakeReporter reporter}) build({
    bool isActive = true,
  }) {
    final reporter = _FakeReporter(isActive);
    return (
      service: ListeningStatsService()..scrobbleReporter = reporter,
      reporter: reporter,
    );
  }

  test('announces the track as soon as it starts', () {
    final (:service, :reporter) = build();
    service.startListeningSession(song, duration: const Duration(minutes: 5));

    expect(reporter.nowPlaying, hasLength(1));
    expect(reporter.nowPlaying.single['title'], 'One More Time');
    expect(reporter.listens, isEmpty);
  });

  test('scrobbles once, with the time playback started', () {
    final (:service, :reporter) = build();
    final startedAt = DateTime.now().subtract(const Duration(minutes: 5));

    service
      ..startListeningSession(
        song,
        duration: const Duration(minutes: 10),
        startedAt: startedAt,
      )
      ..recordListeningSessionProgress(wasPlaying: true);

    expect(reporter.listens, hasLength(1));
    expect(reporter.listens.single, startedAt);

    service.recordListeningSessionProgress(wasPlaying: true);
    expect(reporter.listens, hasLength(1));

    // Nothing was recorded locally: that setting is off.
    expect(service.hasStats, isFalse);
  });

  test('says nothing before the track has been played enough', () {
    final (:service, :reporter) = build();

    service
      ..startListeningSession(
        song,
        duration: const Duration(minutes: 10),
        startedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      )
      ..recordListeningSessionProgress(wasPlaying: true);

    expect(reporter.listens, isEmpty);
  });

  test('never scrobbles a track shorter than 30 seconds', () {
    final (:service, :reporter) = build();

    service
      ..startListeningSession(
        song,
        duration: const Duration(seconds: 20),
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      )
      ..recordListeningSessionProgress(wasPlaying: true);

    expect(reporter.listens, isEmpty);
  });

  test('a new play of the same track is scrobbled again', () {
    final (:service, :reporter) = build();
    final firstStart = DateTime.now().subtract(const Duration(minutes: 20));
    final secondStart = DateTime.now().subtract(const Duration(minutes: 10));

    service
      ..startListeningSession(
        song,
        duration: const Duration(minutes: 10),
        startedAt: firstStart,
      )
      ..recordListeningSessionProgress(wasPlaying: true)
      ..finishListeningSession(flushStats: false)
      ..startListeningSession(
        song,
        duration: const Duration(minutes: 10),
        startedAt: secondStart,
      )
      ..recordListeningSessionProgress(wasPlaying: true);

    expect(reporter.listens, [firstStart, secondStart]);
  });

  test('nothing happens without a connected account', () {
    final (:service, :reporter) = build(isActive: false);

    service
      ..startListeningSession(
        song,
        duration: const Duration(minutes: 10),
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      )
      ..recordListeningSessionProgress(wasPlaying: true);

    expect(reporter.nowPlaying, isEmpty);
    expect(reporter.listens, isEmpty);
  });
}

class _FakeReporter implements ScrobbleReporter {
  _FakeReporter(this.isActive);

  @override
  final bool isActive;

  final List<Map> nowPlaying = [];
  final List<DateTime> listens = [];

  @override
  void reportNowPlaying(Map song, {Duration? duration}) {
    nowPlaying.add(song);
  }

  @override
  void reportListen(Map song, {required DateTime startedAt, Duration? duration}) {
    listens.add(startedAt);
  }
}
