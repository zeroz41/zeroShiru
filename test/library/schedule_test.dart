import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/library/schedule.dart';
import 'package:zero/domain/models/catalog.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/ports/catalog_repository.dart';

Media _media(
  int id,
  String title, {
  required DateTime? airingAt,
  int episode = 1,
}) => Media(
  id: id,
  title: MediaTitle(userPreferred: title),
  format: MediaFormat.tv,
  status: MediaStatus.releasing,
  nextAiringEpisode: airingAt == null
      ? null
      : AiringEpisode(episode: episode, airingAt: airingAt),
);

class _Catalog implements CatalogRepository {
  _Catalog(this.pages);

  final Map<int, MediaPage> pages;
  final queries = <MediaBrowseQuery>[];

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) async {
    queries.add(query);
    return pages[query.page] ?? const MediaPage(items: [], hasNextPage: false);
  }

  @override
  Future<Media?> mediaById(int id) async => null;

  @override
  Future<List<Media>> similar(int mediaId) async => const [];
}

void main() {
  test(
    'schedule paginates, filters, de-duplicates, and sorts airings',
    () async {
      final now = DateTime.utc(2026, 8, 24, 12);
      final later = _media(
        2,
        'Later',
        airingAt: now.add(const Duration(days: 1)),
        episode: 8,
      );
      final sooner = _media(
        1,
        'Sooner',
        airingAt: now.add(const Duration(hours: 2)),
        episode: 4,
      );
      final catalog = _Catalog({
        1: MediaPage(
          items: [later, _media(9, 'Unknown', airingAt: null)],
          hasNextPage: true,
        ),
        2: MediaPage(
          items: [
            sooner,
            later,
            _media(
              10,
              'Already aired',
              airingAt: now.subtract(const Duration(minutes: 1)),
            ),
          ],
          hasNextPage: false,
        ),
      });

      final schedule = await loadUpcomingSchedule(catalog, now: now);

      expect(schedule.map((media) => media.id), [1, 2]);
      expect(catalog.queries.map((query) => query.page), [1, 2]);
      for (final query in catalog.queries) {
        expect(query.perPage, 50);
        expect(query.sort, MediaSort.popularity);
        expect(query.statuses, [MediaStatus.releasing]);
        expect(query.formats, [MediaFormat.tv, MediaFormat.tvShort]);
      }
    },
  );

  test('schedule stops at the request cap even if a provider loops', () async {
    final now = DateTime.utc(2026, 8, 24);
    final catalog = _Catalog({
      for (var page = 1; page <= 6; page++)
        page: MediaPage(
          items: [
            _media(page, 'Show $page', airingAt: now.add(Duration(days: page))),
          ],
          hasNextPage: true,
        ),
    });

    final schedule = await loadUpcomingSchedule(
      catalog,
      now: now,
      pageLimit: 2,
    );

    expect(schedule, hasLength(2));
    expect(catalog.queries, hasLength(2));
  });
}
