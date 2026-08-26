import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../application/playback/backend.dart';
import '../../application/playback/preferences.dart';
import '../../domain/ports/ports.dart';
import '../database/database.dart';
import '../database/query_cache_impl.dart';
import '../database/settings_repository_impl.dart';
import '../debrid/debrid_client_impl.dart';
import '../learning/local_japanese_learning_tools.dart';
import '../learning/jimaku_learning_subtitle_repository.dart';
import '../media/media_kit_playback_backend.dart';
import '../network/http_transport_impl.dart';
import '../network/http_streaming_transport.dart';
import '../network/ssrf_guard.dart';
import '../platform/credential_store_impl.dart';
import '../platform/log_sink.dart';
import '../sources/native_source_resolver.dart';
import '../tracking/anilist_catalog_repository.dart';
import '../tracking/anilist_client.dart';
import '../tracking/ani_zip_episode_repository.dart';
import '../tracking/auth.dart';
import '../tracking/mal_client.dart';
import '../tracking/tracking_repository_impl.dart';

/// Owns the long-lived infrastructure graph for one app process.
class AppServices {
  AppServices._({
    required this.catalog,
    required this.episodes,
    required this.tracking,
    required this.settings,
    required this.credentials,
    required this.playback,
    required this.debrid,
    required this.log,
    required this.playbackProbe,
    required this.sources,
    required this.learning,
    required this.learningSubtitles,
    required this._profileDatabase,
    required this._sharedDatabase,
    required this._queryCache,
    required this._transport,
  });

  final CatalogRepository catalog;
  final EpisodeRepository episodes;
  final TrackingRepository tracking;
  final SettingsRepository settings;
  final CredentialStore credentials;
  final PlaybackBackend playback;
  final Map<DebridService, DebridClient> debrid;
  final FileLogSink log;
  final IoStreamingTransport playbackProbe;
  final SourceResolver sources;
  final LanguageLearningTools learning;
  final LearningSubtitleRepository learningSubtitles;

  final AppDatabase _profileDatabase;
  final AppDatabase _sharedDatabase;
  final SqliteQueryCache _queryCache;
  final PackageHttpTransport _transport;
  Future<void>? _closeFuture;

  static Future<AppServices> open() async {
    final support = await getApplicationSupportDirectory();
    final databases = openAppDatabases(supportDirectory: support.path);
    final queryCache = SqliteQueryCache(
      profile: databases.profile,
      shared: databases.shared,
    );
    final transport = PackageHttpTransport();
    final playbackProbe = IoStreamingTransport();
    final credentials = SecureCredentialStore();
    final settings = SqliteSettingsRepository(databases.profile);
    final learning = LocalJapaneseLearningTools(
      databasePath: DatabasePaths.learning(support.path),
      transport: GuardedHttpTransport(
        transport,
        maxBodyBytes: 64 * 1024 * 1024,
      ),
    );
    final learningSubtitles = JimakuLearningSubtitleRepository(
      cacheDirectory: p.join(support.path, 'cache', 'learning-subtitles'),
      transport: GuardedHttpTransport(
        transport,
        maxBodyBytes: 16 * 1024 * 1024,
      ),
    );
    final sources = NativeSourceResolver(
      transport: GuardedHttpTransport(transport),
      settings: settings,
    );
    final auth = TrackingAuthStore(credentials);
    final anilist = AnilistClient(transport: transport, cache: queryCache);
    final mal = MalClient(transport: transport);
    final playback = MediaKitPlaybackBackend(
      preferences: () {
        final current = settings.readSettings();
        return playbackPreferencesFor(current);
      },
    );
    final debrid = {
      for (final service in debridServices)
        service: ProviderDebridClient(service, transport),
    };

    return AppServices._(
      catalog: AnilistCatalogRepository(anilist),
      episodes: AniZipEpisodeRepository(transport),
      tracking: TrackingRepositoryImpl(anilist: anilist, mal: mal, auth: auth),
      settings: settings,
      credentials: credentials,
      playback: playback,
      debrid: debrid,
      log: FileLogSink(support.path),
      playbackProbe: playbackProbe,
      sources: sources,
      learning: learning,
      learningSubtitles: learningSubtitles,
      profileDatabase: databases.profile,
      sharedDatabase: databases.shared,
      queryCache: queryCache,
      transport: transport,
    );
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    try {
      await Future.wait([
        playback.dispose(),
        learning.dispose(),
      ], eagerError: false);
    } finally {
      if (settings case final SqliteSettingsRepository repository) {
        repository.dispose();
      }
      _queryCache.dispose();
      _transport.close();
      playbackProbe.close();
      _profileDatabase.close();
      _sharedDatabase.close();
      log.close();
    }
  }
}
