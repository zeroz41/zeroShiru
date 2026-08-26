/// Episode picking for season packs: which file of a pack the player actually gets.
///
/// Faithful port of `crates/core/src/pick.rs`. The parser is injected so callers
/// can supply their own, but nobody has to — [pickPack] reads names with the
/// shared filename recognizer, so picking is one call with no host round trip.
library;

import 'filename.dart';

/// One file of a release: its path inside the torrent and its size in bytes.
class PackFile {
  const PackFile(this.path, this.size);

  final String path;
  final int size;
}

/// What the injected parser said about one file name. [episodeNumbers] holds every
/// finite number the name answers to ("01-12" parses to [1, 12]); [isExtra] is the
/// anitomy anime_type flag (NCOP/NCED/OVA/special).
class ParsedName {
  const ParsedName({
    this.episodeNumbers = const [],
    this.episodeSpans = const [],
    this.isExtra = false,
  });

  final List<double> episodeNumbers;
  final List<FilenameEpisodeSpan> episodeSpans;
  final bool isExtra;
}

/// Reads the video files' bare names in order and answers with one entry per
/// name (null per entry = that name failed to parse; a throw = the parser broke).
typedef PackParser = List<ParsedName?> Function(List<String> names);

/// The release provably does not contain the requested episode: every video file
/// parsed to an episode number and none of them covers it. Raised instead of
/// guessing, because the guess used to be "largest file" — asking a 459-516 pack
/// for episode 23 played episode 475.
abstract class EpisodeSelectionFailure implements Exception {
  const EpisodeSelectionFailure();

  String get message;

  @override
  String toString() => message;
}

class EpisodeNotInPack extends EpisodeSelectionFailure {
  const EpisodeNotInPack({
    required this.episode,
    required this.first,
    required this.last,
  });

  final double episode;
  final double first;
  final double last;

  @override
  String get message =>
      'This release holds ${_spanText(first, last)}, not episode ${_plain(episode)}. '
      'Pick a release that has it.';

  @override
  bool operator ==(Object other) =>
      other is EpisodeNotInPack &&
      other.episode == episode &&
      other.first == first &&
      other.last == last;

  @override
  int get hashCode => Object.hash(episode, first, last);
}

/// The requested episode could not be identified without guessing. This is
/// distinct from [EpisodeNotInPack]: some file names were unnumbered or the
/// parser failed, so the release's true span is unknown, but playing the
/// largest video would still be unsafe.
class EpisodeNotIdentified extends EpisodeSelectionFailure {
  const EpisodeNotIdentified(this.episode);

  final double episode;

  @override
  String get message =>
      'This release does not identify a safe file for episode ${_plain(episode)}. '
      'Pick a release whose files are numbered.';
}

String _spanText(double first, double last) => first == last
    ? 'episode ${_plain(first)}'
    : 'episodes ${_plain(first)}-${_plain(last)}';

/// Formats an episode number the way Rust's f64 Display does: no trailing `.0`.
String _plain(double value) => value == value.truncateToDouble()
    ? value.truncate().toString()
    : value.toString();

enum _Match { exact, range }

/// Whether a file's episode numbers cover the requested episode. More than one
/// number means a multi-episode file, which counts as a range containing
/// everything between.
_Match? _matchesEpisode(ParsedName? entry, double episode) {
  final spans = entry?.episodeSpans ?? const <FilenameEpisodeSpan>[];
  if (spans.isNotEmpty) {
    for (final span in spans) {
      if (!span.contains(episode)) continue;
      return span.first == span.last ? _Match.exact : _Match.range;
    }
    return null;
  }
  final numbers = entry?.episodeNumbers ?? const <double>[];
  if (numbers.isEmpty) return null;
  if (numbers.length == 1) {
    return numbers.first == episode ? _Match.exact : null;
  }
  final min = numbers.reduce((a, b) => a < b ? a : b);
  final max = numbers.reduce((a, b) => a > b ? a : b);
  return min <= episode && episode <= max ? _Match.range : null;
}

/// Picks the requested episode out of a pack. `parse` receives the video files'
/// bare names in order and answers with one entry per name. Returns the index
/// into `files` of the pick, or null for an empty list. Throws
/// [EpisodeNotInPack] when the release provably lacks the episode.
int? pickEpisodeFile(List<PackFile> files, double episode, PackParser parse) {
  final videoIndices = [
    for (var index = 0; index < files.length; index++)
      if (isVideoPath(files[index].path)) index,
  ];
  if (videoIndices.isEmpty) {
    if (files.isEmpty) return null;
    throw EpisodeNotIdentified(episode);
  }

  final names = [
    for (final index in videoIndices) files[index].path.split('/').last,
  ];

  List<ParsedName?>? parsed;
  try {
    parsed = parse(names);
  } catch (_) {
    if (videoIndices.length == 1) return videoIndices.first;
    throw EpisodeNotIdentified(episode);
  }
  if (videoIndices.length == 1 &&
      (parsed.isEmpty || (parsed.first?.episodeNumbers.isEmpty ?? true))) {
    return videoIndices.first;
  }

  // rank 0: episode, exact. 1: episode, range. 2: extra, exact. 3: extra, range.
  // First file in torrent order wins within a rank, so duplicate resolutions stay stable.
  final ranks = List<int?>.filled(4, null);
  final held = <double>[]; // every episode number the pack's files answer to
  var unnumbered = 0;
  for (var position = 0; position < parsed.length; position++) {
    final entry = parsed[position];
    final numbers = entry?.episodeNumbers ?? const <double>[];
    if (numbers.isEmpty) {
      unnumbered++;
    } else {
      held.addAll(numbers);
    }
    final matched = _matchesEpisode(entry, episode);
    if (matched == null) continue;
    final isExtra = entry?.isExtra ?? false;
    final rank = (isExtra ? 2 : 0) + (matched == _Match.range ? 1 : 0);
    ranks[rank] ??= position;
  }
  for (final position in ranks) {
    if (position != null) return videoIndices[position];
  }

  final episodes = [
    for (var position = 0; position < videoIndices.length; position++)
      if (!((position < parsed.length ? parsed[position] : null)?.isExtra ??
          false))
        position,
  ];
  // every video answered with a number and none covers the episode: the release
  // cannot serve this request, and no fallback can make it
  if (parsed.length == videoIndices.length &&
      unnumbered == 0 &&
      held.isNotEmpty) {
    // the reported span reads off the real episodes where any exist, so an NCOP1
    // in the pack does not make a 459-516 release claim to start at episode 1
    final span = episodes.isEmpty
        ? held
        : [
            for (final position in episodes)
              ...parsed[position]?.episodeNumbers ?? const <double>[],
          ];
    final first = span.reduce((a, b) => a < b ? a : b);
    final last = span.reduce((a, b) => a > b ? a : b);
    throw EpisodeNotInPack(episode: episode, first: first, last: last);
  }

  // A partial parse is not permission to choose the largest video. That was
  // the final unsafe fallback which could still turn an unnumbered batch into
  // the wrong episode.
  throw EpisodeNotIdentified(episode);
}

/// Picks the episode for a debrid resolve. [maxFiles] remains in the signature
/// for provider compatibility, but an explicit episode is never handed off as
/// an unselected pack: the player cannot safely infer the user's intent from a
/// window or from torrent order.
int? pickPackFile(
  List<PackFile> files,
  double episode,
  PackParser parse,
  int maxFiles,
) {
  return pickEpisodeFile(files, episode, parse);
}

/// Reads names with the shared recognizer. The picker's own contract applies: a
/// name the recognizer cannot number comes back as null, which keeps a
/// mismatch unproven and the fallbacks in play.
List<ParsedName?> parseNames(List<String> names) => [
  for (final name in names) _parsedNameOf(name),
];

ParsedName? _parsedNameOf(String name) {
  final parsed = parseFilename(name);
  if (parsed.episodeNumbers.isEmpty && parsed.kind == null) return null;
  return ParsedName(
    episodeNumbers: parsed.episodeNumbers,
    episodeSpans: parsed.episodeSpans,
    isExtra: parsed.isExtra,
  );
}

/// Picks the episode out of a pack using the shared recognizer — the call every
/// host makes. Null hands the choice to the player.
int? pickPack(List<PackFile> files, double episode, int maxFiles) =>
    pickPackFile(files, episode, parseNames, maxFiles);
