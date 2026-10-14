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

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:musify/models/scrobble.dart';
import 'package:musify/services/scrobble_queue.dart';

/// Last.fm only talks to registered applications, and it signs every call with
/// a shared secret that belongs to the application, not to the user. An APK
/// anyone can unzip is no place for the maintainer's secret, and Musify has no
/// key of its own, so both halves are read from the build environment:
///
///     flutter build apk --dart-define=LASTFM_API_KEY=...
///                       --dart-define=LASTFM_API_SECRET=...
///
/// A build without them simply has no Last.fm entry in the settings, and
/// everything else — ListenBrainz included — works as usual.
const lastFmApiKey = String.fromEnvironment('LASTFM_API_KEY');
const lastFmApiSecret = String.fromEnvironment('LASTFM_API_SECRET');

bool get isLastFmSupported =>
    lastFmApiKey.isNotEmpty && lastFmApiSecret.isNotEmpty;

const lastFmApiRoot = 'https://ws.audioscrobbler.com/2.0/';
const lastFmAuthRoot = 'https://www.last.fm/api/auth/';

/// Error codes Last.fm documents as worth retrying.
const _lastFmServiceOffline = 11;
const _lastFmTemporarilyUnavailable = 16;
const _lastFmRateLimited = 29;

/// The session key the user revoked, or that was never valid.
const _lastFmInvalidSession = 9;

/// Signs a Last.fm call: every parameter except `format` sorted by name,
/// concatenated as name then value, the shared secret appended, the whole
/// thing hashed with MD5.
String lastFmApiSignature(Map<String, String> parameters, String secret) {
  final names = parameters.keys
      .where((name) => name != 'format' && name != 'callback')
      .toList()
    ..sort();

  final payload = StringBuffer();
  for (final name in names) {
    payload
      ..write(name)
      ..write(parameters[name]);
  }
  payload.write(secret);

  return md5.convert(utf8.encode(payload.toString())).toString();
}

/// A signed-in Last.fm account.
class LastFmSession {
  const LastFmSession({required this.username, required this.sessionKey});

  final String username;
  final String sessionKey;
}

/// Raised when Last.fm no longer accepts the stored session key, which only
/// signing in again can fix.
class LastFmSessionExpired implements Exception {
  const LastFmSessionExpired();
}

class LastFmClient {
  LastFmClient({http.Client? httpClient, this.apiRoot = lastFmApiRoot})
    : _httpClient = httpClient ?? http.Client();

  static const _timeout = Duration(seconds: 15);

  final String apiRoot;
  final http.Client _httpClient;

  /// Step one of the desktop sign-in: an unauthorized request token.
  Future<String?> requestToken() async {
    final body = await _call({'method': 'auth.getToken'});
    return body?['token']?.toString();
  }

  /// Step two: the page where the user approves Musify.
  Uri authorizationUrl(String token) =>
      Uri.parse('$lastFmAuthRoot?api_key=$lastFmApiKey&token=$token');

  /// Step three, once the user has approved the token in their browser.
  Future<LastFmSession?> createSession(String token) async {
    final body = await _call({'method': 'auth.getSession', 'token': token});
    final session = body?['session'];
    if (session is! Map) return null;

    final key = session['key']?.toString();
    final name = session['name']?.toString();
    if (key == null || name == null) return null;

    return LastFmSession(username: name, sessionKey: key);
  }

  Future<ScrobbleSubmission> scrobble(
    String sessionKey,
    List<Scrobble> listens,
  ) async {
    if (listens.isEmpty) return ScrobbleSubmission.accepted;

    final parameters = <String, String>{
      'method': 'track.scrobble',
      'sk': sessionKey,
    };
    for (var index = 0; index < listens.length; index++) {
      final listen = listens[index];
      parameters['artist[$index]'] = listen.artist;
      parameters['track[$index]'] = listen.title;
      parameters['timestamp[$index]'] = '${listen.timestamp}';
      if (listen.album != null) parameters['album[$index]'] = listen.album!;
      if (listen.duration != null) {
        parameters['duration[$index]'] = '${listen.duration!.inSeconds}';
      }
    }

    return _submit(parameters);
  }

  Future<ScrobbleSubmission> updateNowPlaying(
    String sessionKey,
    Scrobble listen,
  ) => _submit({
    'method': 'track.updateNowPlaying',
    'sk': sessionKey,
    'artist': listen.artist,
    'track': listen.title,
    if (listen.album != null) 'album': listen.album!,
    if (listen.duration != null) 'duration': '${listen.duration!.inSeconds}',
  });

  Future<ScrobbleSubmission> _submit(Map<String, String> parameters) async {
    try {
      final body = await _call(parameters);
      return body == null
          ? ScrobbleSubmission.rejected
          : ScrobbleSubmission.accepted;
    } on _LastFmError catch (error) {
      if (error.code == _lastFmInvalidSession) {
        throw const LastFmSessionExpired();
      }
      return error.retryable
          ? ScrobbleSubmission.retryLater
          : ScrobbleSubmission.rejected;
    }
  }

  /// Posts a signed call and returns its decoded body, or null when Last.fm
  /// answered something that is not a usable response.
  Future<Map<String, dynamic>?> _call(Map<String, String> parameters) async {
    final signed = {...parameters, 'api_key': lastFmApiKey}
      ..['api_sig'] = lastFmApiSignature({
        ...parameters,
        'api_key': lastFmApiKey,
      }, lastFmApiSecret)
      ..['format'] = 'json';

    final response = await _httpClient
        .post(Uri.parse(apiRoot), body: signed)
        .timeout(_timeout);

    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } on FormatException {
      body = null;
    }

    // A 200 is no proof of success: Last.fm reports failures in the body.
    final error = body?['error'];
    if (error != null) {
      final code = error is int ? error : int.tryParse('$error') ?? 0;
      throw _LastFmError(code, _isRetryable(code));
    }

    if (response.statusCode >= 500 || response.statusCode == 429) {
      throw const _LastFmError(0, true);
    }

    return response.statusCode == 200 ? body : null;
  }

  bool _isRetryable(int code) =>
      code == _lastFmServiceOffline ||
      code == _lastFmTemporarilyUnavailable ||
      code == _lastFmRateLimited;
}

class _LastFmError implements Exception {
  const _LastFmError(this.code, this.retryable);

  final int code;
  final bool retryable;
}
