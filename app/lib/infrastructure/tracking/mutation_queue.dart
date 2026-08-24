// ignore_for_file: prefer_initializing_formals

/// Offline-safe mutation queue, ported from the redo branch's
/// `providers/lib/mutationqueue.js`.
///
/// Semantics preserved:
/// - persisted across sessions (only NON-executed mutations are persisted);
/// - types entry | delete | favourite;
/// - rate limits: AniList 8/min with 500 ms spacing; MAL 30/min with 1500 ms
///   (tightened to 15/min with 3000 ms when MAL is the authenticated
///   provider);
/// - duplicate favourite toggles for the same media cancel each other out;
/// - duplicate entry/delete are last-write-wins, preserving the original
///   `progressBefore` and `queuedAt`;
/// - `progressBefore` powers stale-write detection at flush time: an entry
///   mutation is discarded when the server's progress already moved past the
///   baseline recorded at queue time;
/// - tokens are NEVER persisted inside variables — they are replaced with a
///   `tokenUserId` reference and restored just before execution;
/// - the queue is flushed on the reconnect signal and after list reads
///   settle (the caller invokes [flush] at those moments; `isFetchingList`
///   guards the race).
library;

import '../../domain/ports/query_cache.dart';
import '../network/transport.dart';
import 'sync_rules.dart' show TrackingProvider;

enum MutationType { entry, delete, favourite }

class QueuedMutation {
  const QueuedMutation({
    required this.type,
    required this.mediaId,
    required this.variables,
    this.result,
    this.progressBefore,
    required this.executed,
    required this.queuedAt,
  });

  factory QueuedMutation.fromJson(Map<String, dynamic> json) => QueuedMutation(
    type: MutationType.values.byName(json['type'] as String),
    mediaId: (json['mediaId'] as num).toInt(),
    variables: (json['variables'] as Map?)?.cast<String, dynamic>() ?? const {},
    result: (json['result'] as Map?)?.cast<String, dynamic>(),
    progressBefore: (json['progressBefore'] as num?)?.toInt(),
    executed: json['executed'] as bool? ?? false,
    queuedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['queuedAt'] as num).toInt(),
    ),
  );

  final MutationType type;
  final int mediaId;

  /// Mutation variables. Never carries `token`/`refresh_in` while queued —
  /// only a `tokenUserId` reference.
  final Map<String, dynamic> variables;

  /// The API result when [executed] (used to re-apply to the local cache).
  final Map<String, dynamic>? result;

  /// Progress at queue time — the stale-write baseline.
  final int? progressBefore;

  /// True when the API call already succeeded this session; false when the
  /// mutation is waiting to be sent (offline).
  final bool executed;

  final DateTime queuedAt;

  QueuedMutation copyWith({
    Map<String, dynamic>? variables,
    int? progressBefore,
    DateTime? queuedAt,
  }) => QueuedMutation(
    type: type,
    mediaId: mediaId,
    variables: variables ?? this.variables,
    result: result,
    progressBefore: progressBefore ?? this.progressBefore,
    executed: executed,
    queuedAt: queuedAt ?? this.queuedAt,
  );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'mediaId': mediaId,
    'variables': variables,
    if (result != null) 'result': result,
    if (progressBefore != null) 'progressBefore': progressBefore,
    'executed': executed,
    'queuedAt': queuedAt.millisecondsSinceEpoch,
  };

  bool _same(QueuedMutation other) =>
      other.type == type &&
      other.mediaId == mediaId &&
      other.queuedAt == queuedAt;
}

/// Restored credentials for a queued mutation ([MutationQueue.credentialsOf]).
class MutationCredentials {
  const MutationCredentials(this.token, {this.refreshIn});

  final String token;

  /// Epoch seconds of the MAL refresh deadline (`refresh_in`).
  final int? refreshIn;
}

class MutationRateLimit {
  const MutationRateLimit({required this.perMinute, required this.spacing});

  final int perMinute;
  final Duration spacing;
}

typedef PersistQueue = Future<void> Function(List<QueuedMutation> pending);

class MutationQueue {
  /// [persist] receives the non-executed mutations on every change; pass a
  /// callback of your own, or use [MutationQueue.fromCache] for the old
  /// `GENERAL:syncQueueAni` / `syncQueueMal` persistence.
  ///
  /// [malAuthenticated] tightens the MyAnimeList limit to 15/min, 3000 ms —
  /// the old app did this when MAL was the signed-in provider (its own
  /// account traffic already consumes MAL quota).
  MutationQueue({
    required this.provider,
    PersistQueue? persist,
    List<QueuedMutation> initial = const [],
    bool malAuthenticated = false,
    Clock clock = const SystemClock(),
    int? Function(String token)? tokenUserIdOf,
    MutationCredentials? Function(int userId)? credentialsOf,
  }) : _persist = persist,
       _clock = clock,
       _tokenUserIdOf = tokenUserIdOf,
       _credentialsOf = credentialsOf,
       _queue = [...initial],
       rateLimit = provider == TrackingProvider.aniList
           ? const MutationRateLimit(
               perMinute: 8,
               spacing: Duration(milliseconds: 500),
             )
           : malAuthenticated
           ? const MutationRateLimit(
               perMinute: 15,
               spacing: Duration(milliseconds: 3000),
             )
           : const MutationRateLimit(
               perMinute: 30,
               spacing: Duration(milliseconds: 1500),
             );

  /// Loads the persisted queue from the old cache location
  /// (`general:syncQueueAni` / `general:syncQueueMal`) and keeps it in sync.
  static Future<MutationQueue> fromCache(
    QueryCache cache, {
    required TrackingProvider provider,
    bool malAuthenticated = false,
    Clock clock = const SystemClock(),
    int? Function(String token)? tokenUserIdOf,
    MutationCredentials? Function(int userId)? credentialsOf,
  }) async {
    final key = provider == TrackingProvider.aniList
        ? 'syncQueueAni'
        : 'syncQueueMal';
    var initial = const <QueuedMutation>[];
    try {
      final stored = await cache.read(
        CacheStores.general,
        key,
        ignoreExpiry: true,
      );
      final list = stored?.value['mutations'] as List?;
      if (list != null) {
        initial = [
          for (final item in list.whereType<Map>())
            QueuedMutation.fromJson(item.cast<String, dynamic>()),
        ];
      }
    } on Object {
      initial = const [];
    }
    return MutationQueue(
      provider: provider,
      initial: initial,
      malAuthenticated: malAuthenticated,
      clock: clock,
      tokenUserIdOf: tokenUserIdOf,
      credentialsOf: credentialsOf,
      persist: (pending) => cache.write(CacheStores.general, key, {
        'mutations': [for (final m in pending) m.toJson()],
      }),
    );
  }

  final TrackingProvider provider;
  final MutationRateLimit rateLimit;
  final PersistQueue? _persist;
  final Clock _clock;
  final int? Function(String token)? _tokenUserIdOf;
  final MutationCredentials? Function(int userId)? _credentialsOf;

  final List<QueuedMutation> _queue;
  Future<void> _persistFuture = Future.value();

  /// True while user lists are being fetched — decides whether an executed
  /// mutation must be queued (to be re-applied after the fetch lands) or can
  /// be applied immediately.
  bool isFetchingList = false;

  bool get hasPending => _queue.isNotEmpty;

  List<QueuedMutation> get pending => List.unmodifiable(_queue);

  /// Completes when the latest persistence write has settled (test hook).
  Future<void> get persisted => _persistFuture;

  void _schedulePersist() {
    final persist = _persist;
    if (persist == null) return;
    final pending = [
      for (final m in _queue)
        if (!m.executed) m,
    ];
    _persistFuture = _persistFuture.then((_) => persist(pending));
  }

  /// Strips credentials from the variables, replacing them with a
  /// `tokenUserId` reference so tokens are never persisted.
  Map<String, dynamic> _stripToken(Map<String, dynamic> variables) {
    final token = variables['token'];
    if (token is! String) return variables;
    final userId = _tokenUserIdOf?.call(token);
    final safe = {...variables}
      ..remove('token')
      ..remove('refresh_in');
    if (userId != null) safe['tokenUserId'] = userId;
    return safe;
  }

  /// Restores token/refresh_in from the `tokenUserId` reference right before
  /// execution.
  QueuedMutation resolveTokenFields(QueuedMutation mutation) {
    final userId = mutation.variables['tokenUserId'];
    if (userId is! num) return mutation;
    final credentials = _credentialsOf?.call(userId.toInt());
    if (credentials == null) return mutation;
    final variables = {...mutation.variables}..remove('tokenUserId');
    variables['token'] = credentials.token;
    if (credentials.refreshIn != null) {
      variables['refresh_in'] = credentials.refreshIn;
    }
    return mutation.copyWith(variables: variables);
  }

  /// Adds a mutation. Returns false when [executed] is true and no list
  /// fetch is in flight — the caller should apply the result immediately
  /// instead of queueing.
  bool enqueue(
    MutationType type,
    int mediaId,
    Map<String, dynamic> variables, {
    Map<String, dynamic>? result,
    int? progressBefore,
    bool executed = true,
  }) {
    if (executed && !isFetchingList) return false;
    final mutation = QueuedMutation(
      type: type,
      mediaId: mediaId,
      variables: _stripToken(variables),
      result: result,
      progressBefore: progressBefore,
      executed: executed,
      queuedAt: _clock.now(),
    );

    if (type == MutationType.favourite) {
      final index = _queue.indexWhere(
        (m) => m.type == MutationType.favourite && m.mediaId == mediaId,
      );
      if (index != -1) {
        // Two toggles cancel out.
        _queue.removeAt(index);
        _schedulePersist();
        return true;
      }
    } else {
      final index = _queue.indexWhere(
        (m) => m.type == type && m.mediaId == mediaId,
      );
      if (index != -1) {
        // Last write wins, preserving the original baseline and queue time.
        _queue[index] = mutation.copyWith(
          progressBefore: _queue[index].progressBefore,
          queuedAt: _queue[index].queuedAt,
        );
        _schedulePersist();
        return true;
      }
    }

    _queue.add(mutation);
    _schedulePersist();
    return true;
  }

  /// The pre-mutation progress for a queued entry mutation — used so a
  /// second write while offline keeps the original baseline instead of
  /// reading the already-optimistically-patched cache.
  int? progressBeforeOf(int mediaId) {
    for (final m in _queue) {
      if (m.type == MutationType.entry && m.mediaId == mediaId) {
        return m.progressBefore;
      }
    }
    return null;
  }

  /// Flushes after a list read settles or on reconnect.
  ///
  /// Executed mutations are re-applied to the local cache via [apply] (they
  /// raced the list fetch); offline mutations are also applied when they
  /// carry a result, then sent to the API via [execute] under the provider
  /// rate limit. A mutation leaves the persisted queue only after its API
  /// call succeeds; failures stay queued for the next flush.
  ///
  /// [freshProgressOf] reports the server's current progress for a media
  /// (from the just-fetched lists) and powers stale-write detection.
  Future<void> flush({
    int? Function(int mediaId)? freshProgressOf,
    required Future<void> Function(QueuedMutation mutation) apply,
    required Future<void> Function(QueuedMutation mutation) execute,
  }) async {
    if (_queue.isEmpty) return;
    final snapshot = [..._queue];
    // Executed (session-only race) mutations clear upfront; offline ones
    // stay persisted until they actually go through.
    _queue.removeWhere((m) => m.executed);
    _schedulePersist();

    final offline = [
      for (final m in snapshot)
        if (!m.executed) m,
    ];
    final executedNewestFirst = [
      for (final m in snapshot.reversed)
        if (m.executed) m,
    ];

    // Re-apply to the local cache immediately so the UI is current no
    // matter how long the rate-limited API calls take.
    for (final mutation in [...executedNewestFirst, ...offline]) {
      if (!_validate(mutation, freshProgressOf)) continue;
      if (mutation.executed || mutation.result != null) {
        await apply(resolveTokenFields(mutation));
      }
    }

    await _executeRateLimited(offline, freshProgressOf, execute);
  }

  Future<void> _executeRateLimited(
    List<QueuedMutation> mutations,
    int? Function(int mediaId)? freshProgressOf,
    Future<void> Function(QueuedMutation mutation) execute,
  ) async {
    var executedThisWindow = 0;
    var windowStart = _clock.now();
    for (final mutation in mutations) {
      if (!_validate(mutation, freshProgressOf)) {
        // Stale — discard and drop from the persisted queue.
        _queue.removeWhere((m) => m._same(mutation));
        _schedulePersist();
        continue;
      }

      if (executedThisWindow >= rateLimit.perMinute) {
        final elapsed = _clock.now().difference(windowStart);
        final wait = const Duration(minutes: 1) - elapsed;
        if (wait > Duration.zero) await _clock.sleep(wait);
        executedThisWindow = 0;
        windowStart = _clock.now();
      }

      try {
        await execute(resolveTokenFields(mutation));
        // Succeeded — leave the persisted queue.
        _queue.removeWhere((m) => m._same(mutation));
        _schedulePersist();
        executedThisWindow++;
      } on Object {
        // Keep it queued; the next flush retries.
      }
      if (rateLimit.spacing > Duration.zero) {
        await _clock.sleep(rateLimit.spacing);
      }
    }
  }

  /// Stale-write detection: an entry mutation is invalid when the server's
  /// progress already moved past the baseline recorded at queue time.
  /// delete/favourite are always valid.
  bool _validate(
    QueuedMutation mutation,
    int? Function(int mediaId)? freshProgressOf,
  ) {
    if (mutation.type != MutationType.entry) return true;
    final targetProgress = mutation.executed
        ? (mutation.result?['progress'] as num?)
        : mutation.variables['episode'] as num?;
    if (targetProgress == null) return true;
    final freshProgress = freshProgressOf?.call(mutation.mediaId);
    if (freshProgress == null) return true;
    final progressBefore = mutation.progressBefore ?? freshProgress;
    return freshProgress <= progressBefore;
  }
}
