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
  final indexed = candidates.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final a = left.$2;
    final b = right.$2;

    var order = _availabilityRank(availability(a))
        .compareTo(_availabilityRank(availability(b)));
    if (order != 0) return order;

    order =
        releaseLanguagePreferenceScore(
          b,
          audioLanguage: preferences.audioLanguage,
          subtitleLanguage: preferences.releaseSubtitleLanguage,
        ).compareTo(
          releaseLanguagePreferenceScore(
            a,
            audioLanguage: preferences.audioLanguage,
            subtitleLanguage: preferences.releaseSubtitleLanguage,
          ),
        );
    if (order != 0) return order;

    order = _qualityDistance(
      a.title,
      preferences.rssQuality,
    ).compareTo(_qualityDistance(b.title, preferences.rssQuality));
    if (order != 0) return order;

    order = _accuracyRank(a).compareTo(_accuracyRank(b));
    if (order != 0) return order;

    order = _typeRank(a).compareTo(_typeRank(b));
    if (order != 0) return order;

    order = switch (preferences.torrentSort) {
      'size' => (b.size ?? 0).compareTo(a.size ?? 0),
      'quality' => sourceQuality(b.title).compareTo(sourceQuality(a.title)),
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
    return left.$1.compareTo(right.$1);
  });
  return [for (final item in indexed) item.$2];
}

int _swarmRatio(TorrentResult result) {
  final seeders = result.seeders ?? 0;
  final leechers = result.leechers ?? 0;
  final peers = seeders + leechers;
  return peers <= 0 ? 0 : (seeders * 1000 ~/ peers);
}

int sourceQuality(String title) =>
    int.tryParse(
      RegExp(
            r'(2160|1440|1080|720|540|480)p?',
            caseSensitive: false,
          ).firstMatch(title)?.group(1) ??
          '',
    ) ??
    0;

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
