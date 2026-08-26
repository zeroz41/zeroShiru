import 'media.dart';

/// Sorts the library UI understands, independent of any tracking provider's
/// wire vocabulary.
enum MediaSort { trending, popularity, score, title, startDate }

/// One page of media returned by the public catalogue.
class MediaPage {
  const MediaPage({required this.items, required this.hasNextPage});

  final List<Media> items;
  final bool hasNextPage;
}

/// Provider-neutral browse/search query. Infrastructure adapters translate
/// this into AniList GraphQL variables (or another catalogue in the future).
class MediaBrowseQuery {
  const MediaBrowseQuery({
    this.search,
    this.page = 1,
    this.perPage = 50,
    this.sort = MediaSort.trending,
    this.season,
    this.year,
    this.formats = const [],
    this.statuses = const [],
    this.excludedStatuses = const [],
    this.genres = const [],
    this.excludedGenres = const [],
    this.tags = const [],
    this.excludedTags = const [],
    this.onList,
    this.includeAdult = false,
  });

  final String? search;
  final int page;
  final int perPage;
  final MediaSort sort;
  final MediaSeason? season;
  final int? year;
  final List<MediaFormat> formats;
  final List<MediaStatus> statuses;
  final List<MediaStatus> excludedStatuses;
  final List<String> genres;
  final List<String> excludedGenres;
  final List<String> tags;
  final List<String> excludedTags;
  final bool? onList;
  final bool includeAdult;
}
