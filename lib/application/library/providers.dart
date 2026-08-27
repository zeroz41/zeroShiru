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

final homeFeedProvider = FutureProvider<HomeFeed>((ref) {
  return loadHomeFeed(ref.watch(catalogRepositoryProvider));
});

final personalizedHomeFeedProvider = FutureProvider<PersonalizedHomeFeed>((
  ref,
) async {
  final tracking = ref.watch(trackingRepositoryProvider);
  final home = await ref.watch(homeFeedProvider.future);
  return loadPersonalizedHomeFeed(tracking, home);
});

final trackingAccountsProvider = FutureProvider<List<TrackingAccount>>((ref) {
  return ref.watch(trackingRepositoryProvider).accounts();
});

final upcomingScheduleProvider = FutureProvider<List<Media>>((ref) {
  return loadUpcomingSchedule(ref.watch(catalogRepositoryProvider));
});
