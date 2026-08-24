import 'package:path_provider/path_provider.dart';

import '../../domain/ports/ports.dart';
import '../database/database.dart';
import '../database/query_cache_impl.dart';
import '../database/settings_repository_impl.dart';
import '../network/http_transport_impl.dart';
import '../platform/credential_store_impl.dart';
import '../platform/log_sink.dart';
import '../tracking/anilist_catalog_repository.dart';
import '../tracking/anilist_client.dart';
import '../tracking/auth.dart';
import '../tracking/mal_client.dart';
import '../tracking/tracking_repository_impl.dart';

/// Owns the long-lived infrastructure graph for one app process.
class AppServices {
  AppServices._({
    required this.catalog,
    required this.tracking,
    required this.settings,
    required this.credentials,
    required this.log,
    required this._profileDatabase,
    required this._sharedDatabase,
    required this._queryCache,
    required this._transport,
  });

  final CatalogRepository catalog;
  final TrackingRepository tracking;
  final SettingsRepository settings;
  final CredentialStore credentials;
  final FileLogSink log;

  final AppDatabase _profileDatabase;
  final AppDatabase _sharedDatabase;
  final SqliteQueryCache _queryCache;
  final PackageHttpTransport _transport;

  static Future<AppServices> open() async {
    final support = await getApplicationSupportDirectory();
    final databases = openAppDatabases(supportDirectory: support.path);
    final queryCache = SqliteQueryCache(
      profile: databases.profile,
      shared: databases.shared,
    );
    final transport = PackageHttpTransport();
    final credentials = SecureCredentialStore();
    final auth = TrackingAuthStore(credentials);
    final anilist = AnilistClient(transport: transport, cache: queryCache);
    final mal = MalClient(transport: transport);

    return AppServices._(
      catalog: AnilistCatalogRepository(anilist),
      tracking: TrackingRepositoryImpl(anilist: anilist, mal: mal, auth: auth),
      settings: SqliteSettingsRepository(databases.profile),
      credentials: credentials,
      log: FileLogSink(support.path),
      profileDatabase: databases.profile,
      sharedDatabase: databases.shared,
      queryCache: queryCache,
      transport: transport,
    );
  }

  void close() {
    if (settings case final SqliteSettingsRepository repository) {
      repository.dispose();
    }
    _queryCache.dispose();
    _transport.close();
    _profileDatabase.close();
    _sharedDatabase.close();
    log.close();
  }
}
