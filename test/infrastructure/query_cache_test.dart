import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/ports/query_cache.dart';
import 'package:zero/infrastructure/database/database.dart';
import 'package:zero/infrastructure/database/query_cache_impl.dart';

import 'test_support.dart';

const swrStore = CacheStoreSpec(
  'test_swr',
  maxAge: Duration(hours: 1),
  maxEntries: 100,
  swr: true,
);
const plainStore = CacheStoreSpec(
  'test_plain',
  maxAge: Duration(hours: 1),
  maxEntries: 100,
);
const tinyStore = CacheStoreSpec(
  'test_tiny',
  maxAge: Duration(days: 1),
  maxEntries: 3,
);
const sharedStore = CacheStoreSpec(
  'test_shared',
  maxAge: Duration(hours: 1),
  maxEntries: 10,
  shared: true,
);

void main() {
  late AppDatabase profile;
  late AppDatabase shared;
  late ManualClock clock;
  late SqliteQueryCache cache;

  setUp(() {
    profile = AppDatabase.inMemory();
    shared = AppDatabase.inMemory();
    clock = ManualClock();
    cache = SqliteQueryCache(profile: profile, shared: shared, clock: clock);
  });

  tearDown(() {
    profile.close();
    shared.close();
  });

  group('read/write', () {
    test('roundtrips a value with its stored-at time', () async {
      await cache.write(plainStore, 'k', {'a': 1});
      final entry = await cache.read(plainStore, 'k');
      expect(entry, isNotNull);
      expect(entry!.value, {'a': 1});
      expect(entry.stale, isFalse);
      expect(entry.storedAt, clock.now());
    });

    test('an expired entry is a miss', () async {
      await cache.write(plainStore, 'k', {'a': 1});
      clock.advance(const Duration(hours: 2));
      expect(await cache.read(plainStore, 'k'), isNull);
    });

    test(
      'ignoreExpiry serves the expired entry, marked stale (offline reads)',
      () async {
        await cache.write(plainStore, 'k', {'a': 1});
        clock.advance(const Duration(hours: 2));
        final entry = await cache.read(plainStore, 'k', ignoreExpiry: true);
        expect(entry!.value, {'a': 1});
        expect(entry.stale, isTrue);
      },
    );

    test('a caller-supplied maxAge overrides the store TTL', () async {
      await cache.write(plainStore, 'k', {
        'a': 1,
      }, maxAge: const Duration(minutes: 1));
      clock.advance(const Duration(minutes: 2));
      expect(await cache.read(plainStore, 'k'), isNull);
    });

    test('delete removes the entry', () async {
      await cache.write(plainStore, 'k', {'a': 1});
      await cache.delete(plainStore, 'k');
      expect(await cache.read(plainStore, 'k', ignoreExpiry: true), isNull);
    });

    test('shared stores land in the shared database, per-profile in the profile one', () async {
      await cache.write(sharedStore, 'k', {'where': 'shared'});
      await cache.write(plainStore, 'k', {'where': 'profile'});
      int rows(AppDatabase db, String store) =>
          db.db.select('SELECT COUNT(*) AS n FROM cache WHERE store = ?', [
                store,
              ]).first['n']
              as int;
      expect(rows(shared, 'test_shared'), 1);
      expect(rows(profile, 'test_shared'), 0);
      expect(rows(profile, 'test_plain'), 1);
      expect(rows(shared, 'test_plain'), 0);
    });
  });

  group('pruning', () {
    test('past the cap the oldest entries go first', () async {
      for (var i = 0; i < 5; i++) {
        await cache.write(tinyStore, 'k$i', {'i': i});
        clock.advance(const Duration(minutes: 1));
      }
      expect(await cache.read(tinyStore, 'k0'), isNull);
      expect(await cache.read(tinyStore, 'k1'), isNull);
      expect(await cache.read(tinyStore, 'k2'), isNotNull);
      expect(await cache.read(tinyStore, 'k3'), isNotNull);
      expect(await cache.read(tinyStore, 'k4'), isNotNull);
    });

    test('rewriting an existing key does not evict', () async {
      for (var i = 0; i < 3; i++) {
        await cache.write(tinyStore, 'k$i', {'i': i});
        clock.advance(const Duration(minutes: 1));
      }
      await cache.write(tinyStore, 'k0', {'i': 99});
      for (var i = 0; i < 3; i++) {
        expect(await cache.read(tinyStore, 'k$i'), isNotNull, reason: 'k$i');
      }
    });

    test('caps are per store, not global', () async {
      for (var i = 0; i < 3; i++) {
        await cache.write(tinyStore, 'k$i', {'i': i});
        await cache.write(plainStore, 'p$i', {'i': i});
        clock.advance(const Duration(minutes: 1));
      }
      await cache.write(tinyStore, 'k3', {'i': 3});
      expect(await cache.read(tinyStore, 'k0'), isNull);
      expect(await cache.read(plainStore, 'p0'), isNotNull);
    });
  });

  group('swrRead', () {
    test('a fresh row answers immediately, no revalidation', () async {
      await cache.write(swrStore, 'k', {'a': 1});
      var called = 0;
      final value = await cache.swrRead(swrStore, 'k', () async {
        called++;
        return {'a': 2};
      });
      expect(value, {'a': 1});
      expect(called, 0);
    });

    test('no row at all means the caller waits like any first fetch', () async {
      final value = await cache.swrRead(swrStore, 'k', () async => {'a': 1});
      expect(value, {'a': 1});
      expect((await cache.read(swrStore, 'k'))!.value, {
        'a': 1,
      }, reason: 'landed in the store');
    });

    test(
      'a stale row in an swr store answers immediately and revalidates behind',
      () async {
        await cache.write(swrStore, 'k', {'a': 1});
        clock.advance(const Duration(hours: 2));

        final bumps = <void>[];
        final sub = cache.revalidated.listen(bumps.add);

        final value = await cache.swrRead(swrStore, 'k', () async => {'a': 2});
        expect(value, {'a': 1}, reason: 'the stale copy is served');

        await pumpEventQueue();
        expect((await cache.read(swrStore, 'k'))!.value, {
          'a': 2,
        }, reason: 'the fresh copy landed');
        expect(
          bumps.length,
          1,
          reason: 'a changed value tells the rails to repaint',
        );
        await sub.cancel();
      },
    );

    test('an identical fresh copy does not bump revalidated', () async {
      await cache.write(swrStore, 'k', {
        'a': 1,
        'b': [1, 2],
      });
      clock.advance(const Duration(hours: 2));

      final bumps = <void>[];
      final sub = cache.revalidated.listen(bumps.add);

      // Same JSON, different key order — deep comparison, not string equality.
      await cache.swrRead(
        swrStore,
        'k',
        () async => {
          'b': [1, 2],
          'a': 1,
        },
      );
      await pumpEventQueue();
      expect(bumps, isEmpty);
      await sub.cancel();
    });

    test(
      'only swr stores serve stale: a plain store waits for the fresh copy',
      () async {
        await cache.write(plainStore, 'k', {'a': 1});
        clock.advance(const Duration(hours: 2));
        final value = await cache.swrRead(
          plainStore,
          'k',
          () async => {'a': 2},
        );
        expect(value, {'a': 2});
      },
    );

    test('revalidation is single-flight per key', () async {
      await cache.write(swrStore, 'k', {'a': 1});
      clock.advance(const Duration(hours: 2));

      var calls = 0;
      final gate = Completer<Map<String, dynamic>?>();
      Future<Map<String, dynamic>?> revalidate() {
        calls++;
        return gate.future;
      }

      final first = await cache.swrRead(swrStore, 'k', revalidate);
      final second = await cache.swrRead(swrStore, 'k', revalidate);
      expect(first, {'a': 1});
      expect(second, {'a': 1});

      gate.complete({'a': 2});
      await pumpEventQueue();
      expect(calls, 1, reason: 'two asks in the same breath cost one request');
      expect((await cache.read(swrStore, 'k'))!.value, {'a': 2});
    });

    test('different keys revalidate independently', () async {
      await cache.write(swrStore, 'k1', {'a': 1});
      await cache.write(swrStore, 'k2', {'a': 1});
      clock.advance(const Duration(hours: 2));
      var calls = 0;
      Future<Map<String, dynamic>?> revalidate() async {
        calls++;
        return {'a': 2};
      }

      await cache.swrRead(swrStore, 'k1', revalidate);
      await cache.swrRead(swrStore, 'k2', revalidate);
      await pumpEventQueue();
      expect(calls, 2);
    });

    test('a failed revalidation leaves the stale copy standing', () async {
      await cache.write(swrStore, 'k', {'a': 1});
      clock.advance(const Duration(hours: 2));
      final value = await cache.swrRead(
        swrStore,
        'k',
        () async => throw Exception('api down'),
      );
      expect(value, {'a': 1});
      await pumpEventQueue();
      final kept = await cache.read(swrStore, 'k', ignoreExpiry: true);
      expect(kept!.value, {'a': 1});
    });

    test(
      'a null revalidation result writes nothing and bumps nothing',
      () async {
        await cache.write(swrStore, 'k', {'a': 1});
        clock.advance(const Duration(hours: 2));
        final bumps = <void>[];
        final sub = cache.revalidated.listen(bumps.add);
        final value = await cache.swrRead(swrStore, 'k', () async => null);
        expect(value, {'a': 1});
        await pumpEventQueue();
        expect(bumps, isEmpty);
        expect((await cache.read(swrStore, 'k', ignoreExpiry: true))!.value, {
          'a': 1,
        });
        await sub.cancel();
      },
    );

    test(
      'the first fetch of a missing key does not bump revalidated',
      () async {
        final bumps = <void>[];
        final sub = cache.revalidated.listen(bumps.add);
        await cache.swrRead(swrStore, 'k', () async => {'a': 1});
        await pumpEventQueue();
        expect(
          bumps,
          isEmpty,
          reason: 'nothing was served, so nothing needs repainting',
        );
        await sub.cancel();
      },
    );
  });

  test('jsonDeepEquals compares structurally', () {
    expect(jsonDeepEquals({'a': 1}, {'a': 1}), isTrue);
    expect(jsonDeepEquals({'a': 1, 'b': 2}, {'b': 2, 'a': 1}), isTrue);
    expect(
      jsonDeepEquals(
        {
          'a': [
            1,
            {'x': null},
          ],
        },
        {
          'a': [
            1,
            {'x': null},
          ],
        },
      ),
      isTrue,
    );
    expect(jsonDeepEquals({'a': 1}, {'a': 2}), isFalse);
    expect(jsonDeepEquals({'a': 1}, {'a': 1, 'b': 1}), isFalse);
    expect(jsonDeepEquals([1, 2], [2, 1]), isFalse);
    expect(jsonDeepEquals(null, null), isTrue);
    expect(jsonDeepEquals(1, 1.0), isTrue, reason: 'JSON has one number type');
  });
}
