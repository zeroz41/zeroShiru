import '../../domain/models/availability.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/torrent.dart';
import 'release_language.dart';

/// The single authoritative ordering for automatic playback and the picker's
/// "Best" view.
///
/// The order deliberately starts with facts that most affect time-to-play and
/// correctness, then moves to softer quality signals:
///
/// 1. proven debrid cache availability;
/// 2. requested audio and subtitle languages;
/// 3. configured resolution;
/// 4. source match confidence and release shape;
/// 5. the user's torrent sort preference, with seed health as the fallback.
///
/// Language metadata and cache checks can both be incomplete, so neither is a
/// hard filter here. Episode/file validation happens before candidates reach
/// this ranker.
List<TorrentResult> rankBestSources(
  Iterable<TorrentResult> candidates, {
  required Settings preferences,
  required Availability Function(TorrentResult result) availability,
}) {
  // The comparator runs O(n log n) times over lists that can hold hundreds of
  // results, and the language/quality scores lowercase the title and run
  // regexes. Compute each candidate's keys once up front.
  final keyed = [
    for (final (index, result) in candidates.indexed)
      (
        index: index,
        result: result,
        availability: _availabilityRank(availability(result)),
        language: releaseLanguagePreferenceScore(
          result,
          audioLanguage: preferences.audioLanguage,
          subtitleLanguage: preferences.releaseSubtitleLanguage,
        ),
        qualityDistance: _qualityDistance(result.title, preferences.rssQuality),
        quality: sourceQuality(result.title),
      ),
  ];
  keyed.sort((left, right) {
    final a = left.result;
    final b = right.result;

    var order = left.availability.compareTo(right.availability);
    if (order != 0) return order;

    order = right.language.compareTo(left.language);
    if (order != 0) return order;

    order = left.qualityDistance.compareTo(right.qualityDistance);
    if (order != 0) return order;

    order = _accuracyRank(a).compareTo(_accuracyRank(b));
    if (order != 0) return order;

    order = _typeRank(a).compareTo(_typeRank(b));
    if (order != 0) return order;

    order = switch (preferences.torrentSort) {
      'size' => (b.size ?? 0).compareTo(a.size ?? 0),
      'quality' => right.quality.compareTo(left.quality),
      _ => (b.seeders ?? 0).compareTo(a.seeders ?? 0),
    };
    if (order != 0) return order;

    // Seeder health remains the most useful general torrent tie-breaker even
    // when somebody chose a different primary sort. When seeder counts tie,
    // prefer the swarm with fewer blocked downloaders rather than treating a
    // 5:2 swarm and a 5:500 swarm as equally healthy.
    order = (b.seeders ?? 0).compareTo(a.seeders ?? 0);
    if (order != 0) return order;
    order = _swarmRatio(b).compareTo(_swarmRatio(a));
    if (order != 0) return order;
    order = (b.downloads ?? 0).compareTo(a.downloads ?? 0);
    if (order != 0) return order;

    // A current repack is generally a better fallback than an otherwise
    // indistinguishable stale upload. Missing dates remain neutral.
    order = (b.date?.millisecondsSinceEpoch ?? 0).compareTo(
      a.date?.millisecondsSinceEpoch ?? 0,
    );
    if (order != 0) return order;

    // Equal-resolution releases with equal swarm health start transferring
    // less data sooner. A missing size carries no confidence and sorts last.
    final aSize = a.size == null || a.size! <= 0 ? 1 << 62 : a.size!;
    final bSize = b.size == null || b.size! <= 0 ? 1 << 62 : b.size!;
    order = aSize.compareTo(bSize);
    if (order != 0) return order;

    // Preserve provider order when every meaningful signal ties.
    return left.index.compareTo(right.index);
  });
  return [for (final item in keyed) item.result];
}

int _swarmRatio(TorrentResult result) {
  final seeders = result.seeders ?? 0;
  final leechers = result.leechers ?? 0;
  final peers = seeders + leechers;
  return peers <= 0 ? 0 : (seeders * 1000 ~/ peers);
}

final _qualityPattern = RegExp(
  r'(2160|1440|1080|720|540|480)p?',
  caseSensitive: false,
);

int sourceQuality(String title) =>
    int.tryParse(_qualityPattern.firstMatch(title)?.group(1) ?? '') ?? 0;

int _availabilityRank(Availability availability) => switch (availability) {
  Availability.cached => 0,
  Availability.unknown => 1,
  Availability.available => 2,
  Availability.unavailable => 3,
};

int _qualityDistance(String title, String preferred) {
  final quality = sourceQuality(title);
  final expected = int.tryParse(preferred);
  if (expected == null || expected <= 0) {
    return quality == 0 ? 1 << 30 : -quality;
  }
  if (quality == 0) return 1 << 30;
  return (quality - expected).abs();
}

int _accuracyRank(TorrentResult result) => switch (result.accuracy) {
  'high' => 0,
  null => 1,
  'medium' => 2,
  'low' => 3,
  _ => 2,
};

int _typeRank(TorrentResult result) => switch (result.type) {
  'best' => 0,
  null => 1,
  'batch' => 2,
  _ => 3,
};
