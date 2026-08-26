/// Whether a release can hold the episode being asked for, judged from its title
/// alone. Pure and transport free: it runs over search results before anything
/// knows or cares whether they will be played from a torrent, from debrid, or
/// from a cache — every source's results go through it.
///
/// Port of `frontend/common/modules/playback/coverage.js`. Why it exists: a
/// title that names several episodes parses to an array of numbers, and the app
/// read any array as "this is a batch, so it has everything".
/// `[F-R] One Piece 0487+0490` parses to [487, 490] exactly like
/// `One Piece 0001-0782` does, so a two episode fix release was offered for
/// every episode of the show, and picking any of them played 487.
library;

import '../../domain/media/filename.dart';

/// An inclusive span of episode numbers a title claims.
class ReleaseSpan {
  const ReleaseSpan(this.first, this.last);

  final double first;
  final double last;

  bool contains(double episode) => first <= episode && episode <= last;

  @override
  bool operator ==(Object other) =>
      other is ReleaseSpan && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => 'ReleaseSpan($first, $last)';
}

/// The episode numbers a parsed title claims, as an inclusive span. A single
/// number is a span of one; several become the range they enclose, which is how
/// a batch names itself. Accepts the recognizer's number list or the raw
/// `episode_number` shapes anitomy produced (a string, a list of strings).
/// Null when the title names no episodes.
ReleaseSpan? releaseSpan(Object? episodeNumber) {
  if (episodeNumber == null) return null;
  final raw = episodeNumber is List ? episodeNumber : [episodeNumber];
  final numbers = [for (final value in raw) ?_finite(value)];
  if (numbers.isEmpty) return null;
  return ReleaseSpan(
    numbers.reduce((a, b) => a < b ? a : b),
    numbers.reduce((a, b) => a > b ? a : b),
  );
}

/// Whether a release should still be offered for an episode. A title that names
/// no episodes proves nothing and remains eligible for file-list inspection.
/// Once a title does make a claim, however, it must cover either the local or
/// mapped absolute episode. Guessing that every out-of-range number is an
/// alternate numbering scheme is how unrelated partial batches reached the
/// picker.
///
/// [parse] is the parse of the release title: a [ParsedFilename] from the
/// recognizer, or the raw episode-number value(s) a foreign parser produced.
bool releaseHoldsEpisode(
  Object? parse, {
  Object? episode,
  Object? absoluteEpisode,
  Object? episodeCount,
}) {
  final wanted = [
    for (final value in [episode, absoluteEpisode]) ?_finite(value),
  ];
  if (wanted.isEmpty) {
    return true; // nothing was asked for, so nothing can be ruled out
  }
  final spans = _episodeSpansOf(parse);
  if (spans.isEmpty) return true;
  return wanted.any((episode) => spans.any((span) => span.contains(episode)));
}

/// Which number should be handed to the torrent's file picker. Local numbering
/// wins when both forms are present; otherwise a mapped absolute number is used.
/// Null means the title did not prove a match.
double? releaseEpisodeFor(
  Object? parse, {
  Object? episode,
  Object? absoluteEpisode,
}) {
  final spans = _episodeSpansOf(parse);
  if (spans.isEmpty) return null;
  for (final value in [episode, absoluteEpisode]) {
    final candidate = _finite(value);
    if (candidate != null && spans.any((span) => span.contains(candidate))) {
      return candidate;
    }
  }
  return null;
}

List<ReleaseSpan> _episodeSpansOf(Object? parse) {
  if (parse is ParsedFilename) {
    return [
      for (final span in parse.episodeSpans) ReleaseSpan(span.first, span.last),
    ];
  }
  final span = releaseSpan(_episodeNumberOf(parse));
  return span == null ? const [] : [span];
}

Object? _episodeNumberOf(Object? parse) =>
    parse is ParsedFilename ? parse.episodeNumbers : parse;

double? _finite(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}
