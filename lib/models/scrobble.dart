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

import 'package:musify/utilities/media_duration.dart';

/// A single listen, ready to be handed to a scrobbling service.
///
/// Instances are persisted in the offline queue, so [toJson] and
/// [Scrobble.fromJson] have to keep reading what earlier versions wrote.
class Scrobble {
  const Scrobble({
    required this.title,
    required this.artist,
    required this.playedAt,
    this.album,
    this.duration,
  });

  factory Scrobble.fromJson(Map json) {
    final playedAt = json['playedAt'];
    return Scrobble(
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      playedAt: DateTime.fromMillisecondsSinceEpoch(
        (playedAt is int ? playedAt : int.tryParse('$playedAt') ?? 0) * 1000,
        isUtc: true,
      ),
      album: json['album']?.toString(),
      duration: readMediaDuration(json['duration']),
    );
  }

  /// Builds a listen out of a Musify song map.
  ///
  /// Returns null for anything that cannot be scrobbled: live streams have no
  /// track boundaries, and both services reject a listen without an artist.
  static Scrobble? fromSong(
    Map song, {
    required DateTime playedAt,
    Duration? duration,
  }) {
    if (song['isLive'] == true) return null;

    final title = _cleanField(song['title']);
    final artist =
        _cleanArtist(song['artist']) ?? _cleanArtist(song['videoAuthor']);
    if (title == null || artist == null) return null;

    return Scrobble(
      title: title,
      artist: artist,
      playedAt: playedAt,
      album: _cleanField(song['album']),
      duration: duration ?? readMediaDuration(song['duration']),
    );
  }

  final String title;
  final String artist;
  final DateTime playedAt;
  final String? album;
  final Duration? duration;

  /// Seconds since the Unix epoch, which is what both services expect.
  int get timestamp => playedAt.toUtc().millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'playedAt': timestamp,
    if (album != null) 'album': album,
    if (duration != null) 'duration': duration!.inSeconds,
  };

  @override
  String toString() => '$artist - $title (@$timestamp)';
}

/// Song maps carry stringified values, so an absent album arrives as the
/// text 'null' rather than as null.
String? _cleanField(dynamic value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text == 'null') return null;
  return text;
}

/// YouTube Music credits a release to a topic channel ('Daft Punk - Topic');
/// neither service knows that artist.
String? _cleanArtist(dynamic value) {
  final text = _cleanField(value);
  if (text == null) return null;

  const topicSuffix = ' - topic';
  if (text.toLowerCase().endsWith(topicSuffix)) {
    final stripped = text.substring(0, text.length - topicSuffix.length).trim();
    return stripped.isEmpty ? null : stripped;
  }

  return text;
}
