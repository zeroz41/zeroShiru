import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/application/library/home_feed.dart';
import 'package:zeroshiru/domain/models/catalog.dart';
import 'package:zeroshiru/domain/models/media.dart';
import 'package:zeroshiru/domain/ports/catalog_repository.dart';
import 'package:zeroshiru/infrastructure/network/transport.dart';
import 'package:zeroshiru/infrastructure/tracking/anilist_catalog_repository.dart';
import 'package:zeroshiru/infrastructure/tracking/anilist_client.dart';

import '../tracking/fakes.dart';

class _RecordingCatalog implements CatalogRepository {
  final List<MediaBrowseQuery> queries = [];

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) async {
    queries.add(query);
    return MediaPage(
      items: [
        Media(
          id: queries.length,
          title: MediaTitle(userPreferred: 'Result ${queries.length}'),
        ),
      ],
      hasNextPage: false,
    );
  }

  @override
  Future<Media?> mediaById(int id) async => null;
}

void main() {
  test('season boundaries follow anime cours', () {
    expect(mediaSeasonAt(DateTime(2026, 1, 1)), MediaSeason.winter);
    expect(mediaSeasonAt(DateTime(2026, 3, 31)), MediaSeason.winter);
    expect(mediaSeasonAt(DateTime(2026, 4, 1)), MediaSeason.spring);
    expect(mediaSeasonAt(DateTime(2026, 7, 1)), MediaSeason.summer);
    expect(mediaSeasonAt(DateTime(2026, 10, 1)), MediaSeason.fall);
  });

  test(
    'home feed asks for this season and all-time popularity concurrently',
    () async {
      final catalog = _RecordingCatalog();
      final feed = await loadHomeFeed(catalog, now: DateTime(2026, 8, 23));

      expect(catalog.queries, hasLength(2));
      final seasonal = catalog.queries[0];
      expect(seasonal.season, MediaSeason.summer);
      expect(seasonal.year, 2026);
      expect(seasonal.sort, MediaSort.trending);
      expect(seasonal.excludedStatuses, [MediaStatus.notYetReleased]);
      expect(catalog.queries[1].sort, MediaSort.popularity);
      expect(feed.hero.single.title.display, 'Result 1');
      expect(feed.popular.single.title.display, 'Result 2');
    },
  );

  test('AniList catalogue translates the provider-neutral query', () async {
    final transport = FakeTransport();
    transport.onJson('graphql.anilist.co', {
      'data': {
        'Page': {
          'pageInfo': {'hasNextPage': true},
          'media': <Object>[],
        },
      },
    });
    final repository = AnilistCatalogRepository(
      AnilistClient(transport: transport, cache: InMemoryQueryCache()),
    );

    final result = await repository.browse(
      const MediaBrowseQuery(
        search: '  Frieren  ',
        page: 3,
        perPage: 20,
        sort: MediaSort.score,
        season: MediaSeason.fall,
        year: 2023,
        formats: [MediaFormat.tv, MediaFormat.ona],
        genres: [' Fantasy ', 'Adventure', 'Fantasy'],
        excludedGenres: ['Hentai'],
        tags: ['Time Skip'],
        excludedTags: ['Gore'],
        excludedStatuses: [MediaStatus.cancelled],
      ),
    );

    final body = transport.requests.single.body! as BytesBody;
    final payload = jsonDecode(utf8.decode(body.bytes)) as Map<String, dynamic>;
    final variables = payload['variables'] as Map<String, dynamic>;
    expect(variables['search'], 'Frieren');
    expect(variables['page'], 3);
    expect(variables['perPage'], 20);
    expect(variables['sort'], 'SCORE_DESC');
    expect(variables['season'], 'FALL');
    expect(variables['year'], 2023);
    expect(variables['format'], ['TV', 'ONA']);
    expect(variables['genre'], ['Fantasy', 'Adventure']);
    expect(variables['genre_not'], ['Hentai']);
    expect(variables['tag'], ['Time Skip']);
    expect(variables['tag_not'], ['Gore']);
    expect(variables['status_not'], ['CANCELLED']);
    expect(variables['isAdult'], isFalse);
    expect(result.hasNextPage, isTrue);
  });
}
