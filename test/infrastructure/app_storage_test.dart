import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zero/infrastructure/database/database.dart';
import 'package:zero/infrastructure/storage/app_storage.dart';

void main() {
  late Directory root;
  late AppStoragePaths storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zero-storage-test-');
    storage = AppStoragePaths(
      supportDirectory: p.join(root.path, 'support'),
      cacheDirectory: p.join(root.path, 'cache'),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('keeps durable databases in support and caches in cache storage', () {
    expect(
      storage.profileDatabase,
      p.join(root.path, 'support', 'db', 'profile-default.db'),
    );
    expect(
      storage.learningDatabase,
      p.join(root.path, 'support', 'db', 'learning.db'),
    );
    expect(
      storage.sharedDatabase,
      p.join(root.path, 'cache', 'db', 'shared.db'),
    );
    expect(
      storage.learningSubtitleCacheDirectory,
      p.join(root.path, 'cache', 'learning-subtitles'),
    );
  });

  test('migrates the shared database and Jimaku cache exactly once', () async {
    final oldShared = DatabasePaths.shared(storage.supportDirectory);
    final oldDatabase = AppDatabase.open(oldShared);
    oldDatabase.db.execute(
      'INSERT INTO cache '
      '(store, key, value, stored_at, expires_at) VALUES (?, ?, ?, ?, ?)',
      ['shared', 'example', '{"cached":true}', 1, 2],
    );
    oldDatabase.close();

    final oldSubtitle = File(
      p.join(
        storage.supportDirectory,
        'cache',
        'learning-subtitles',
        'show',
        'episode-1.srt',
      ),
    );
    await oldSubtitle.parent.create(recursive: true);
    await oldSubtitle.writeAsString('legacy subtitle');

    expect(await storage.migrateLegacyCaches(), isEmpty);

    expect(await File(oldShared).exists(), isFalse);
    expect(await File(storage.sharedDatabase).exists(), isTrue);
    expect(await oldSubtitle.exists(), isFalse);
    final newSubtitle = File(
      p.join(storage.learningSubtitleCacheDirectory, 'show', 'episode-1.srt'),
    );
    expect(await newSubtitle.readAsString(), 'legacy subtitle');

    final migratedDatabase = AppDatabase.open(storage.sharedDatabase);
    final row = migratedDatabase.db.select(
      'SELECT value FROM cache WHERE store = ? AND key = ?',
      ['shared', 'example'],
    ).single;
    expect(row['value'], '{"cached":true}');
    migratedDatabase.close();

    expect(await storage.migrateLegacyCaches(), isEmpty);
    expect(await newSubtitle.readAsString(), 'legacy subtitle');
  });

  test('moves SQLite WAL and shared-memory sidecars with the cache', () async {
    final oldShared = DatabasePaths.shared(storage.supportDirectory);
    final oldFiles = {
      oldShared: 'database',
      '$oldShared-wal': 'wal',
      '$oldShared-shm': 'shm',
    };
    for (final entry in oldFiles.entries) {
      final file = File(entry.key);
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }

    expect(await storage.migrateLegacyCaches(), isEmpty);

    for (final entry in oldFiles.entries) {
      final suffix = entry.key.substring(oldShared.length);
      expect(await File(entry.key).exists(), isFalse);
      expect(
        await File('${storage.sharedDatabase}$suffix').readAsString(),
        entry.value,
      );
    }
  });

  test('keeps entries already written to the new cache layout', () async {
    final currentDatabase = AppDatabase.open(storage.sharedDatabase);
    currentDatabase.db.execute(
      'INSERT INTO cache '
      '(store, key, value, stored_at, expires_at) VALUES (?, ?, ?, ?, ?)',
      ['shared', 'current', 'new', 1, 2],
    );
    currentDatabase.close();

    final oldShared = DatabasePaths.shared(storage.supportDirectory);
    final oldDatabase = AppDatabase.open(oldShared);
    oldDatabase.db.execute(
      'INSERT INTO cache '
      '(store, key, value, stored_at, expires_at) VALUES (?, ?, ?, ?, ?)',
      ['shared', 'legacy', 'old', 1, 2],
    );
    oldDatabase.close();

    final currentSubtitle = File(
      p.join(storage.learningSubtitleCacheDirectory, 'same.srt'),
    );
    await currentSubtitle.parent.create(recursive: true);
    await currentSubtitle.writeAsString('current');
    final oldSubtitle = File(
      p.join(
        storage.supportDirectory,
        'cache',
        'learning-subtitles',
        'same.srt',
      ),
    );
    await oldSubtitle.parent.create(recursive: true);
    await oldSubtitle.writeAsString('legacy');

    expect(await storage.migrateLegacyCaches(), isEmpty);

    final keptDatabase = AppDatabase.open(storage.sharedDatabase);
    expect(
      keptDatabase.db.select('SELECT key FROM cache').single['key'],
      'current',
    );
    keptDatabase.close();
    expect(await File(oldShared).exists(), isFalse);
    expect(await currentSubtitle.readAsString(), 'current');
    expect(await oldSubtitle.exists(), isFalse);
  });
}
