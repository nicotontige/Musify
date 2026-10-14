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

import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:musify/main.dart' show logger;
import 'package:musify/models/scrobble.dart';
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/lastfm_client.dart';
import 'package:musify/services/listenbrainz_client.dart';
import 'package:musify/services/scrobble_queue.dart';
import 'package:musify/services/settings_manager.dart';

final scrobblingService = ScrobblingService();

/// What the listening session needs from the scrobbling side, kept narrow so
/// the session bookkeeping can be tested without any of it.
abstract class ScrobbleReporter {
  /// Whether anything at all would be sent. Nothing leaves the device until
  /// the user has connected an account and left scrobbling on.
  bool get isActive;

  /// Playback of [song] has just started.
  void reportNowPlaying(Map song, {Duration? duration});

  /// [song] has been played long enough to count as a listen. [startedAt] is
  /// when its playback began, which is the timestamp both services record.
  void reportListen(
    Map song, {
    required DateTime startedAt,
    Duration? duration,
  });
}

/// Sends the listening history to Last.fm and/or ListenBrainz.
///
/// Nothing here is ever awaited by the player: a listen is queued on disk and
/// the network is dealt with afterwards, so a dead connection costs playback
/// nothing.
class ScrobblingService implements ScrobbleReporter {
  ScrobblingService({
    LastFmClient? lastFmClient,
    ListenBrainzClient? listenBrainzClient,
    ScrobbleStore store = const HiveScrobbleStore(),
  }) : _lastFm = lastFmClient ?? LastFmClient(),
       _listenBrainz = listenBrainzClient ?? ListenBrainzClient(),
       _lastFmQueue = ScrobbleQueue(lastFmQueueKey, store: store),
       _listenBrainzQueue = ScrobbleQueue(listenBrainzQueueKey, store: store);

  static const credentialsBox = 'userNoBackup';
  static const lastFmSessionKeyKey = 'lastFmSessionKey';
  static const lastFmUsernameKey = 'lastFmUsername';
  static const listenBrainzTokenKey = 'listenBrainzToken';
  static const listenBrainzUsernameKey = 'listenBrainzUsername';
  static const lastFmQueueKey = 'lastFmScrobbleQueue';
  static const listenBrainzQueueKey = 'listenBrainzScrobbleQueue';

  final LastFmClient _lastFm;
  final ListenBrainzClient _listenBrainz;
  final ScrobbleQueue _lastFmQueue;
  final ScrobbleQueue _listenBrainzQueue;

  /// The accounts, for the settings screen to watch.
  final ValueNotifier<String?> lastFmUsername = ValueNotifier(null);
  final ValueNotifier<String?> listenBrainzUsername = ValueNotifier(null);

  /// Listens still waiting for a working connection.
  final ValueNotifier<int> pendingListens = ValueNotifier(0);

  // Credentials sit in a plain Hive box, like every other piece of state in
  // Musify. There is no secure storage in the project and adding one for this
  // would pull in a sizable dependency: a Last.fm session key is worth no more
  // than the listening history it writes, and anything able to read the app's
  // own files can read the history too.
  String? _lastFmSessionKey;
  String? _listenBrainzToken;
  String? _pendingLastFmToken;
  bool _loaded = false;

  bool get hasLastFm => _lastFmSessionKey != null;
  bool get hasListenBrainz => _listenBrainzToken != null;

  @override
  bool get isActive {
    _ensureLoaded();
    return scrobblingEnabled.value && (hasLastFm || hasListenBrainz);
  }

  /// Reads the stored accounts. Safe to call repeatedly; the settings screen
  /// uses it to make sure the notifiers are populated before it builds.
  void loadFromStorage() {
    _loaded = true;
    try {
      final box = Hive.box(credentialsBox);
      _lastFmSessionKey = isLastFmSupported
          ? box.get(lastFmSessionKeyKey)?.toString()
          : null;
      _listenBrainzToken = box.get(listenBrainzTokenKey)?.toString();
      lastFmUsername.value = _lastFmSessionKey == null
          ? null
          : box.get(lastFmUsernameKey)?.toString();
      listenBrainzUsername.value = _listenBrainzToken == null
          ? null
          : box.get(listenBrainzUsernameKey)?.toString();
    } catch (e, stackTrace) {
      logger.log(
        'Error reading scrobbling credentials',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void reportNowPlaying(Map song, {Duration? duration}) {
    if (!isActive) return;

    final listen = Scrobble.fromSong(
      song,
      playedAt: DateTime.now(),
      duration: duration,
    );
    if (listen == null) return;

    // A missed now playing update is not worth retrying: by the time it could
    // be sent again the track is no longer the one playing.
    if (hasLastFm) {
      unawaited(
        _guard(() => _lastFm.updateNowPlaying(_lastFmSessionKey!, listen)),
      );
    }
    if (hasListenBrainz) {
      unawaited(
        _guard(
          () => _listenBrainz.updateNowPlaying(_listenBrainzToken!, listen),
        ),
      );
    }

    // A new track is a good moment to find out the network came back.
    unawaited(submitPending());
  }

  @override
  void reportListen(
    Map song, {
    required DateTime startedAt,
    Duration? duration,
  }) {
    if (!isActive) return;

    final listen = Scrobble.fromSong(
      song,
      playedAt: startedAt,
      duration: duration,
    );
    if (listen == null) return;

    unawaited(_enqueue(listen));
  }

  /// Offers every queued listen to the services that are connected.
  Future<void> submitPending() async {
    if (!isActive) return;

    if (hasLastFm) {
      await _lastFmQueue.flush(
        (batch) => _guard(() => _lastFm.scrobble(_lastFmSessionKey!, batch)),
      );
    }
    if (hasListenBrainz) {
      await _listenBrainzQueue.flush(
        (batch) => _guard(
          () => _listenBrainz.submitListens(_listenBrainzToken!, batch),
        ),
      );
    }
    _publishPendingCount();
  }

  /// Sends the backlog right away, ignoring the backoff, after the user asked
  /// for it from the settings screen.
  Future<void> submitPendingNow() async {
    _lastFmQueue.allowImmediateRetry();
    _listenBrainzQueue.allowImmediateRetry();
    await submitPending();
  }

  Future<void> refreshPendingCount() async {
    await _lastFmQueue.load();
    await _listenBrainzQueue.load();
    _publishPendingCount();
  }

  /// Step one of the Last.fm sign-in: the page the user has to approve.
  Future<Uri?> beginLastFmSignIn() async {
    if (!isLastFmSupported) return null;

    try {
      final token = await _lastFm.requestToken();
      if (token == null) return null;

      _pendingLastFmToken = token;
      return _lastFm.authorizationUrl(token);
    } catch (e, stackTrace) {
      logger.log(
        'Error starting Last.fm sign-in',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Step two, once the user says they approved it.
  Future<bool> completeLastFmSignIn() async {
    final token = _pendingLastFmToken;
    if (token == null) return false;

    try {
      final session = await _lastFm.createSession(token);
      if (session == null) return false;

      _pendingLastFmToken = null;
      _lastFmSessionKey = session.sessionKey;
      lastFmUsername.value = session.username;
      await addOrUpdateData<String>(
        credentialsBox,
        lastFmSessionKeyKey,
        session.sessionKey,
      );
      await addOrUpdateData<String>(
        credentialsBox,
        lastFmUsernameKey,
        session.username,
      );
      await _enableScrobbling();
      unawaited(submitPending());
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error signing in to Last.fm',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> disconnectLastFm() async {
    _lastFmSessionKey = null;
    _pendingLastFmToken = null;
    lastFmUsername.value = null;
    await deleteData(credentialsBox, lastFmSessionKeyKey);
    await deleteData(credentialsBox, lastFmUsernameKey);
    await _lastFmQueue.clear();
    _publishPendingCount();
  }

  /// Connects ListenBrainz with the token the user copied from their account
  /// page. Returns false when ListenBrainz does not recognise it.
  Future<bool> connectListenBrainz(String token) async {
    try {
      final username = await _listenBrainz.validateToken(token.trim());
      if (username == null) return false;

      _listenBrainzToken = token.trim();
      listenBrainzUsername.value = username;
      await addOrUpdateData<String>(
        credentialsBox,
        listenBrainzTokenKey,
        _listenBrainzToken!,
      );
      await addOrUpdateData<String>(
        credentialsBox,
        listenBrainzUsernameKey,
        username,
      );
      await _enableScrobbling();
      unawaited(submitPending());
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error connecting to ListenBrainz',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> disconnectListenBrainz() async {
    _listenBrainzToken = null;
    listenBrainzUsername.value = null;
    await deleteData(credentialsBox, listenBrainzTokenKey);
    await deleteData(credentialsBox, listenBrainzUsernameKey);
    await _listenBrainzQueue.clear();
    _publishPendingCount();
  }

  Future<void> _enqueue(Scrobble listen) async {
    try {
      if (hasLastFm) await _lastFmQueue.add(listen);
      if (hasListenBrainz) await _listenBrainzQueue.add(listen);
      _publishPendingCount();
      await submitPending();
    } catch (e, stackTrace) {
      logger.log('Error queueing a listen', error: e, stackTrace: stackTrace);
    }
  }

  /// Turns the network side of a submission into a queue verdict. Anything
  /// unexpected is treated as temporary: a listen is only ever dropped on an
  /// answer that says it will never be accepted.
  Future<ScrobbleSubmission> _guard(
    Future<ScrobbleSubmission> Function() send,
  ) async {
    try {
      return await send();
    } on LastFmSessionExpired {
      logger.log('Last.fm session key was rejected, signing out');
      await disconnectLastFm();
      return ScrobbleSubmission.retryLater;
    } catch (e, stackTrace) {
      logger.log('Error submitting a listen', error: e, stackTrace: stackTrace);
      return ScrobbleSubmission.retryLater;
    }
  }

  Future<void> _enableScrobbling() async {
    if (scrobblingEnabled.value) return;
    scrobblingEnabled.value = true;
    await addOrUpdateData<bool>('settings', 'scrobblingEnabled', true);
  }

  void _ensureLoaded() {
    if (!_loaded) loadFromStorage();
  }

  void _publishPendingCount() {
    pendingListens.value = _lastFmQueue.length + _listenBrainzQueue.length;
  }
}
