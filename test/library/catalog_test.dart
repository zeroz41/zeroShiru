import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/library/home_feed.dart';
import 'package:zero/domain/models/catalog.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/tracking_account.dart';
import 'package:zero/domain/ports/ports.dart';
import 'package:zero/domain/ports/http_transport.dart';
import 'package:zero/infrastructure/tracking/anilist_catalog_repository.dart';
import 'package:zero/infrastructure/tracking/anilist_client.dart';

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

  @override
  Future<List<Media>> similar(int mediaId) async => const [];
}

class _WatchingRepository implements TrackingRepository {
  _WatchingRepository(this.watching);

  final List<Media> watching;

  @override
  Future<List<TrackingAccount>> accounts() async => const [];

  @override
  Future<Media?> mediaById(int id) async => null;

  @override
  Future<List<Media>> search(String query, {int page = 1}) async => const [];

  @override
  Future<List<Media>> userList(ListStatus status) async =>
      status == ListStatus.current ? watching : const [];

  @override
  Future<void> updateProgress(Media media, int episode) async {}

  @override
  Future<TrackingAccount> connectAniList(String pasted) =>
      throw UnimplementedError();

  @override
  Future<void> disconnect(TrackingAccountService service) async {}
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
    'home feed asks for seasonal, new, and popular titles concurrently',
    () async {
      final catalog = _RecordingCatalog();
      final feed = await loadHomeFeed(catalog, now: DateTime(2026, 8, 23));

      expect(catalog.queries, hasLength(3));
      final seasonal = catalog.queries[0];
      expect(seasonal.season, MediaSeason.summer);
      expect(seasonal.year, 2026);
      expect(seasonal.sort, MediaSort.trending);
      expect(seasonal.excludedStatuses, [MediaStatus.notYetReleased]);
      expect(catalog.queries[1].sort, MediaSort.popularity);
      expect(catalog.queries[1].year, 2026);
      expect(catalog.queries[1].excludedStatuses, [MediaStatus.notYetReleased]);
      expect(catalog.queries[2].sort, MediaSort.popularity);
      expect(feed.hero.single.title.display, 'Result 1');
      expect(feed.newReleases.single.title.display, 'Result 2');
      expect(feed.popular.single.title.display, 'Result 3');
    },
  );

  test('personalized expansion asks for one scored genre page', () async {
    final catalog = _RecordingCatalog();

    final media = await loadPersonalizedGenreCandidates(
      catalog,
      'Slice of Life',
    );

    expect(media, hasLength(1));
    final query = catalog.queries.single;
    expect(query.perPage, 25);
    expect(query.sort, MediaSort.score);
    expect(query.genres, ['Slice of Life']);
    expect(query.excludedStatuses, [MediaStatus.notYetReleased]);
    expect(query.includeAdult, isFalse);
  });

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

  test(
    'personalized home feed resumes progress and favors watched genres',
    () async {
      const watching = Media(
        id: 1,
        title: MediaTitle(userPreferred: 'Watching'),
        episodes: 12,
        genres: ['Fantasy', 'Adventure'],
        listEntry: ListEntry(status: ListStatus.current, progress: 4),
      );
      const fantasy = Media(
        id: 2,
        title: MediaTitle(userPreferred: 'Fantasy pick'),
        genres: ['Fantasy'],
        averageScore: 80,
      );
      const comedy = Media(
        id: 3,
        title: MediaTitle(userPreferred: 'Comedy pick'),
        genres: ['Comedy'],
        averageScore: 99,
      );
      const home = HomeFeed(
        hero: [],
        trending: [comedy, fantasy],
        newReleases: [],
        popular: [],
      );

      final feed = await loadPersonalizedHomeFeed(
        _WatchingRepository([watching]),
        home,
      );

      final slot = feed.continueWatching.single;
      expect(slot.media, watching);
      expect(slot.episode, 5);
      expect(slot.resumeProgress, isNull);
      expect(feed.recommendations, [fantasy, comedy]);
      expect(feed.favoriteGenres, ['Adventure', 'Fantasy']);
    },
  );
}
