import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/media.dart';
import '../../domain/models/tracking_account.dart';
import '../../domain/ports/ports.dart';
import 'home_feed.dart';
import 'schedule.dart';

/// Composition-root overrides are installed by main.dart. Keeping these
/// ports here means feature widgets never import infrastructure adapters.
final catalogRepositoryProvider = Provider<CatalogRepository>((ref) {
  throw StateError('CatalogRepository was not installed at bootstrap');
});

final trackingRepositoryProvider = Provider<TrackingRepository>((ref) {
  throw StateError('TrackingRepository was not installed at bootstrap');
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw StateError('SettingsRepository was not installed at bootstrap');
});

final credentialStoreProvider = Provider<CredentialStore>((ref) {
  throw StateError('CredentialStore was not installed at bootstrap');
});

/// Optional because episode enrichment must never make the numbered episode
/// list disappear. Bootstrap installs the live mapping adapter; tests and
/// offline starts naturally receive the local fallback.
final episodeRepositoryProvider = Provider<EpisodeRepository?>((ref) => null);

final episodeMetadataProvider = FutureProvider.family<List<EpisodeInfo>, Media>(
  (ref, media) async {
    final repository = ref.watch(episodeRepositoryProvider);
    if (repository != null) {
      final episodes = await repository.episodes(media);
      if (episodes.isNotEmpty) return episodes;
    }
    return fallbackEpisodeMetadata(media);
  },
);

List<EpisodeInfo> fallbackEpisodeMetadata(Media media) => [
  for (var episode = 1; episode <= (media.maxEpisode ?? 1); episode++)
    EpisodeInfo(
      number: episode,
      imageUrl: media.bannerImage ?? media.coverImage,
      durationMinutes: media.duration,
    ),
];

/// Optional like [episodeRepositoryProvider]: rails and details degrade to
/// tracker-only (or no) progress when no local history store is installed,
/// which is also what keeps existing widget tests hermetic.
final watchHistoryProvider = Provider<WatchHistoryRepository?>((ref) => null);

final watchHistoryRecentProvider = FutureProvider<List<WatchHistoryEntry>>((
  ref,
) async {
  final history = ref.watch(watchHistoryProvider);
  if (history == null) return const [];
  final subscription = history.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return history.recent();
});

/// Highest locally-completed episode for one show; live against history
/// writes so the details modal and episode list update as episodes finish.
final localWatchedThroughProvider = FutureProvider.family<int, int>((
  ref,
  mediaId,
) async {
  final history = ref.watch(watchHistoryProvider);
  if (history == null) return 0;
  final subscription = history.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return history.watchedThrough(mediaId);
});

/// In-episode resume fractions for one show, keyed by episode number.
/// Completed episodes are excluded — rows already mark those as watched.
final episodeResumeProgressProvider =
    FutureProvider.family<Map<int, double>, int>((ref, mediaId) async {
      final history = ref.watch(watchHistoryProvider);
      if (history == null) return const {};
      final subscription = history.changes.listen((_) => ref.invalidateSelf());
      ref.onDispose(subscription.cancel);
      final rows = await history.progressForMedia(mediaId);
      return {
        for (final row in rows)
          if (!row.completed &&
              row.position >= minimumMeaningfulWatch &&
              row.fraction > 0)
            row.episode: row.fraction,
      };
    });

/// Community "more like this" for the details modal; SWR-cached beneath the
/// catalog port, so reopening a show is instant and offline-tolerant.
final similarMediaProvider = FutureProvider.family<List<Media>, int>((
  ref,
  mediaId,
) {
  return ref.watch(catalogRepositoryProvider).similar(mediaId);
});

final homeFeedProvider = FutureProvider<HomeFeed>((ref) {
  return loadHomeFeed(ref.watch(catalogRepositoryProvider));
});

/// Remote enrichment is deliberately separate from personalization. Home can
/// render local history immediately even while a tracker request is slow or
/// offline; this provider updates the derived feed whenever it eventually
/// settles.
final trackerWatchingProvider = FutureProvider<List<Media>>((ref) async {
  try {
    return await ref
        .watch(trackingRepositoryProvider)
        .userList(ListStatus.current);
  } catch (_) {
    return const [];
  }
});

/// One cached, non-blocking candidate page for the strongest established
/// genre. Family state means switching profiles/genres gets an independent
/// SWR cache key in the catalogue adapter.
final personalizedGenreCandidatesProvider =
    FutureProvider.family<List<Media>, String>((ref, genre) {
      return loadPersonalizedGenreCandidates(
        ref.watch(catalogRepositoryProvider),
        genre,
      );
    });

/// Synchronous derived state: cached Home and local history appear first,
/// then tracker and genre-candidate providers transparently enrich the row.
final personalizedHomeFeedProvider = Provider<PersonalizedHomeFeed>((ref) {
  final home = ref.watch(homeFeedProvider).value;
  if (home == null) return const PersonalizedHomeFeed();
  final history =
      ref.watch(watchHistoryRecentProvider).value ??
      const <WatchHistoryEntry>[];
  final watching = ref.watch(trackerWatchingProvider).value ?? const <Media>[];
  final base = buildPersonalizedHomeFeed(
    home,
    watching: watching,
    localHistory: history,
  );
  if (base.favoriteGenres.isEmpty) return base;

  final expanded = ref
      .watch(personalizedGenreCandidatesProvider(base.favoriteGenres.first))
      .value;
  if (expanded == null || expanded.isEmpty) return base;
  return buildPersonalizedHomeFeed(
    HomeFeed(
      hero: home.hero,
      trending: home.trending,
      newReleases: home.newReleases,
      popular: [...home.popular, ...expanded],
      genreSections: home.genreSections,
    ),
    watching: watching,
    localHistory: history,
  );
});

final trackingAccountsProvider = FutureProvider<List<TrackingAccount>>((ref) {
  return ref.watch(trackingRepositoryProvider).accounts();
});

final upcomingScheduleProvider = FutureProvider<List<Media>>((ref) {
  return loadUpcomingSchedule(ref.watch(catalogRepositoryProvider));
});
