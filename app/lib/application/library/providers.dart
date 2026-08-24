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

final homeFeedProvider = FutureProvider<HomeFeed>((ref) {
  return loadHomeFeed(ref.watch(catalogRepositoryProvider));
});

final trackingAccountsProvider = FutureProvider<List<TrackingAccount>>((ref) {
  return ref.watch(trackingRepositoryProvider).accounts();
});

final upcomingScheduleProvider = FutureProvider<List<Media>>((ref) {
  return loadUpcomingSchedule(ref.watch(catalogRepositoryProvider));
});
