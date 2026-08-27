/// Remaining capability ports. Implementations live under infrastructure/;
/// screens depend only on these interfaces via application/ controllers.
library;

import '../models/media.dart';
import '../models/settings.dart';
import '../models/source_extension.dart';
import '../models/tracking_account.dart';
import '../models/torrent.dart';

export 'catalog_repository.dart';
export 'app_log.dart';
export 'debrid_client.dart';
export 'episode_repository.dart';
export 'language_learning.dart';
export 'learning_subtitles.dart';
export 'media_engine.dart';

/// Runs source searches (declarative manifests) and merges results.
abstract interface class SourceResolver {
  Future<SourceCatalog> catalog();
  Future<SourceCatalog> install(String source);
  Future<SourceCatalog> remove(String source);
  Future<SourceCatalog> setEnabled(String id, bool enabled);
  Future<SourceCatalog> updateSettings(
    String id,
    Map<String, Object?> settings,
  );
  Future<bool> validate(String id);

  Stream<SourceSearchBatch> search(TorrentQuery query, {bool movie = false});
}

/// AniList/MAL behind one surface.
abstract interface class TrackingRepository {
  Future<List<TrackingAccount>> accounts();
  Future<Media?> mediaById(int id);
  Future<List<Media>> search(String query, {int page = 1});
  Future<List<Media>> userList(ListStatus status);

  /// Apply the watch-counts rules (never move progress backward, zero-episode
  /// offset, completion/repeat handling) and queue the mutation offline-safely.
  Future<void> updateProgress(Media media, int episode);
}

abstract interface class SettingsRepository {
  T read<T>(String key, T fallback);
  Future<void> write<T>(String key, T value);
  Stream<void> get changes;

  Settings readSettings();
  Future<void> writeSettings(Settings settings);
}

abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Streaming torrent engine + loopback Range gateway (pure Dart, phase 6).
abstract interface class TorrentEngine {
  Future<List<PlayerFile>> stream(String idOrMagnet);
  Future<void> unload();
  Future<Map<String, ({int seeders, int leechers})>> scrape(
    List<String> hashes,
  );
}
