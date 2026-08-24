/// Stale-while-revalidate query cache port (the redo branch's cache.js
/// semantics). Implemented over SQLite in infrastructure/database.
library;

class CacheStoreSpec {
  const CacheStoreSpec(
    this.name, {
    required this.maxAge,
    required this.maxEntries,
    this.swr = false,
    this.shared = false,
  });

  final String name;
  final Duration maxAge;
  final int maxEntries;

  /// Only swr stores may serve stale data. User-owned stores never opt in.
  final bool swr;

  /// Shared across profiles vs per-profile.
  final bool shared;
}

/// The store table, ported from cache.js. TTL/caps are measured decisions.
abstract final class CacheStores {
  static const general = CacheStoreSpec(
    'general',
    maxAge: Duration(days: 3650),
    maxEntries: 500,
  );
  static const userLists = CacheStoreSpec(
    'user_lists',
    maxAge: Duration(days: 3650),
    maxEntries: 50,
  );
  static const history = CacheStoreSpec(
    'history',
    maxAge: Duration(days: 3650),
    maxEntries: 2000,
  );
  static const notifications = CacheStoreSpec(
    'notifications',
    maxAge: Duration(days: 3650),
    maxEntries: 2000,
  );
  static const queryFollowing = CacheStoreSpec(
    'query_following',
    maxAge: Duration(days: 30),
    maxEntries: 2000,
  );
  static const queryRecommendations = CacheStoreSpec(
    'query_recommendations',
    maxAge: Duration(days: 30),
    maxEntries: 500,
  );
  static const mediaCache = CacheStoreSpec(
    'media_cache',
    maxAge: Duration(days: 120),
    maxEntries: 10000,
    shared: true,
  );
  static const queryMappings = CacheStoreSpec(
    'query_mappings',
    maxAge: Duration(days: 120),
    maxEntries: 5000,
    swr: true,
    shared: true,
  );
  static const queryCompound = CacheStoreSpec(
    'query_compound',
    maxAge: Duration(days: 7),
    maxEntries: 500,
    swr: true,
    shared: true,
  );
  static const queryEpisodes = CacheStoreSpec(
    'query_episodes',
    maxAge: Duration(days: 60),
    maxEntries: 1000,
    swr: true,
    shared: true,
  );
  static const querySearchIds = CacheStoreSpec(
    'query_search_ids',
    maxAge: Duration(days: 30),
    maxEntries: 1000,
    swr: true,
    shared: true,
  );
  static const querySearch = CacheStoreSpec(
    'query_search',
    maxAge: Duration(days: 30),
    maxEntries: 1000,
    swr: true,
    shared: true,
  );
  static const queryRss = CacheStoreSpec(
    'query_rss',
    maxAge: Duration(days: 30),
    maxEntries: 1000,
    swr: true,
    shared: true,
  );
}

class CacheEntry<T> {
  const CacheEntry(this.value, this.storedAt, {required this.stale});

  final T value;
  final DateTime storedAt;
  final bool stale;
}

abstract interface class QueryCache {
  /// Read an entry. When [ignoreExpiry] (offline), expired entries are
  /// returned anyway.
  Future<CacheEntry<Map<String, dynamic>>?> read(
    CacheStoreSpec store,
    String key, {
    bool ignoreExpiry = false,
  });

  Future<void> write(
    CacheStoreSpec store,
    String key,
    Map<String, dynamic> value, {
    Duration? maxAge,
  });

  Future<void> delete(CacheStoreSpec store, String key);

  /// SWR read: return stale immediately when allowed, kick [revalidate] in
  /// the background (single-flight per key), and bump [revalidated] when the
  /// fresh copy differs from what was served.
  Future<Map<String, dynamic>?> swrRead(
    CacheStoreSpec store,
    String key,
    Future<Map<String, dynamic>?> Function() revalidate,
  );

  /// Increments whenever a background revalidation lands a changed value —
  /// screens listen to repaint.
  Stream<void> get revalidated;
}
