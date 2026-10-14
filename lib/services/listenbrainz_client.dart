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

import 'package:http/http.dart' as http;
import 'package:musify/constants/version.dart';
import 'package:musify/models/scrobble.dart';
import 'package:musify/services/scrobble_queue.dart';

const listenBrainzApiRoot = 'https://api.listenbrainz.org';
const listenBrainzSettingsUrl = 'https://listenbrainz.org/settings/';

/// The ListenBrainz half of the scrobbling support.
///
/// ListenBrainz asks for nothing but a user token, which the user copies from
/// their own settings page, so this path works in any build of Musify.
class ListenBrainzClient {
  ListenBrainzClient({
    http.Client? httpClient,
    this.apiRoot = listenBrainzApiRoot,
  }) : _httpClient = httpClient ?? http.Client();

  static const _timeout = Duration(seconds: 15);

  final String apiRoot;
  final http.Client _httpClient;

  /// Returns the user name the token belongs to, or null when it is refused.
  Future<String?> validateToken(String token) async {
    final response = await _httpClient
        .get(
          Uri.parse('$apiRoot/1/validate-token'),
          headers: {'Authorization': 'Token $token'},
        )
        .timeout(_timeout);

    if (response.statusCode != 200) return null;

    final body = jsonDecode(response.body);
    if (body is! Map || body['valid'] != true) return null;

    return body['user_name']?.toString();
  }

  Future<ScrobbleSubmission> submitListens(
    String token,
    List<Scrobble> listens,
  ) async {
    if (listens.isEmpty) return ScrobbleSubmission.accepted;

    return _submit(token, {
      'listen_type': listens.length == 1 ? 'single' : 'import',
      'payload': [
        for (final listen in listens)
          {
            'listened_at': listen.timestamp,
            'track_metadata': _metadata(listen),
          },
      ],
    });
  }

  /// A playing-now payload carries no timestamp and is never retried: it is
  /// only worth sending while the track is actually playing.
  Future<ScrobbleSubmission> updateNowPlaying(
    String token,
    Scrobble listen,
  ) => _submit(token, {
    'listen_type': 'playing_now',
    'payload': [
      {'track_metadata': _metadata(listen)},
    ],
  });

  Future<ScrobbleSubmission> _submit(
    String token,
    Map<String, dynamic> body,
  ) async {
    final response = await _httpClient
        .post(
          Uri.parse('$apiRoot/1/submit-listens'),
          headers: {
            'Authorization': 'Token $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    final status = response.statusCode;
    if (status == 200) return ScrobbleSubmission.accepted;
    // 400 is a malformed listen and 401 a token the user has revoked; neither
    // gets better by being sent again.
    if (status == 400 || status == 401 || status == 403) {
      return ScrobbleSubmission.rejected;
    }
    return ScrobbleSubmission.retryLater;
  }

  Map<String, dynamic> _metadata(Scrobble listen) => {
    'artist_name': listen.artist,
    'track_name': listen.title,
    if (listen.album != null) 'release_name': listen.album,
    'additional_info': {
      'media_player': 'Musify',
      'submission_client': 'Musify',
      'submission_client_version': appVersion,
      if (listen.duration != null)
        'duration_ms': listen.duration!.inMilliseconds,
    },
  };
}
