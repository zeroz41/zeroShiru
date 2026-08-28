import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/library/home_feed.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/tracking_account.dart';
import 'package:zero/domain/ports/ports.dart';

class _WatchingRepository implements TrackingRepository {
  _WatchingRepository([this.watching = const []]);

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

class _FailingRepository extends _WatchingRepository {
  @override
  Future<List<Media>> userList(ListStatus status) async =>
      throw StateError('tracker offline');
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

WatchHistoryEntry _history(
  Media media, {
  int through = 0,
  EpisodeWatchProgress? resume,
}) => WatchHistoryEntry(
  media: media,
  watchedThrough: through,
  resume: resume,
  updatedAt: DateTime(2026, 8, 27),
);

void main() {
  final home = HomeFeed(
    hero: const [],
    trending: [
      _media(201, 'Trendy Action', genres: const ['Action'], score: 80),
      _media(202, 'Quiet Drama', genres: const ['Drama'], score: 90),
    ],
    newReleases: [
      _media(203, 'Fresh Fantasy', genres: const ['Fantasy'], score: 70),
    ],
    popular: const [],
  );

  test(
    'local history alone fills Continue Watching and recommendations',
    () async {
      final feed = await loadPersonalizedHomeFeed(
        _WatchingRepository(),
        home,
        localHistory: [
          _history(
            _media(
              1,
              'Watched Locally',
              genres: const ['Action'],
              episodes: 12,
            ),
            through: 3,
          ),
        ],
      );

      final slot = feed.continueWatching.single;
      expect(slot.media.id, 1);
      expect(slot.media.listEntry!.progress, 3);
      expect(slot.media.listEntry!.status, ListStatus.current);
      expect(slot.episode, 4);
      expect(slot.resumeProgress, isNull);
      expect(feed.favoriteGenres, ['Action']);
      expect(feed.recommendations.map((media) => media.id), [201, 202, 203]);
    },
  );

  test(
    'local entries lead, tracker-only shows follow, duplicates collapse',
    () async {
      final shared = _media(
        1,
        'Both Sides',
        genres: const ['Action'],
        episodes: 12,
        entry: const ListEntry(status: ListStatus.current, progress: 9),
      );
      final trackerOnly = _media(
        2,
        'Tracker Only',
        genres: const ['Drama'],
        episodes: 24,
        entry: const ListEntry(status: ListStatus.current, progress: 2),
      );
      final feed = await loadPersonalizedHomeFeed(
        _WatchingRepository([shared, trackerOnly]),
        home,
        localHistory: [_history(shared.withListEntry(null), through: 4)],
      );

      expect(feed.continueWatching.map((item) => item.media.id), [1, 2]);
      // The local snapshot leads the rail even when the tracker is ahead.
      expect(feed.continueWatching.first.media.listEntry!.progress, 4);
      // Tracker-only shows resume at the episode after their tracked progress.
      expect(feed.continueWatching.last.episode, 3);
    },
  );

  test('finished shows and barely-started shows stay off the rail', () async {
    final feed = await loadPersonalizedHomeFeed(
      _WatchingRepository(),
      home,
      localHistory: [
        _history(_media(1, 'Done', episodes: 12), through: 12),
        _history(_media(2, 'Barely Opened', episodes: 12)),
        _history(
          _media(3, 'Mid Episode', episodes: 12),
          resume: EpisodeWatchProgress(
            mediaId: 3,
            episode: 1,
            position: const Duration(minutes: 9),
            duration: const Duration(minutes: 24),
            completed: false,
            updatedAt: DateTime(2026, 8, 27),
          ),
        ),
      ],
    );

    final slot = feed.continueWatching.single;
    expect(slot.media.id, 3);
    // The mid-episode slot resumes its own episode with the watched fraction.
    expect(slot.episode, 1);
    expect(slot.resumeProgress, closeTo(9 / 24, 0.001));
  });

  test('a tracker outage never empties the local rails', () async {
    final feed = await loadPersonalizedHomeFeed(
      _FailingRepository(),
      home,
      localHistory: [
        _history(
          _media(1, 'Local Show', genres: const ['Fantasy'], episodes: 12),
          through: 2,
        ),
      ],
    );

    expect(feed.continueWatching.single.media.id, 1);
    expect(feed.recommendations.first.id, 203);
  });

  test('watched shows are excluded from recommendations', () async {
    final feed = await loadPersonalizedHomeFeed(
      _WatchingRepository(),
      home,
      localHistory: [
        _history(
          _media(201, 'Trendy Action', genres: const ['Action'], episodes: 12),
          through: 1,
        ),
      ],
    );

    expect(feed.recommendations.map((media) => media.id), isNot(contains(201)));
  });

  test('a focused slice-of-life profile still gets discovery picks', () async {
    final variedHome = HomeFeed(
      hero: const [],
      trending: [
        _media(301, 'Pure Slice', genres: const ['Slice of Life'], score: 82),
        _media(
          302,
          'Funny Slice',
          genres: const ['Slice of Life', 'Comedy'],
          score: 90,
        ),
        _media(
          303,
          'Romantic Slice',
          genres: const ['Slice of Life', 'Romance'],
          score: 88,
        ),
        _media(
          304,
          'Dramatic Slice',
          genres: const ['Slice of Life', 'Drama'],
          score: 86,
        ),
        _media(305, 'Action Discovery', genres: const ['Action'], score: 91),
        _media(306, 'Mystery Discovery', genres: const ['Mystery'], score: 89),
      ],
      newReleases: const [],
      popular: const [],
    );
    final feed = await loadPersonalizedHomeFeed(
      _WatchingRepository(),
      variedHome,
      localHistory: [
        for (var id = 1; id <= 4; id++)
          _history(
            _media(
              id,
              'Slice Favorite $id',
              genres: const ['Slice of Life'],
              episodes: 12,
            ),
            through: 12,
          ),
      ],
      now: DateTime(2026, 8, 27),
    );

    expect(feed.favoriteGenres, ['Slice of Life']);
    expect(
      feed.recommendations.take(4),
      everyElement(
        isA<Media>().having(
          (media) => media.genres,
          'genres',
          contains('Slice of Life'),
        ),
      ),
    );
    expect(feed.recommendations[4].genres, isNot(contains('Slice of Life')));
  });

  test('one brief play stays a low-confidence taste signal', () {
    final cautiousHome = HomeFeed(
      hero: const [],
      trending: [
        _media(311, 'Action One', genres: const ['Action'], score: 82),
        _media(312, 'Action Two', genres: const ['Action'], score: 80),
        _media(313, 'Drama Discovery', genres: const ['Drama'], score: 91),
        _media(314, 'Comedy Discovery', genres: const ['Comedy'], score: 89),
      ],
      newReleases: const [],
      popular: const [],
    );
    final brieflyPlayed = _media(
      1,
      'Brief Action',
      genres: const ['Action'],
      episodes: 12,
    );
    final feed = buildPersonalizedHomeFeed(
      cautiousHome,
      localHistory: [
        _history(
          brieflyPlayed,
          resume: EpisodeWatchProgress(
            mediaId: brieflyPlayed.id,
            episode: 1,
            position: const Duration(minutes: 1),
            duration: const Duration(minutes: 24),
            completed: false,
            updatedAt: DateTime(2026, 8, 27),
          ),
        ),
      ],
      now: DateTime(2026, 8, 27),
    );

    expect(feed.favoriteGenres, isEmpty);
    expect(
      feed.recommendations.take(2),
      everyElement(
        isA<Media>().having(
          (media) => media.genres,
          'genres',
          contains('Action'),
        ),
      ),
    );
    expect(feed.recommendations[2].genres, isNot(contains('Action')));
  });

  test('a watched franchise is suppressed across season IDs', () {
    final watchedSeason = _media(
      1,
      'Shingeki no Kyojin Season 2',
      genres: const ['Action'],
      episodes: 12,
    );
    final feed = buildPersonalizedHomeFeed(
      HomeFeed(
        hero: const [],
        trending: [
          _media(
            321,
            'Shingeki no Kyojin',
            genres: const ['Action'],
            score: 84,
          ),
          _media(
            322,
            'Shingeki no Kyojin: The Final Season',
            genres: const ['Action'],
            score: 90,
          ),
          _media(323, 'Different Action', genres: const ['Action'], score: 80),
        ],
        newReleases: const [],
        popular: const [],
      ),
      localHistory: [_history(watchedSeason, through: 4)],
      now: DateTime(2026, 8, 27),
    );

    expect(
      feed.recommendations.where(
        (media) => media.title.display.startsWith('Shingeki no Kyojin'),
      ),
      isEmpty,
    );
    expect(feed.recommendations.map((media) => media.id), contains(323));
  });

  test('seasons from one franchise do not flood recommendations', () async {
    final franchiseHome = HomeFeed(
      hero: const [],
      trending: [
        _media(401, 'Shingeki no Kyojin', genres: const ['Action'], score: 84),
        _media(
          402,
          'Shingeki no Kyojin Season 3',
          genres: const ['Action'],
          score: 90,
        ),
        _media(
          403,
          'Shingeki no Kyojin: The Final Season',
          genres: const ['Action'],
          score: 89,
        ),
        _media(404, 'Different Action', genres: const ['Action'], score: 80),
        _media(405, '葬送のフリーレン', genres: const ['Action'], score: 88),
        _media(406, '薬屋のひとりごと', genres: const ['Action'], score: 87),
      ],
      newReleases: const [],
      popular: const [],
    );
    final feed = await loadPersonalizedHomeFeed(
      _WatchingRepository([
        _media(
          1,
          'Current Action',
          genres: const ['Action'],
          episodes: 12,
          entry: const ListEntry(status: ListStatus.current, progress: 6),
        ),
      ]),
      franchiseHome,
    );

    expect(
      feed.recommendations.where(
        (media) => media.title.display.startsWith('Shingeki no Kyojin'),
      ),
      hasLength(1),
    );
    expect(feed.recommendations.map((media) => media.id), contains(401));
    expect(
      feed.recommendations.map((media) => media.id),
      containsAll([405, 406]),
    );
  });
}
