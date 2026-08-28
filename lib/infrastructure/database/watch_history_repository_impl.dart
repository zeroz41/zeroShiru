import 'dart:async';
import 'dart:convert';

import '../../domain/models/media.dart';
import '../../domain/models/media_codec.dart';
import '../../domain/ports/watch_history.dart';
import 'database.dart';

/// Watch history over the durable profile database.
///
/// Writes come from the player a few times a minute; reads are rail-sized.
/// Both are tiny single-table statements, so the synchronous sqlite3 API on
/// the UI isolate is fine here — the same trade the settings repository makes.
class SqliteWatchHistoryRepository implements WatchHistoryRepository {
  SqliteWatchHistoryRepository(this._database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _database;
  final DateTime Function() _clock;
  final _changes = StreamController<void>.broadcast();


  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> record({
    required Media media,
    required int episode,
    required Duration position,
    required Duration duration,
    bool completed = false,
  }) async {
    final now = _clock().millisecondsSinceEpoch;
    final db = _database.db;
    db.execute('BEGIN');
    try {
      // completed latches: MAX keeps an earlier completion when a later
      // partial rewatch writes completed = 0.
      db.execute(
        '''
        INSERT INTO episode_progress
          (media_id, episode, position_ms, duration_ms, completed, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (media_id, episode) DO UPDATE SET
          position_ms = excluded.position_ms,
          duration_ms = excluded.duration_ms,
          completed = MAX(episode_progress.completed, excluded.completed),
          updated_at = excluded.updated_at
        ''',
        [
          media.id,
          episode,
          position.inMilliseconds,
          duration.inMilliseconds,
          completed ? 1 : 0,
          now,
        ],
      );
      db.execute(
        '''
        INSERT INTO watched_media (media_id, media_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT (media_id) DO UPDATE SET
          media_json = excluded.media_json,
          updated_at = excluded.updated_at
        ''',
        [media.id, jsonEncode(mediaToJson(media)), now],
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    _changes.add(null);
  }

  @override
  Future<EpisodeWatchProgress?> progressFor(int mediaId, int episode) async {
    final rows = _database.db.select(
      'SELECT * FROM episode_progress WHERE media_id = ? AND episode = ?',
      [mediaId, episode],
    );
    if (rows.isEmpty) return null;
    return _progressFromRow(rows.first);
  }

  @override
  Future<List<EpisodeWatchProgress>> progressForMedia(int mediaId) async {
    final rows = _database.db.select(
      'SELECT * FROM episode_progress WHERE media_id = ? ORDER BY episode',
      [mediaId],
    );
    return [for (final row in rows) _progressFromRow(row)];
  }

  @override
  Future<int> watchedThrough(int mediaId) async {
    final rows = _database.db.select(
      'SELECT MAX(episode) AS through FROM episode_progress '
      'WHERE media_id = ? AND completed = 1',
      [mediaId],
    );
    return (rows.first['through'] as int?) ?? 0;
  }

  @override
  Future<List<WatchHistoryEntry>> recent({int limit = 30}) async {
    final db = _database.db;
    final shows = db.select(
      'SELECT media_id, media_json, updated_at FROM watched_media '
      'ORDER BY updated_at DESC LIMIT ?',
      [limit],
    );
    final entries = <WatchHistoryEntry>[];
    for (final show in shows) {
      final media = _decodeMedia(show['media_json']);
      if (media == null) continue;
      final mediaId = show['media_id'] as int;
      final through = db.select(
        'SELECT MAX(episode) AS through FROM episode_progress '
        'WHERE media_id = ? AND completed = 1',
        [mediaId],
      );
      final resumeRows = db.select(
        'SELECT * FROM episode_progress '
        'WHERE media_id = ? AND completed = 0 AND position_ms >= ? '
        'ORDER BY updated_at DESC LIMIT 1',
        [mediaId, minimumMeaningfulWatch.inMilliseconds],
      );
      entries.add(
        WatchHistoryEntry(
          media: media,
          watchedThrough: (through.first['through'] as int?) ?? 0,
          resume: resumeRows.isEmpty ? null : _progressFromRow(resumeRows.first),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            show['updated_at'] as int,
          ),
        ),
      );
    }
    return entries;
  }

  @override
  Future<void> forget(int mediaId) async {
    final db = _database.db;
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM episode_progress WHERE media_id = ?', [mediaId]);
      db.execute('DELETE FROM watched_media WHERE media_id = ?', [mediaId]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    _changes.add(null);
  }

  void dispose() {
    _changes.close();
  }

  Media? _decodeMedia(Object? json) {
    if (json is! String) return null;
    try {
      return mediaFromJson(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

  EpisodeWatchProgress _progressFromRow(Map<String, Object?> row) {
    return EpisodeWatchProgress(
      mediaId: row['media_id'] as int,
      episode: row['episode'] as int,
      position: Duration(milliseconds: row['position_ms'] as int),
      duration: Duration(milliseconds: row['duration_ms'] as int),
      completed: (row['completed'] as int) != 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }
}
