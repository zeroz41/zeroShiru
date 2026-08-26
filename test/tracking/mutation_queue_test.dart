/// Mutation queue semantics: rate limits, dedupe, persistence, token
/// stripping, stale-write validation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/ports/query_cache.dart';
import 'package:zero/infrastructure/tracking/mutation_queue.dart';
import 'package:zero/infrastructure/tracking/sync_rules.dart'
    show TrackingProvider;

import 'fakes.dart';

void main() {
  group('rate limits', () {
    test('AniList: 8/min with 500ms spacing', () {
      final queue = MutationQueue(provider: TrackingProvider.aniList);
      expect(queue.rateLimit.perMinute, 8);
      expect(queue.rateLimit.spacing, const Duration(milliseconds: 500));
    });

    test('MAL: 30/min with 1500ms spacing', () {
      final queue = MutationQueue(provider: TrackingProvider.myAnimeList);
      expect(queue.rateLimit.perMinute, 30);
      expect(queue.rateLimit.spacing, const Duration(milliseconds: 1500));
    });

    test(
      'MAL tightens to 15/min, 3000ms when MAL is the signed-in provider',
      () {
        final queue = MutationQueue(
          provider: TrackingProvider.myAnimeList,
          malAuthenticated: true,
        );
        expect(queue.rateLimit.perMinute, 15);
        expect(queue.rateLimit.spacing, const Duration(milliseconds: 3000));
      },
    );

    test('flush paces offline mutations and waits out a full window', () async {
      final clock = FakeClock();
      final queue = MutationQueue(
        provider: TrackingProvider.aniList,
        clock: clock,
      );
      for (var i = 0; i < 9; i++) {
        queue.enqueue(MutationType.entry, i, {'episode': 1}, executed: false);
      }
      final executed = <int>[];
      await queue.flush(
        apply: (_) async {},
        execute: (m) async => executed.add(m.mediaId),
      );
      expect(executed, hasLength(9));
      // 500ms spacing after every request…
      expect(
        clock.sleeps
            .where((s) => s == const Duration(milliseconds: 500))
            .length,
        9,
      );
      // …and one window wait before the 9th (8/min exhausted after 4s of
      // spacing, so the wait is 60s minus the elapsed spacing).
      final windowWaits = clock.sleeps
          .where((s) => s > const Duration(seconds: 30))
          .toList();
      expect(windowWaits, hasLength(1));
      expect(windowWaits.single, const Duration(seconds: 56));
    });
  });

  group('dedupe', () {
    test('duplicate favourite toggles cancel out', () {
      final queue = MutationQueue(provider: TrackingProvider.aniList);
      queue.enqueue(MutationType.favourite, 7, const {}, executed: false);
      expect(queue.hasPending, isTrue);
      queue.enqueue(MutationType.favourite, 7, const {}, executed: false);
      expect(queue.hasPending, isFalse);
    });

    test('favourites for different media do not cancel', () {
      final queue = MutationQueue(provider: TrackingProvider.aniList);
      queue.enqueue(MutationType.favourite, 7, const {}, executed: false);
      queue.enqueue(MutationType.favourite, 8, const {}, executed: false);
      expect(queue.pending, hasLength(2));
    });

    test('duplicate entry is last-write-wins preserving progressBefore and '
        'queuedAt', () {
      final clock = FakeClock();
      final queue = MutationQueue(
        provider: TrackingProvider.aniList,
        clock: clock,
      );
      queue.enqueue(
        MutationType.entry,
        7,
        const {'episode': 5},
        progressBefore: 4,
        executed: false,
      );
      final originalQueuedAt = queue.pending.single.queuedAt;

      clock.advance(const Duration(minutes: 3));
      queue.enqueue(
        MutationType.entry,
        7,
        const {'episode': 6},
        progressBefore: 5,
        executed: false,
      );

      final mutation = queue.pending.single;
      expect(mutation.variables['episode'], 6, reason: 'last write wins');
      expect(mutation.progressBefore, 4, reason: 'original baseline kept');
      expect(mutation.queuedAt, originalQueuedAt);
    });

    test('progressBeforeOf reads the queued baseline', () {
      final queue = MutationQueue(provider: TrackingProvider.aniList);
      queue.enqueue(
        MutationType.entry,
        7,
        const {'episode': 5},
        progressBefore: 4,
        executed: false,
      );
      expect(queue.progressBeforeOf(7), 4);
      expect(queue.progressBeforeOf(8), isNull);
    });
  });

  group('enqueue gating', () {
    test('executed mutation outside a list fetch is applied immediately '
        '(returns false, nothing queued)', () {
      final queue = MutationQueue(provider: TrackingProvider.aniList);
      final queued = queue.enqueue(MutationType.entry, 7, const {'episode': 5});
      expect(queued, isFalse);
      expect(queue.hasPending, isFalse);
    });

    test('executed mutation during a list fetch is queued', () {
      final queue = MutationQueue(provider: TrackingProvider.aniList)
        ..isFetchingList = true;
      final queued = queue.enqueue(
        MutationType.entry,
        7,
        const {'episode': 5},
        result: const {'progress': 5},
      );
      expect(queued, isTrue);
      expect(queue.pending.single.executed, isTrue);
    });
  });

  group('persistence', () {
    test('only non-executed mutations are persisted', () async {
      final persisted = <List<QueuedMutation>>[];
      final queue = MutationQueue(
        provider: TrackingProvider.aniList,
        persist: (pending) async => persisted.add(pending),
      )..isFetchingList = true;
      queue.enqueue(
        MutationType.entry,
        1,
        const {'episode': 5},
        result: const {'progress': 5},
      ); // executed, session-only
      queue.enqueue(MutationType.entry, 2, const {
        'episode': 3,
      }, executed: false); // offline
      await queue.persisted;
      expect(persisted.last.map((m) => m.mediaId), [2]);
    });

    test('round-trips through the cache-backed store', () async {
      final cache = InMemoryQueryCache();
      final first = MutationQueue(
        provider: TrackingProvider.aniList,
        persist: (pending) => cache.write(CacheStores.general, 'syncQueueAni', {
          'mutations': [for (final m in pending) m.toJson()],
        }),
      );
      first.enqueue(
        MutationType.entry,
        42,
        const {'episode': 5},
        progressBefore: 4,
        executed: false,
      );
      await first.persisted;

      final second = await MutationQueue.fromCache(
        cache,
        provider: TrackingProvider.aniList,
      );
      expect(second.pending, hasLength(1));
      final restored = second.pending.single;
      expect(restored.mediaId, 42);
      expect(restored.variables['episode'], 5);
      expect(restored.progressBefore, 4);
      expect(restored.executed, isFalse);
    });

    test('an offline mutation survives until execution succeeds', () async {
      final cache = InMemoryQueryCache();
      final queue = await MutationQueue.fromCache(
        cache,
        provider: TrackingProvider.aniList,
      );
      queue.enqueue(MutationType.entry, 42, const {
        'episode': 5,
      }, executed: false);
      await queue.persisted;

      // First flush fails — the mutation must stay in the persisted queue.
      await queue.flush(
        apply: (_) async {},
        execute: (_) async => throw StateError('server down'),
      );
      await queue.persisted;
      var reloaded = await MutationQueue.fromCache(
        cache,
        provider: TrackingProvider.aniList,
      );
      expect(reloaded.hasPending, isTrue);

      // Second flush succeeds — now it leaves the persisted queue.
      await queue.flush(apply: (_) async {}, execute: (_) async {});
      await queue.persisted;
      reloaded = await MutationQueue.fromCache(
        cache,
        provider: TrackingProvider.aniList,
      );
      expect(reloaded.hasPending, isFalse);
    });
  });

  group('token stripping', () {
    test('tokens are never persisted — replaced by tokenUserId and restored '
        'at execution', () async {
      final queue = MutationQueue(
        provider: TrackingProvider.aniList,
        tokenUserIdOf: (token) => token == 'secret-token' ? 99 : null,
        credentialsOf: (userId) => userId == 99
            ? const MutationCredentials('secret-token', refreshIn: 1234)
            : null,
      );
      queue.enqueue(MutationType.entry, 7, const {
        'episode': 5,
        'token': 'secret-token',
        'refresh_in': 1234,
      }, executed: false);

      final stored = queue.pending.single;
      expect(stored.variables.containsKey('token'), isFalse);
      expect(stored.variables.containsKey('refresh_in'), isFalse);
      expect(stored.variables['tokenUserId'], 99);

      QueuedMutation? executed;
      await queue.flush(
        apply: (_) async {},
        execute: (m) async => executed = m,
      );
      expect(executed!.variables['token'], 'secret-token');
      expect(executed!.variables['refresh_in'], 1234);
      expect(executed!.variables.containsKey('tokenUserId'), isFalse);
    });

    test('an unknown token is still stripped (no credential is persisted)', () {
      final queue = MutationQueue(
        provider: TrackingProvider.aniList,
        tokenUserIdOf: (_) => null,
      );
      queue.enqueue(MutationType.entry, 7, const {
        'episode': 5,
        'token': 'stranger',
      }, executed: false);
      expect(queue.pending.single.variables.containsKey('token'), isFalse);
      expect(
        queue.pending.single.variables.containsKey('tokenUserId'),
        isFalse,
      );
      expect(queue.pending.single.variables['episode'], 5);
    });
  });

  group('flush', () {
    test('executed mutations clear upfront; offline stay until sent', () async {
      final queue = MutationQueue(provider: TrackingProvider.aniList)
        ..isFetchingList = true;
      queue.enqueue(
        MutationType.entry,
        1,
        const {'episode': 5},
        result: const {'progress': 5},
      );
      queue.enqueue(MutationType.entry, 2, const {
        'episode': 3,
      }, executed: false);
      queue.isFetchingList = false;

      final applied = <int>[];
      final executed = <int>[];
      await queue.flush(
        apply: (m) async => applied.add(m.mediaId),
        execute: (m) async => executed.add(m.mediaId),
      );
      expect(
        applied,
        [1],
        reason:
            'executed mutations re-apply; a result-less offline '
            'mutation has nothing to apply yet',
      );
      expect(executed, [2]);
      expect(queue.hasPending, isFalse);
    });

    test(
      'offline mutation without a result is not applied, only executed',
      () async {
        final queue = MutationQueue(provider: TrackingProvider.aniList);
        queue.enqueue(MutationType.entry, 2, const {
          'episode': 3,
        }, executed: false);
        final applied = <int>[];
        await queue.flush(
          apply: (m) async => applied.add(m.mediaId),
          execute: (_) async {},
        );
        expect(applied, isEmpty);
      },
    );

    test('stale entry writes are discarded when the server moved past the '
        'baseline', () async {
      final queue = MutationQueue(provider: TrackingProvider.aniList);
      queue.enqueue(
        MutationType.entry,
        7,
        const {'episode': 5},
        progressBefore: 4,
        executed: false,
      );
      final executed = <int>[];
      await queue.flush(
        freshProgressOf: (mediaId) => 6, // server already at 6 > baseline 4
        apply: (_) async {},
        execute: (m) async => executed.add(m.mediaId),
      );
      expect(executed, isEmpty);
      expect(queue.hasPending, isFalse, reason: 'discarded, not retried');
    });

    test(
      'delete and favourite are always valid regardless of progress',
      () async {
        final queue = MutationQueue(provider: TrackingProvider.aniList);
        queue.enqueue(MutationType.delete, 7, const {}, executed: false);
        queue.enqueue(MutationType.favourite, 8, const {}, executed: false);
        final executed = <MutationType>[];
        await queue.flush(
          freshProgressOf: (_) => 100,
          apply: (_) async {},
          execute: (m) async => executed.add(m.type),
        );
        expect(executed, [MutationType.delete, MutationType.favourite]);
      },
    );

    test(
      'a failed execution keeps the mutation queued for the next flush',
      () async {
        final queue = MutationQueue(provider: TrackingProvider.aniList);
        queue.enqueue(MutationType.entry, 7, const {
          'episode': 5,
        }, executed: false);
        await queue.flush(
          apply: (_) async {},
          execute: (_) async => throw StateError('offline again'),
        );
        expect(queue.hasPending, isTrue);
      },
    );
  });
}
