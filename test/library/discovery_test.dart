import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/library/discovery.dart';
import 'package:zero/domain/models/catalog.dart';
import 'package:zero/domain/models/media.dart';

void main() {
  test('discovery filters count and translate active values', () {
    final filters = const DiscoveryFilters().copyWith(
      sort: MediaSort.score,
      season: MediaSeason.fall,
      year: 2026,
      formats: {MediaFormat.tv, MediaFormat.ona},
      statuses: {MediaStatus.releasing},
      genres: {'Action', 'Fantasy'},
      hideMyAnime: true,
    );

    expect(filters.activeCount, 9);
    final query = filters.toQuery(page: 3, search: '  Frieren  ');
    expect(query.page, 3);
    expect(query.search, '  Frieren  ');
    expect(query.sort, MediaSort.score);
    expect(query.season, MediaSeason.fall);
    expect(query.year, 2026);
    expect(query.formats, {MediaFormat.tv, MediaFormat.ona});
    expect(query.statuses, {MediaStatus.releasing});
    expect(query.genres, {'Action', 'Fantasy'});
    expect(query.onList, isFalse);
    expect(query.includeAdult, isFalse);
  });

  test('nullable values can be explicitly cleared', () {
    final filters = const DiscoveryFilters(
      season: MediaSeason.spring,
      year: 2025,
    ).copyWith(season: null, year: null);

    expect(filters.season, isNull);
    expect(filters.year, isNull);
    expect(filters.isDefault, isTrue);
  });
}
