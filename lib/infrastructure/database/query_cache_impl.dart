/// The query cache over SQLite — cache.js's semantics on the QueryCache port.
///
/// The rules ported from frontend/common/modules/cache.js (redo branch):
///  - only stores with `swr: true` may serve stale; user-owned stores never
///    opt in,
///  - one in-flight revalidation per entry, so a rail and a modal asking the
///    same question in the same breath cost one request,
///  - the `revalidated` stream bumps only when the fresh copy actually
///    differs from what was served (deep JSON comparison) — that is the
///    signal the home rails repaint on,
///  - `ignoreExpiry` serves whatever exists, however old (offline reads).
library;

import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../domain/ports/query_cache.dart';
import '../../domain/ports/http_transport.dart';
import 'database.dart';

class SqliteQueryCache implements QueryCache {
  SqliteQueryCache({
    required this._profile,
    required this._shared,
    this._clock = const SystemClock(),
  });

  final AppDatabase _profile;
  final AppDatabase _shared;
  final Clock _clock;

  final _revalidating = <String, Future<Map<String, dynamic>?>>{};
  final _revalidated = StreamController<void>.broadcast();

  /// Per-store row counts, seeded from one `COUNT(*)` per store and adjusted
  /// on every write/delete/prune. This class is the table's only writer, and
  /// the caches run on the UI isolate over synchronous SQLite: counting a
  /// 10k-entry store on every landing is a perceptible per-write scan, while
  /// an indexed point lookup is not.
  final _entryCounts = <String, int>{};

  @override
  Stream<void> get revalidated => _revalidated.stream;

  @override
  Future<CacheEntry<Map<String, dynamic>>?> read(
    CacheStoreSpec store,
    String key, {
    bool ignoreExpiry = false,
  }) async {
    final rows = _db(store).select(
      'SELECT value, stored_at, expires_at FROM cache WHERE store = ? AND key = ?',
      [store.name, key],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final expired =
        _clock.now().millisecondsSinceEpoch >= (row['expires_at'] as int);
    if (expired && !ignoreExpiry) return null;
    return CacheEntry(
      jsonDecode(row['value'] as String) as Map<String, dynamic>,
      DateTime.fromMillisecondsSinceEpoch(row['stored_at'] as int),
      stale: expired,
    );
  }

  @override
  Future<void> write(
    CacheStoreSpec store,
    String key,
    Map<String, dynamic> value, {
    Duration? maxAge,
  }) async {
    final db = _db(store);
    final now = _clock.now().millisecondsSinceEpoch;
    final expires = now + (maxAge ?? store.maxAge).inMilliseconds;
    final count = _entryCount(db, store);
    final existed = db.select(
      'SELECT 1 FROM cache WHERE store = ? AND key = ? LIMIT 1',
      [store.name, key],
    ).isNotEmpty;
    db.execute(
      'INSERT INTO cache (store, key, value, stored_at, expires_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT (store, key) DO UPDATE SET '
      'value = excluded.value, stored_at = excluded.stored_at, expires_at = excluded.expires_at',
      [store.name, key, jsonEncode(value), now, expires],
    );
    if (!existed) _entryCounts[store.name] = count + 1;
    _prune(store);
  }

  @override
  Future<void> delete(CacheStoreSpec store, String key) async {
    final db = _db(store);
    db.execute('DELETE FROM cache WHERE store = ? AND key = ?', [
      store.name,
      key,
    ]);
    final cached = _entryCounts[store.name];
    if (cached != null) _entryCounts[store.name] = cached - db.updatedRows;
  }

  int _entryCount(Database db, CacheStoreSpec store) =>
      _entryCounts[store.name] ??=
          db.select('SELECT COUNT(*) AS n FROM cache WHERE store = ?', [
                store.name,
              ]).first['n']
              as int;

  @override
  Future<Map<String, dynamic>?> swrRead(
    CacheStoreSpec store,
    String key,
    Future<Map<String, dynamic>?> Function() revalidate, {
    Duration? maxAge,
  }) async {
    final fresh = await read(store, key);
    if (fresh != null) return fresh.value;

    // Only swr stores may serve stale — an expired row in a user-owned store
    // is a miss, and the caller waits like any first fetch.
    final stale = store.swr ? await read(store, key, ignoreExpiry: true) : null;
    if (stale == null) {
      return _revalidate(store, key, revalidate, maxAge: maxAge);
    }

    // Serve the stale copy immediately; the fresh one lands behind it. A
    // failed revalidation is swallowed: the stale copy stands.
    unawaited(
      _revalidate(
        store,
        key,
        revalidate,
        maxAge: maxAge,
      ).catchError((Object _) => null),
    );
    return stale.value;
  }

  /// One in-flight revalidation per entry. What the store held when the
  /// revalidation started is remembered so the landing can be judged: only a
  /// fresh copy that actually differs is worth telling the rails about.
  Future<Map<String, dynamic>?> _revalidate(
    CacheStoreSpec store,
    String key,
    Future<Map<String, dynamic>?> Function() revalidate, {
    Duration? maxAge,
  }) {
    final slot = '${store.name}:$key';
    final inFlight = _revalidating[slot];
    if (inFlight != null) return inFlight;

    final landing = _land(store, key, revalidate, maxAge: maxAge).whenComplete(
      () {
        _revalidating.remove(slot);
      },
    );
    _revalidating[slot] = landing;
    return landing;
  }

  Future<Map<String, dynamic>?> _land(
    CacheStoreSpec store,
    String key,
    Future<Map<String, dynamic>?> Function() revalidate, {
    Duration? maxAge,
  }) async {
    final served = (await read(store, key, ignoreExpiry: true))?.value;
    final landed = await revalidate();
    if (landed == null) return null;
    await write(store, key, landed, maxAge: maxAge);
    if (served != null && !jsonDeepEquals(served, landed)) {
      _revalidated.add(null);
    }
    return landed;
  }

  /// Oldest-first eviction past the store's cap.
  void _prune(CacheStoreSpec store) {
    final db = _db(store);
    final overflow = _entryCount(db, store) - store.maxEntries;
    if (overflow <= 0) return;
    db.execute(
      'DELETE FROM cache WHERE rowid IN ('
      'SELECT rowid FROM cache WHERE store = ? ORDER BY stored_at ASC LIMIT ?)',
      [store.name, overflow],
    );
    _entryCounts[store.name] = store.maxEntries;
  }

  Database _db(CacheStoreSpec store) => (store.shared ? _shared : _profile).db;

  void dispose() {
    _revalidated.close();
  }
}

/// Structural equality over decoded JSON (maps compared by key, lists by
/// position). Key order never matters — the served copy comes back from
/// SQLite and the fresh one from the network, in whatever order each built
/// its maps.
bool jsonDeepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!jsonDeepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
