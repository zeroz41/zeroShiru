/// In-memory fakes shared by the tracking tests. No network, no wall clock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zero/domain/ports/ports.dart';
import 'package:zero/domain/ports/query_cache.dart';
import 'package:zero/domain/ports/http_transport.dart';

/// Routes requests by URL substring to canned handlers. A handler may return
/// an [HttpResponse], a JSON-encodable Map/List, or throw.
class FakeTransport implements HttpTransport {
  final List<(String, FutureOr<Object> Function(HttpRequest))> _routes = [];
  final List<HttpRequest> requests = [];

  void on(String urlSubstring, FutureOr<Object> Function(HttpRequest) handler) {
    _routes.add((urlSubstring, handler));
  }

  void onJson(String urlSubstring, Object json, {int status = 200}) {
    on(urlSubstring, (_) => jsonResponse(json, status: status));
  }

  static HttpResponse jsonResponse(Object json, {int status = 200}) =>
      HttpResponse(status, const {
        'content-type': 'application/json',
      }, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final url = request.url.toString();
    for (final (substring, handler) in _routes) {
      if (url.contains(substring)) {
        final result = await handler(request);
        if (result is HttpResponse) return result;
        return jsonResponse(result);
      }
    }
    throw NetworkException('no fake route for $url');
  }
}

/// Deterministic clock: `now` only moves when the test advances it or when
/// code under test sleeps.
class FakeClock implements Clock {
  FakeClock([DateTime? start])
    : _now = start ?? DateTime.utc(2026, 8, 23, 12, 0, 0);

  DateTime _now;
  final List<Duration> sleeps = [];

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);

  @override
  Future<void> sleep(Duration duration) async {
    sleeps.add(duration);
    _now = _now.add(duration);
  }
}

class _StoredEntry {
  _StoredEntry(this.value, this.storedAt, this.maxAge);

  final Map<String, dynamic> value;
  final DateTime storedAt;
  final Duration maxAge;
}

class InMemoryQueryCache implements QueryCache {
  InMemoryQueryCache([FakeClock? clock]) : clock = clock ?? FakeClock();

  final FakeClock clock;
  final Map<String, _StoredEntry> _entries = {};
  final Map<String, Future<void>> _revalidating = {};
  final List<(String store, String key, Duration? maxAge)> writes = [];
  final StreamController<void> _revalidated = StreamController.broadcast();

  String _key(CacheStoreSpec store, String key) => '${store.name}::$key';

  @override
  Future<CacheEntry<Map<String, dynamic>>?> read(
    CacheStoreSpec store,
    String key, {
    bool ignoreExpiry = false,
  }) async {
    final entry = _entries[_key(store, key)];
    if (entry == null) return null;
    final stale = clock.now().difference(entry.storedAt) >= entry.maxAge;
    if (stale && !ignoreExpiry) return null;
    return CacheEntry(entry.value, entry.storedAt, stale: stale);
  }

  @override
  Future<void> write(
    CacheStoreSpec store,
    String key,
    Map<String, dynamic> value, {
    Duration? maxAge,
  }) async {
    writes.add((store.name, key, maxAge));
    _entries[_key(store, key)] = _StoredEntry(
      value,
      clock.now(),
      maxAge ?? store.maxAge,
    );
  }

  @override
  Future<void> delete(CacheStoreSpec store, String key) async {
    _entries.remove(_key(store, key));
  }

  @override
  Future<Map<String, dynamic>?> swrRead(
    CacheStoreSpec store,
    String key,
    Future<Map<String, dynamic>?> Function() revalidate, {
    Duration? maxAge,
  }) async {
    final freshHit = await read(store, key);
    if (freshHit != null) return freshHit.value;

    final stale = store.swr ? await read(store, key, ignoreExpiry: true) : null;
    if (stale != null) {
      final cacheKey = _key(store, key);
      if (!_revalidating.containsKey(cacheKey)) {
        late final Future<void> refresh;
        refresh = () async {
          final fresh = await revalidate();
          if (fresh != null) {
            await write(store, key, fresh, maxAge: maxAge);
          }
        }().whenComplete(() => _revalidating.remove(cacheKey));
        _revalidating[cacheKey] = refresh;
        unawaited(refresh);
      }
      return stale.value;
    }

    final fresh = await revalidate();
    if (fresh != null) await write(store, key, fresh, maxAge: maxAge);
    return fresh;
  }

  @override
  Stream<void> get revalidated => _revalidated.stream;
}

class InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
