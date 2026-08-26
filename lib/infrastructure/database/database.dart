/// SQLite persistence for the Flutter host.
///
/// Application data mirrors the redo branch's IndexedDB split: a per-profile
/// database (user-owned stores, settings kv) and a shared database (query
/// caches every profile benefits from). A third rebuildable file holds the
/// optional language dictionary. Paths are passed in by the caller — production
/// hands in the path_provider application-support directory, tests hand in
/// nothing and use [AppDatabase.inMemory].
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Bump when adding a migration to [_migrations].
const int schemaVersion = 1;

/// One migration step. Runs inside a transaction; the journal row is written
/// by the caller.
typedef Migration = void Function(Database db);

const Map<int, Migration> _migrations = {1: _createInitialSchema};

void _createInitialSchema(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS cache (
      store TEXT NOT NULL,
      key TEXT NOT NULL,
      value TEXT NOT NULL,
      stored_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      PRIMARY KEY (store, key)
    )
  ''');
  // Pruning deletes the oldest rows of one store; this index is that scan.
  db.execute(
    'CREATE INDEX IF NOT EXISTS cache_store_age ON cache (store, stored_at)',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS kv (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
}

/// A migrated SQLite database. Owns the handle; [close] disposes it.
class AppDatabase {
  /// Wraps an already-open handle (tests hand in `sqlite3.openInMemory()`)
  /// and brings its schema up to [schemaVersion].
  AppDatabase(this.db) {
    _migrate(db);
  }

  /// Opens (creating directories as needed) a database file and migrates it.
  factory AppDatabase.open(String path) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final db = sqlite3.open(path);
    // WAL keeps readers (the UI thread) unblocked by writes; NORMAL sync is
    // safe under WAL and avoids an fsync per cache write.
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    return AppDatabase(db);
  }

  /// A fresh in-memory database, for tests.
  factory AppDatabase.inMemory() => AppDatabase(sqlite3.openInMemory());

  final Database db;

  void close() => db.close();

  static void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS migrations (
        version INTEGER PRIMARY KEY,
        applied_at INTEGER NOT NULL
      )
    ''');
    final applied = <int>{
      for (final row in db.select('SELECT version FROM migrations'))
        row['version'] as int,
    };
    db.execute('BEGIN');
    try {
      for (var version = 1; version <= schemaVersion; version++) {
        if (applied.contains(version)) continue;
        final migration = _migrations[version];
        if (migration == null) {
          throw StateError(
            'no migration registered for schema version $version',
          );
        }
        migration(db);
        db.execute(
          'INSERT INTO migrations (version, applied_at) VALUES (?, ?)',
          [version, DateTime.now().millisecondsSinceEpoch],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

/// The standard file layout under the application-support directory.
abstract final class DatabasePaths {
  static String profile(String supportDirectory, String profileId) =>
      p.join(supportDirectory, 'db', 'profile-$profileId.db');

  static String shared(String supportDirectory) =>
      p.join(supportDirectory, 'db', 'shared.db');

  /// Rebuildable, profile-independent language dictionary cache.
  static String learning(String supportDirectory) =>
      p.join(supportDirectory, 'db', 'learning.db');
}

/// Opens the per-profile and shared databases under [supportDirectory]
/// (production passes the path_provider application-support directory).
({AppDatabase profile, AppDatabase shared}) openAppDatabases({
  required String supportDirectory,
  String profileId = 'default',
}) {
  return (
    profile: AppDatabase.open(
      DatabasePaths.profile(supportDirectory, profileId),
    ),
    shared: AppDatabase.open(DatabasePaths.shared(supportDirectory)),
  );
}
