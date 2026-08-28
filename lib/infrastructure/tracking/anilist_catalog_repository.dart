import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../../domain/ports/catalog_repository.dart';
import 'anilist_client.dart';

/// Public catalogue adapter over the shared AniList client/cache.
class AnilistCatalogRepository implements CatalogRepository {
  const AnilistCatalogRepository(this._client);

  final AnilistClient _client;

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) async {
    final page = await _client.search(
      AnilistSearchFilter(
        search: _nonEmpty(query.search),
        page: query.page,
        perPage: query.perPage,
        sort: _sort(query.sort),
        season: _season(query.season),
        year: query.year,
        genres: _nonEmptyList(query.genres),
        genresExclude: _nonEmptyList(query.excludedGenres),
        tags: _nonEmptyList(query.tags),
        tagsExclude: _nonEmptyList(query.excludedTags),
        formats: _mapList(query.formats, _format),
        statuses: _mapList(query.statuses, _status),
        statusesExclude: _mapList(query.excludedStatuses, _status),
        onList: query.onList,
        isAdult: query.includeAdult ? null : false,
      ),
    );
    return MediaPage(items: page.media, hasNextPage: page.hasNextPage);
  }

  @override
  Future<Media?> mediaById(int id) => _client.mediaById(id);

  @override
  Future<List<Media>> similar(int mediaId) => _client.similarMedia(mediaId);

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static List<String>? _nonEmptyList(List<String> values) {
    final normalized = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return normalized.isEmpty ? null : normalized;
  }

  static List<String>? _mapList<T>(
    List<T> values,
    String Function(T) convert,
  ) => values.isEmpty ? null : [for (final value in values) convert(value)];

  static String _sort(MediaSort sort) => switch (sort) {
    MediaSort.trending => 'TRENDING_DESC',
    MediaSort.popularity => 'POPULARITY_DESC',
    MediaSort.score => 'SCORE_DESC',
    MediaSort.title => 'TITLE_ROMAJI',
    MediaSort.startDate => 'START_DATE_DESC',
  };

  static String? _season(MediaSeason? season) => switch (season) {
    MediaSeason.winter => 'WINTER',
    MediaSeason.spring => 'SPRING',
    MediaSeason.summer => 'SUMMER',
    MediaSeason.fall => 'FALL',
    null => null,
  };

  static String _format(MediaFormat format) => switch (format) {
    MediaFormat.tv => 'TV',
    MediaFormat.tvShort => 'TV_SHORT',
    MediaFormat.movie => 'MOVIE',
    MediaFormat.special => 'SPECIAL',
    MediaFormat.ova => 'OVA',
    MediaFormat.ona => 'ONA',
    MediaFormat.music => 'MUSIC',
    MediaFormat.unknown => 'UNKNOWN',
  };

  static String _status(MediaStatus status) => switch (status) {
    MediaStatus.finished => 'FINISHED',
    MediaStatus.releasing => 'RELEASING',
    MediaStatus.notYetReleased => 'NOT_YET_RELEASED',
    MediaStatus.cancelled => 'CANCELLED',
    MediaStatus.hiatus => 'HIATUS',
  };
}
