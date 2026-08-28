import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/library/home_feed.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/domain/models/catalog.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/tracking_account.dart';
import 'package:zero/domain/ports/ports.dart';

class _Tracking implements TrackingRepository {
  _Tracking(this.current);

  final Future<List<Media>> current;

  @override
  Future<List<TrackingAccount>> accounts() async => const [];

  @override
  Future<Media?> mediaById(int id) async => null;

  @override
  Future<List<Media>> search(String query, {int page = 1}) async => const [];

  @override
  Future<List<Media>> userList(ListStatus status) =>
      status == ListStatus.current ? current : Future.value(const []);

  @override
  Future<void> updateProgress(Media media, int episode) async {}

  @override
  Future<TrackingAccount> connectAniList(String pasted) =>
      throw UnimplementedError();

  @override
  Future<void> disconnect(TrackingAccountService service) async {}
}

class _Catalog implements CatalogRepository {
  _Catalog([this.expanded = const []]);

  final List<Media> expanded;
  final List<MediaBrowseQuery> queries = [];

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) async {
    queries.add(query);
    return MediaPage(items: expanded, hasNextPage: false);
  }

  @override
  Future<Media?> mediaById(int id) async => null;

  @override
  Future<List<Media>> similar(int mediaId) async => const [];
}

Media _media(
  int id,
  String title, {
  List<String> genres = const [],
  int? episodes,
  int? score,
  ListEntry? entry,
}) => Media(
  id: id,
  title: MediaTitle(userPreferred: title),
  genres: genres,
  episodes: episodes,
  averageScore: score,
  listEntry: entry,
);

WatchHistoryEntry _history(Media media, {required int through}) =>
    WatchHistoryEntry(
      media: media,
      watchedThrough: through,
      updatedAt: DateTime.now(),
    );

void main() {
  final home = HomeFeed(
    hero: const [],
    trending: [
      _media(10, 'Action Pick', genres: const ['Action'], score: 82),
      _media(11, 'Drama Pick', genres: const ['Drama'], score: 90),
    ],
    newReleases: const [],
    popular: const [],
  );

  test(
    'local feed renders while tracker enrichment is still pending',
    () async {
      final trackerResult = Completer<List<Media>>();
      final local = _media(
        1,
        'Local Action',
        genres: const ['Action'],
        episodes: 12,
      );
      final trackerOnly = _media(
        2,
        'Tracker Drama',
        genres: const ['Drama'],
        episodes: 12,
        entry: const ListEntry(status: ListStatus.current, progress: 3),
      );
      final container = ProviderContainer(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(_Catalog()),
          trackingRepositoryProvider.overrideWithValue(
            _Tracking(trackerResult.future),
          ),
          homeFeedProvider.overrideWith((ref) async => home),
          watchHistoryRecentProvider.overrideWith(
            (ref) async => [_history(local, through: 4)],
          ),
        ],
      );
      addTearDown(container.dispose);
      await Future.wait([
        container.read(homeFeedProvider.future),
        container.read(watchHistoryRecentProvider.future),
      ]);

      final localFeed = container.read(personalizedHomeFeedProvider);
      expect(localFeed.continueWatching.single.media.id, 1);
      expect(localFeed.recommendations.first.id, 10);
      expect(container.read(trackerWatchingProvider).isLoading, isTrue);

      trackerResult.complete([trackerOnly]);
      await container.read(trackerWatchingProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(
        container
            .read(personalizedHomeFeedProvider)
            .continueWatching
            .map((item) => item.media.id),
        [1, 2],
      );
    },
  );

  test('genre candidates enrich the row after the base feed renders', () async {
    final expanded = _media(
      20,
      'Expanded Action Pick',
      genres: const ['Action'],
      score: 95,
    );
    final catalog = _Catalog([expanded]);
    final local = _media(
      1,
      'Established Action',
      genres: const ['Action'],
      episodes: 12,
    );
    final container = ProviderContainer(
      overrides: [
        catalogRepositoryProvider.overrideWithValue(catalog),
        trackingRepositoryProvider.overrideWithValue(
          _Tracking(Future.value(const [])),
        ),
        homeFeedProvider.overrideWith((ref) async => home),
        watchHistoryRecentProvider.overrideWith(
          (ref) async => [_history(local, through: 12)],
        ),
      ],
    );
    addTearDown(container.dispose);
    await Future.wait([
      container.read(homeFeedProvider.future),
      container.read(watchHistoryRecentProvider.future),
    ]);

    container.read(personalizedHomeFeedProvider);
    await container.read(personalizedGenreCandidatesProvider('Action').future);
    await Future<void>.delayed(Duration.zero);

    final enriched = container.read(personalizedHomeFeedProvider);
    expect(enriched.recommendations.map((media) => media.id), contains(20));
    expect(catalog.queries.single.genres, ['Action']);
  });
}
