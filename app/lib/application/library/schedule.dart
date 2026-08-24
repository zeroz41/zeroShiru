import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../../domain/ports/catalog_repository.dart';

/// Upper bound for a schedule refresh. AniList normally returns all currently
/// releasing TV anime in one or two pages; the cap prevents a bad provider
/// response from turning a refresh into an unbounded request loop.
const schedulePageLimit = 4;

/// Loads future TV airings and orders them by broadcast time.
///
/// Pagination and de-duplication live outside the widget so every catalogue
/// adapter gets the same schedule semantics and the behavior can be tested
/// without a Flutter binding.
Future<List<Media>> loadUpcomingSchedule(
  CatalogRepository catalog, {
  DateTime? now,
  int pageLimit = schedulePageLimit,
}) async {
  assert(pageLimit > 0);
  final referenceTime = now ?? DateTime.now();
  final byId = <int, Media>{};
  var pageNumber = 1;
  var hasNextPage = true;

  while (hasNextPage && pageNumber <= pageLimit) {
    final page = await catalog.browse(
      MediaBrowseQuery(
        page: pageNumber,
        perPage: 50,
        sort: MediaSort.popularity,
        formats: const [MediaFormat.tv, MediaFormat.tvShort],
        statuses: const [MediaStatus.releasing],
      ),
    );
    for (final media in page.items) {
      byId.putIfAbsent(media.id, () => media);
    }
    hasNextPage = page.hasNextPage && page.items.isNotEmpty;
    pageNumber++;
  }

  final upcoming =
      byId.values
          .where((media) {
            final airingAt = media.nextAiringEpisode?.airingAt;
            return airingAt != null && airingAt.isAfter(referenceTime);
          })
          .toList(growable: false)
        ..sort((a, b) {
          final airing = a.nextAiringEpisode!.airingAt.compareTo(
            b.nextAiringEpisode!.airingAt,
          );
          if (airing != 0) return airing;
          final title = a.title.display.compareTo(b.title.display);
          return title != 0 ? title : a.id.compareTo(b.id);
        });

  return upcoming;
}
