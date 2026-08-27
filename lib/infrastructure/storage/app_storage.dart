import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/database.dart';

/// Resolves durable and disposable application storage and migrates the cache
/// layout used before they were separated.
class AppStoragePaths {
  const AppStoragePaths({
    required this.supportDirectory,
    required this.cacheDirectory,
  });

  final String supportDirectory;
  final String cacheDirectory;

  static Future<AppStoragePaths> resolve() async {
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    return AppStoragePaths(
      supportDirectory: support.path,
      cacheDirectory: cache.path,
    );
  }

  String get profileDatabase =>
      DatabasePaths.profile(supportDirectory, 'default');
  String get sharedDatabase => DatabasePaths.shared(cacheDirectory);
  String get learningDatabase => DatabasePaths.learning(supportDirectory);
  String get learningSubtitleCacheDirectory =>
      p.join(cacheDirectory, 'learning-subtitles');

  String get _legacySharedDatabase => DatabasePaths.shared(supportDirectory);
  String get _legacyLearningSubtitleCacheDirectory =>
      p.join(supportDirectory, 'cache', 'learning-subtitles');

  /// Moves caches written by older releases out of application support.
  ///
  /// Cache migration is deliberately best-effort. A failure must not prevent
  /// startup: the shared database and downloaded Jimaku subtitles can both be
  /// rebuilt. Warnings are returned so the composition root can log them after
  /// its log sink has been opened.
  Future<List<String>> migrateLegacyCaches() async {
    final warnings = <String>[];
    final targetSharedExisted = await File(sharedDatabase).exists();

    try {
      await _migrateSqliteFamily(
        sourcePath: _legacySharedDatabase,
        targetPath: sharedDatabase,
      );
    } catch (error) {
      // Never discard an already-established cache in the new location just
      // because cleanup of the legacy copy failed.
      if (!targetSharedExisted) {
        await _tryDeleteSqliteFamily(sharedDatabase);
      }
      await _tryDeleteSqliteFamily(_legacySharedDatabase);
      warnings.add('Shared query cache migration was reset: $error');
    }

    try {
      await _mergeCacheDirectory(
        source: Directory(_legacyLearningSubtitleCacheDirectory),
        target: Directory(learningSubtitleCacheDirectory),
      );
      await _deleteDirectoryIfEmpty(
        Directory(p.join(supportDirectory, 'cache')),
      );
    } catch (error) {
      warnings.add('Learning subtitle cache migration was incomplete: $error');
    }

    return warnings;
  }
}

const _sqliteSidecars = ['-wal', '-shm'];

Future<void> _migrateSqliteFamily({
  required String sourcePath,
  required String targetPath,
}) async {
  final source = File(sourcePath);
  final target = File(targetPath);

  if (await target.exists()) {
    // The current layout is authoritative. This also makes migration
    // idempotent after a prior run completed but legacy cleanup did not.
    await _deleteSqliteFamily(sourcePath);
    return;
  }

  if (!await source.exists()) {
    // Old crashes may have left SQLite sidecars without a main database.
    await _deleteSqliteSidecars(sourcePath);
    return;
  }

  await target.parent.create(recursive: true);
  await _deleteSqliteSidecars(targetPath);

  // Move WAL state before the main file so the destination is not considered
  // complete until every part of the database family has moved.
  for (final suffix in _sqliteSidecars) {
    final oldSidecar = File('$sourcePath$suffix');
    if (await oldSidecar.exists()) {
      await _moveFile(oldSidecar, File('$targetPath$suffix'));
    }
  }
  await _moveFile(source, target);
  await _deleteDirectoryIfEmpty(source.parent);
}

Future<void> _mergeCacheDirectory({
  required Directory source,
  required Directory target,
}) async {
  if (!await source.exists()) return;
  await target.create(recursive: true);

  await for (final entity in source.list(followLinks: false)) {
    final destinationPath = p.join(target.path, p.basename(entity.path));

    if (entity is Directory) {
      final destinationType = await FileSystemEntity.type(
        destinationPath,
        followLinks: false,
      );
      if (destinationType == FileSystemEntityType.notFound ||
          destinationType == FileSystemEntityType.directory) {
        await _mergeCacheDirectory(
          source: entity,
          target: Directory(destinationPath),
        );
      } else {
        // A cache entry already in the new layout always wins a conflict.
        await entity.delete(recursive: true);
      }
      continue;
    }

    if (entity is File) {
      final destinationType = await FileSystemEntity.type(
        destinationPath,
        followLinks: false,
      );
      if (destinationType == FileSystemEntityType.notFound) {
        await _moveFile(entity, File(destinationPath));
      } else {
        await entity.delete();
      }
      continue;
    }

    // Cache directories must not preserve or follow links from an old layout.
    if (entity is Link) await entity.delete();
  }

  await _deleteDirectoryIfEmpty(source);
}

Future<void> _moveFile(File source, File target) async {
  await target.parent.create(recursive: true);
  try {
    await source.rename(target.path);
  } on FileSystemException {
    // Application support and cache can be different filesystems on unusual
    // installations, where rename is not available.
    await source.copy(target.path);
    await source.delete();
  }
}

Future<void> _deleteSqliteSidecars(String databasePath) async {
  for (final suffix in _sqliteSidecars) {
    final file = File('$databasePath$suffix');
    if (await file.exists()) await file.delete();
  }
}

Future<void> _deleteSqliteFamily(String databasePath) async {
  final database = File(databasePath);
  if (await database.exists()) await database.delete();
  await _deleteSqliteSidecars(databasePath);
  await _deleteDirectoryIfEmpty(database.parent);
}

Future<void> _tryDeleteSqliteFamily(String databasePath) async {
  try {
    await _deleteSqliteFamily(databasePath);
  } on FileSystemException {
    // Cleanup is already part of error recovery. The original migration error
    // is more useful to the caller than a secondary deletion failure.
  }
}

Future<void> _deleteDirectoryIfEmpty(Directory directory) async {
  if (!await directory.exists()) return;
  if (await directory.list(followLinks: false).isEmpty) {
    await directory.delete();
  }
}
