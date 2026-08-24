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
  const ParsedName({this.episodeNumbers = const [], this.isExtra = false});

  final List<double> episodeNumbers;
  final bool isExtra;
}

/// Reads the video files' bare names in order and answers with one entry per
/// name (null per entry = that name failed to parse; a throw = the parser broke).
typedef PackParser = List<ParsedName?> Function(List<String> names);

/// The release provably does not contain the requested episode: every video file
/// parsed to an episode number and none of them covers it. Raised instead of
/// guessing, because the guess used to be "largest file" — asking a 459-516 pack
/// for episode 23 played episode 475.
class EpisodeNotInPack implements Exception {
  const EpisodeNotInPack({
    required this.episode,
    required this.first,
    required this.last,
  });

  final double episode;
  final double first;
  final double last;

  String get message =>
      'This release holds ${_spanText(first, last)}, not episode ${_plain(episode)}. '
      'Pick a release that has it.';

  @override
  String toString() => message;

  @override
  bool operator ==(Object other) =>
      other is EpisodeNotInPack &&
      other.episode == episode &&
      other.first == first &&
      other.last == last;

  @override
  int get hashCode => Object.hash(episode, first, last);
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
_Match? _matchesEpisode(List<double> numbers, double episode) {
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
  if (videoIndices.length <= 1) {
    if (videoIndices.isNotEmpty) return videoIndices.first;
    return files.isEmpty ? null : 0;
  }

  final names = [
    for (final index in videoIndices) files[index].path.split('/').last,
  ];

  var candidates = List<int>.of(videoIndices);
  List<ParsedName?>? parsed;
  try {
    parsed = parse(names);
  } catch (_) {
    parsed = null; // a broken parser still yields a playable fallback
  }
  if (parsed != null) {
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
      final matched = _matchesEpisode(numbers, episode);
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
    // nothing matched but nothing is proven either: never fall back onto an extra
    // while real episodes exist
    if (episodes.isNotEmpty) {
      candidates = [for (final position in episodes) videoIndices[position]];
    }
  }
  // best guess: the largest episode-like video, first in torrent order on ties
  int? best;
  for (final index in candidates) {
    if (best == null || files[index].size > files[best].size) best = index;
  }
  return best;
}

/// Picks the episode for a debrid resolve, refusing only when refusing costs
/// nothing: when every file reaches the player anyway (no windowing), handing the
/// whole release over lets the side that knows season offsets decide.
/// Null with no throw hands the choice to the player.
int? pickPackFile(
  List<PackFile> files,
  double episode,
  PackParser parse,
  int maxFiles,
) {
  try {
    return pickEpisodeFile(files, episode, parse);
  } on EpisodeNotInPack {
    if (files.length <= maxFiles) return null;
    rethrow;
  }
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
    isExtra: parsed.isExtra,
  );
}

/// Picks the episode out of a pack using the shared recognizer — the call every
/// host makes. Null hands the choice to the player.
int? pickPack(List<PackFile> files, double episode, int maxFiles) =>
    pickPackFile(files, episode, parseNames, maxFiles);
