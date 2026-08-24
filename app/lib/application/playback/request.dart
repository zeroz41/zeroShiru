/// What the user explicitly asked to watch, carried from the click that started
/// playback to the moment the resolved file list arrives.
///
/// Port of `frontend/common/modules/playback/request.js`. Why this exists: the
/// player re-derives which episode to play from the file list using watch status
/// (currently watching -> progress + 1, otherwise the lowest unwatched episode
/// present). That is the right answer when playback starts itself, and the wrong
/// one when the user named an episode. It bit hardest on debrid, where the
/// resolved list is a window centred on the wanted episode: the lowest episode in
/// a 12 file window is the wanted one minus six, so picking episode 10 played
/// episode 4 and picking 24 played 18.
library;

/// The episode the user asked for, and which show they asked it of.
class PlayRequest {
  const PlayRequest({required this.episode, this.mediaId});

  /// The episode the user asked for. A number, or a string still carrying the
  /// UI's spelling — matching always goes through numeric coercion.
  final Object? episode;

  /// AniList id, when the request came from a media page.
  final int? mediaId;
}

/// A video file with its resolved media attached, shaped like the ones the
/// player's `handleFiles` works on.
class ResolvedFile {
  const ResolvedFile({this.name, this.media});

  final String? name;
  final ResolvedFileMedia? media;
}

/// What resolution said about one file. [mediaId] is null when the file's media
/// never resolved — such a file is still a candidate for the release the user
/// just asked to play.
class ResolvedFileMedia {
  const ResolvedFileMedia({
    this.mediaId,
    this.episode,
    this.parsedEpisode,
    this.episodeRange,
  });

  /// The resolved AniList media id (`media.media.id` in the JS shape).
  final int? mediaId;

  /// The resolver's episode, in AniList's numbering (season offsets applied).
  /// A number or a string.
  final Object? episode;

  /// The raw parsed episode number off the file name
  /// (`parseObject.episode_number`), used when the resolver left no episode.
  final Object? parsedEpisode;

  /// The span a multi-episode file covers, which is how batched releases play.
  final EpisodeRange? episodeRange;
}

class EpisodeRange {
  const EpisodeRange(this.first, this.last);

  final num first;
  final num last;
}

/// The pending explicit request, or null when playback is choosing for itself.
class PlayRequestStore {
  PlayRequest? value;
}

final PlayRequestStore playRequest = PlayRequestStore();

/// Records what a play request asked for, or clears it when it asked for nothing
/// in particular. Called for every play, so a request never outlives the
/// playback it describes.
void requestPlayback({Object? episode, int? mediaId}) {
  final parsed = _finite(episode);
  playRequest.value = parsed == null
      ? null
      : PlayRequest(episode: parsed, mediaId: mediaId);
}

/// The file that serves an explicit request, or null when nothing does — in
/// which case playback falls back to choosing for itself, exactly as it did
/// before a request was ever recorded.
ResolvedFile? matchRequestedFile(
  List<ResolvedFile>? files,
  PlayRequest? request,
) {
  if (request == null || files == null || files.isEmpty) return null;
  final episode = _finite(request.episode);
  if (episode == null) return null;
  // a file whose media did not resolve is still a candidate: it belongs to the
  // release the user just asked to play, and refusing it would fall back to a
  // worse guess
  final candidates = files.where(_sameMedia(request)).toList();
  return _firstWhereOrNull(
        candidates,
        (file) => _finite(file.media?.episode) == episode,
      ) ??
      _firstWhereOrNull(
        candidates,
        (file) => _finite(file.media?.parsedEpisode) == episode,
      ) ??
      // a file holding several episodes serves any of them, which is how
      // batched releases play
      _firstWhereOrNull(
        candidates,
        (file) => _covers(file.media?.episodeRange, episode),
      );
}

bool _covers(EpisodeRange? range, double episode) {
  if (range == null) return false;
  final first = _finite(range.first);
  final last = _finite(range.last);
  return first != null && last != null && first <= episode && episode <= last;
}

/// Why a release cannot serve an explicit request, or null when it can — or when
/// there is not enough evidence to say so, in which case playback chooses for
/// itself as it always did.
///
/// A pack almost always carries something unnumbered — an extra, a special, a
/// file whose name defeats the parser — so requiring every file to be numbered
/// meant a single such file let a pack of episode 1085 onwards play episode 1085
/// to somebody who asked for 28. What the numbered files say is evidence enough.
///
/// This is the authoritative check, and it lives here rather than in the debrid
/// picker because this is the point where every file has been through the
/// resolver: episode numbers are in AniList's terms, season offsets applied, so
/// a release numbered 13-24 that really does hold episode 1 has already been
/// recognised as holding it. What is left is proof.
///
/// The case it was written for: `[F-R] One Piece 0487+0490`, a two episode fix
/// release. Asked for episode 10 it matched nothing, so playback fell back to
/// the lowest episode present and played 487 — whichever episode had been asked
/// for.
String? describeMissingEpisode(
  List<ResolvedFile>? files,
  PlayRequest? request,
) {
  if (request == null || files == null || files.isEmpty) return null;
  final episode = _finite(request.episode);
  if (episode == null) return null;
  final candidates = files.where(_sameMedia(request)).toList();
  // nothing here is the show that was asked for, which resolution failures
  // alone can explain
  if (candidates.isEmpty) return null;
  if (matchRequestedFile(candidates, request) != null) return null;
  final held = [for (final file in candidates) ..._episodesOf(file)];
  // nothing here could be numbered at all, so the release says nothing about
  // what it holds
  if (held.isEmpty) return null;
  final sorted = held.toSet().toList()..sort();
  return 'This release holds ${_listEpisodes(sorted)}, '
      'not episode ${_plain(episode)}. Choose another release.';
}

bool Function(ResolvedFile) _sameMedia(PlayRequest request) =>
    (file) =>
        request.mediaId == null ||
        file.media?.mediaId == null ||
        file.media?.mediaId == request.mediaId;

/// Every episode a resolved file answers to.
List<double> _episodesOf(ResolvedFile file) {
  final range = file.media?.episodeRange;
  final first = _finite(range?.first);
  final last = _finite(range?.last);
  if (first != null && last != null && last >= first) {
    // spelled out so a listing reads honestly, unless the span is too wide to
    // be worth it
    if (last - first <= 50) {
      return [
        for (var index = 0; index <= (last - first).round(); index++)
          first + index,
      ];
    }
    return [first, last];
  }
  final episode =
      _finite(file.media?.episode) ?? _finite(file.media?.parsedEpisode);
  return episode == null ? const [] : [episode];
}

/// Names what a release holds the way a person would: a run reads as a range,
/// gaps are spelled out, since "487-490" would claim two episodes this release
/// does not have.
String _listEpisodes(List<double> episodes) {
  if (episodes.length == 1) return 'episode ${_plain(episodes.first)}';
  var contiguous = true;
  for (var index = 1; index < episodes.length; index++) {
    if (episodes[index] != episodes[index - 1] + 1) {
      contiguous = false;
      break;
    }
  }
  if (contiguous) {
    return 'episodes ${_plain(episodes.first)}-${_plain(episodes.last)}';
  }
  if (episodes.length <= 6) {
    final head = episodes
        .sublist(0, episodes.length - 1)
        .map(_plain)
        .join(', ');
    return 'episodes $head and ${_plain(episodes.last)}';
  }
  final head = episodes.sublist(0, 5).map(_plain).join(', ');
  return 'episodes $head and ${episodes.length - 5} more, '
      'but not every episode in between';
}

String _plain(double value) => value == value.truncateToDouble()
    ? value.truncate().toString()
    : value.toString();

/// Numeric coercion the way the JS reads episode fields: numbers pass through,
/// strings parse ("09" is 9), anything else — arrays, nulls, junk — is nothing.
double? _finite(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}

T? _firstWhereOrNull<T>(List<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}
