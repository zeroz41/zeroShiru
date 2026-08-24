import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';

/// Immutable, provider-neutral discovery state.
///
/// Widgets own presentation concerns such as whether the filter panel is open;
/// this object owns only values that change the catalogue request. That keeps
/// pagination, active-filter badges, and provider translation in agreement.
class DiscoveryFilters {
  const DiscoveryFilters({
    this.sort = MediaSort.trending,
    this.season,
    this.year,
    this.formats = const {},
    this.statuses = const {},
    this.genres = const {},
    this.hideMyAnime = false,
    this.includeAdult = false,
  });

  final MediaSort sort;
  final MediaSeason? season;
  final int? year;
  final Set<MediaFormat> formats;
  final Set<MediaStatus> statuses;
  final Set<String> genres;
  final bool hideMyAnime;
  final bool includeAdult;

  int get activeCount =>
      (sort == MediaSort.trending ? 0 : 1) +
      (season == null ? 0 : 1) +
      (year == null ? 0 : 1) +
      formats.length +
      statuses.length +
      genres.length +
      (hideMyAnime ? 1 : 0) +
      (includeAdult ? 1 : 0);

  bool get isDefault => activeCount == 0;

  MediaBrowseQuery toQuery({
    required int page,
    required String search,
    int perPage = 50,
  }) {
    return MediaBrowseQuery(
      search: search,
      page: page,
      perPage: perPage,
      sort: sort,
      season: season,
      year: year,
      formats: formats.toList(growable: false),
      statuses: statuses.toList(growable: false),
      genres: genres.toList(growable: false),
      onList: hideMyAnime ? false : null,
      includeAdult: includeAdult,
    );
  }

  DiscoveryFilters copyWith({
    MediaSort? sort,
    Object? season = _unset,
    Object? year = _unset,
    Set<MediaFormat>? formats,
    Set<MediaStatus>? statuses,
    Set<String>? genres,
    bool? hideMyAnime,
    bool? includeAdult,
  }) {
    return DiscoveryFilters(
      sort: sort ?? this.sort,
      season: identical(season, _unset) ? this.season : season as MediaSeason?,
      year: identical(year, _unset) ? this.year : year as int?,
      formats: Set.unmodifiable(formats ?? this.formats),
      statuses: Set.unmodifiable(statuses ?? this.statuses),
      genres: Set.unmodifiable(genres ?? this.genres),
      hideMyAnime: hideMyAnime ?? this.hideMyAnime,
      includeAdult: includeAdult ?? this.includeAdult,
    );
  }

  static const Object _unset = Object();
}
