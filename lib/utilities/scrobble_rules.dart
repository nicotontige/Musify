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

/// The rules both Last.fm and ListenBrainz ask clients to follow before a play
/// counts as a listen:
///
///  - a track shorter than 30 seconds is never scrobbled;
///  - a track is scrobbled once half of it, or four minutes, has been played,
///    whichever comes first.
const minimumScrobbleTrackDuration = Duration(seconds: 30);
const maximumScrobbleThreshold = Duration(minutes: 4);

/// How long [trackDuration] has to be played before it can be scrobbled, or
/// null when it never can be.
///
/// Musify does not always know how long a track is before it has been played:
/// an unknown duration falls back to the four-minute ceiling, which is long
/// enough that no 30-second clip can reach it.
Duration? scrobbleThreshold(Duration? trackDuration) {
  if (trackDuration == null || trackDuration <= Duration.zero) {
    return maximumScrobbleThreshold;
  }

  if (trackDuration < minimumScrobbleTrackDuration) return null;

  final half = Duration(microseconds: trackDuration.inMicroseconds ~/ 2);
  return half < maximumScrobbleThreshold ? half : maximumScrobbleThreshold;
}

/// Whether [listened] of playback is enough to scrobble a [trackDuration] long
/// track.
bool isScrobbleEligible({
  required Duration listened,
  required Duration? trackDuration,
}) {
  final threshold = scrobbleThreshold(trackDuration);
  return threshold != null && listened >= threshold;
}
