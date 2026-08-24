import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../../domain/ports/catalog_repository.dart';

class HomeFeed {
  const HomeFeed({
    required this.hero,
    required this.trending,
    required this.popular,
  });

  final List<Media> hero;
  final List<Media> trending;
  final List<Media> popular;
}

/// The season AniList uses for northern-hemisphere anime cours.
MediaSeason mediaSeasonAt(DateTime date) => switch (date.month) {
  <= 3 => MediaSeason.winter,
  <= 6 => MediaSeason.spring,
  <= 9 => MediaSeason.summer,
  _ => MediaSeason.fall,
};

/// Loads the first useful offline-tolerant library screen. The shared query
/// cache beneath [catalog] coalesces duplicates and serves previous sessions.
Future<HomeFeed> loadHomeFeed(
  CatalogRepository catalog, {
  DateTime? now,
}) async {
  final today = now ?? DateTime.now();
  final seasonalQuery = MediaBrowseQuery(
    perPage: 25,
    sort: MediaSort.trending,
    season: mediaSeasonAt(today),
    year: today.year,
    excludedStatuses: const [MediaStatus.notYetReleased],
  );

  final pages = await Future.wait([
    catalog.browse(seasonalQuery),
    catalog.browse(
      const MediaBrowseQuery(perPage: 25, sort: MediaSort.popularity),
    ),
  ]);
  final trending = pages[0].items;
  return HomeFeed(
    hero: trending.take(8).toList(growable: false),
    trending: trending,
    popular: pages[1].items,
  );
}
