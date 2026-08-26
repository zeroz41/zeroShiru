import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../../domain/ports/ports.dart';

class HomeFeed {
  const HomeFeed({
    required this.hero,
    required this.trending,
    required this.newReleases,
    required this.popular,
    this.genreSections = const [],
  });

  final List<Media> hero;
  final List<Media> trending;
  final List<Media> newReleases;
  final List<Media> popular;
  final List<HomeGenreSection> genreSections;
}

class HomeGenreSection {
  const HomeGenreSection({required this.genre, required this.media});

  final String genre;
  final List<Media> media;
}

class PersonalizedHomeFeed {
  const PersonalizedHomeFeed({
    this.continueWatching = const [],
    this.recommendations = const [],
    this.favoriteGenres = const [],
  });

  final List<Media> continueWatching;
  final List<Media> recommendations;
  final List<String> favoriteGenres;

  bool get isEmpty => continueWatching.isEmpty && recommendations.isEmpty;
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
      MediaBrowseQuery(
        perPage: 25,
        sort: MediaSort.popularity,
        year: today.year,
        excludedStatuses: const [MediaStatus.notYetReleased],
      ),
    ),
    catalog.browse(
      const MediaBrowseQuery(perPage: 25, sort: MediaSort.popularity),
    ),
  ]);
  final trending = pages[0].items;
  final newReleases = pages[1].items;
  final popular = pages[2].items;
  return HomeFeed(
    hero: trending.take(8).toList(growable: false),
    trending: trending,
    newReleases: newReleases,
    popular: popular,
    genreSections: _genreSections([...trending, ...newReleases, ...popular]),
  );
}

List<HomeGenreSection> _genreSections(List<Media> source) {
  const priority = [
    'Action',
    'Fantasy',
    'Comedy',
    'Romance',
    'Adventure',
    'Drama',
    'Sci-Fi',
    'Mystery',
    'Slice of Life',
    'Sports',
  ];
  final unique = <int, Media>{for (final media in source) media.id: media};
  return [
    for (final genre in priority)
      if (unique.values.where((media) => media.genres.contains(genre)).length >=
          5)
        HomeGenreSection(
          genre: genre,
          media: unique.values
              .where((media) => media.genres.contains(genre))
              .take(25)
              .toList(growable: false),
        ),
  ].take(3).toList(growable: false);
}

/// Builds a small, explainable recommendation set from the user's active
/// watches. It deliberately re-ranks the already cached home catalogue rather
/// than adding another network request to startup.
Future<PersonalizedHomeFeed> loadPersonalizedHomeFeed(
  TrackingRepository tracking,
  HomeFeed home,
) async {
  final watching = await tracking.userList(ListStatus.current);
  final continueWatching = watching
      .where((media) {
        final progress = media.listEntry?.progress ?? 0;
        final maximum = media.maxEpisode;
        return progress > 0 && (maximum == null || progress < maximum);
      })
      .toList(growable: false);

  final affinity = <String, int>{};
  for (final media in watching) {
    for (final genre in media.genres) {
      affinity.update(genre, (score) => score + 1, ifAbsent: () => 1);
    }
  }
  final favoriteGenres = affinity.keys.toList(growable: false)
    ..sort((a, b) {
      final byWeight = affinity[b]!.compareTo(affinity[a]!);
      return byWeight != 0 ? byWeight : a.compareTo(b);
    });

  final watchedIds = {for (final media in watching) media.id};
  final candidates = <int, Media>{
    for (final media in [
      ...home.trending,
      ...home.newReleases,
      ...home.popular,
    ])
      if (!watchedIds.contains(media.id)) media.id: media,
  }.values.toList(growable: false);
  candidates.sort((a, b) {
    int score(Media media) {
      final genreScore = media.genres.fold<int>(
        0,
        (total, genre) => total + (affinity[genre] ?? 0) * 100,
      );
      return genreScore + (media.averageScore ?? 0);
    }

    return score(b).compareTo(score(a));
  });

  return PersonalizedHomeFeed(
    continueWatching: continueWatching,
    recommendations: affinity.isEmpty
        ? const []
        : candidates
              .where(
                (media) => media.genres.any((genre) => affinity[genre] != null),
              )
              .take(25)
              .toList(growable: false),
    favoriteGenres: favoriteGenres.take(2).toList(growable: false),
  );
}
