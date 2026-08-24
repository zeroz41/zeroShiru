/// Shared debrid orchestration: availability memory, bounded sweeps, probe
/// handover and the end-to-end resolve deadline. Port of
/// `crates/debrid/src/manager.rs` from the proven redo branch.
library;

import 'dart:async';
import 'dart:math' as math;

import '../../domain/models/availability.dart';
import '../../domain/ports/debrid_client.dart';
import 'client.dart';
import 'errors.dart';
import 'hash.dart';
import 'providers/provider.dart';

const int _maxProbeFailures = 3;
const int _maxProbeConcurrency = 3;
const int _probeHandoverMs = 5000;
const int _probeHandoverPollMs = 100;
const int _quietResolveBudgetMs = 15000;
const int _resolveHealthPollMs = 500;

/// A provider plus the state shared by availability checks and resolves for
/// one account. Callers retain one instance so rate limits and remembered
/// answers survive between operations.
class ManagedDebridProvider {
  ManagedDebridProvider(this.provider);

  final DebridProvider provider;

  bool _sweeping = false;
  final Set<String> _inFlight = {};

  DebridApiClient get client => provider.client;
  bool get sweeping => _sweeping;

  /// Turns a magnet into secure player-ready links within one end-to-end
  /// budget. Once any request proves the service quiet, the remaining chain
  /// gets only the shorter quiet budget.
  Future<ResolvedFiles> resolve(
    String magnet,
    ResolveOptions opts, {
    CancelToken? cancel,
  }) async {
    await _awaitProbe(magnet, cancel);

    final operation = CancelToken();
    final deadlineCancel = CancelToken();
    if (cancel?.isCancelled ?? false) operation.cancel();
    final externalDone = Completer<void>();
    final externalWatch = cancel
        ?.race(externalDone.future)
        .then<void>(
          (_) {},
          onError: (Object error) {
            if (error is CancelledException) operation.cancel();
          },
        );

    final work = provider
        .resolve(magnet, opts, cancel: operation)
        .then<_ResolveRace>(
          _Resolved.new,
          onError: (Object error, StackTrace stack) =>
              _ResolveError(error, stack),
        );
    final deadline =
        _resolveDeadline(
          provider.config.timeouts.resolveMs,
          deadlineCancel,
        ).then<_ResolveRace>(
          _Deadline.new,
          onError: (Object error, StackTrace stack) {
            // Cancellation is how the winning work future retires this watcher.
            if (error is CancelledException) return const _DeadlineCancelled();
            return _ResolveError(error, stack);
          },
        );

    try {
      while (true) {
        final outcome = await Future.any([work, deadline]);
        switch (outcome) {
          case _Resolved(:final value):
            deadlineCancel.cancel();
            return ResolvedFiles(
              hash: value.hash,
              name: value.name,
              files: secureFiles(value.files, provider.config.title),
              targetPath: value.targetPath,
            );
          case _ResolveError(:final error, :final stack):
            deadlineCancel.cancel();
            Error.throwWithStackTrace(error, stack);
          case _Deadline(:final elapsedMs):
            operation.cancel();
            // Consume the abandoned provider result so it cannot surface as an
            // unhandled asynchronous error after the caller receives timeout.
            await work;
            throw DebridFailure.timeout(
              '${provider.config.title} did not answer with a playable link '
              'within ${(elapsedMs / 1000).ceil()}s',
            );
          case _DeadlineCancelled():
            // The provider result won but its completion is queued one turn
            // behind the deadline cancellation.
            continue;
        }
      }
    } finally {
      if (!externalDone.isCompleted) externalDone.complete();
      deadlineCancel.cancel();
      await externalWatch;
    }
  }

  Future<int> _resolveDeadline(int fullBudgetMs, CancelToken cancel) async {
    final started = client.clock.nowMs;
    final fullDeadline = started + fullBudgetMs;
    int? quietDeadline = client.quiet ? started + _quietResolveBudgetMs : null;
    while (true) {
      final now = client.clock.nowMs;
      if (quietDeadline == null && client.quiet) {
        quietDeadline = now + _quietResolveBudgetMs;
      }
      final deadline = math.min(quietDeadline ?? fullDeadline, fullDeadline);
      if (now >= deadline) return math.min(now - started, fullBudgetMs);
      await raced(
        client.clock.sleepMs(math.min(_resolveHealthPollMs, deadline - now)),
        cancel,
      );
    }
  }

  /// A resolve waits briefly for a probe of the same release. Otherwise the
  /// probe can remove the account torrent while playback is linking it.
  Future<void> _awaitProbe(String magnet, CancelToken? cancel) async {
    final hash = parseHash(magnet);
    if (hash == null) return;
    final deadline = client.clock.nowMs + _probeHandoverMs;
    while (_inFlight.contains(hash)) {
      final now = client.clock.nowMs;
      if (now >= deadline) return;
      await raced(
        client.clock.sleepMs(math.min(_probeHandoverPollMs, deadline - now)),
        cancel,
      );
    }
  }

  /// Reads the account's own torrent list. This is the free badge source and
  /// the provider client shares its one-minute listing cache with resolves.
  Future<Map<String, Availability>> listAvailability({
    CancelToken? cancel,
  }) async {
    final known = await provider.listAvailability(cancel: cancel);
    for (final MapEntry(:key, :value) in known.entries) {
      client.remember(key, value);
    }
    return known;
  }

  /// Normalized hashes whose answer is neither remembered nor currently being
  /// probed, retaining the result-list order.
  List<String> unknownHashes(List<String> magnetsOrHashes) =>
      DebridApiClient.normalizeHashes(magnetsOrHashes, provider.config.maxAsk)
          .where(
            (hash) => client.recall(hash) == null && !_inFlight.contains(hash),
          )
          .toList();

  /// Answers as much of a results list as the provider can. Missing entries are
  /// unknown, never implicitly not cached.
  Future<Map<String, Availability>> checkAvailability(
    List<String> magnetsOrHashes, {
    void Function(String hash, Availability state)? onAnswer,
    CancelToken? cancel,
  }) async {
    final config = provider.config;
    final candidates = DebridApiClient.normalizeHashes(
      magnetsOrHashes,
      config.maxAsk,
    );
    final answers = <String, Availability>{};
    final unknown = <String>[];
    for (final hash in candidates) {
      final known = client.recall(hash);
      if (known == null) {
        if (!_inFlight.contains(hash)) unknown.add(hash);
      } else {
        answers[hash] = known;
      }
    }
    if (unknown.isEmpty || config.availabilityCheck == AvailabilityCheck.none) {
      return answers;
    }

    final guarded = config.checkAddsMagnets;
    if (guarded && _sweeping) return answers;
    if (guarded) _sweeping = true;
    try {
      if (client.orphaned > 0) await provider.retryCleanup();
      switch (config.availabilityCheck) {
        case AvailabilityCheck.batch:
          await _batch(unknown, (hash, state) {
            answers[hash] = state;
            onAnswer?.call(hash, state);
          }, cancel);
        case AvailabilityCheck.probe:
          await _sweep(unknown, (hash, state) {
            answers[hash] = state;
            onAnswer?.call(hash, state);
          }, cancel);
        case AvailabilityCheck.none:
          break;
      }
      return answers;
    } finally {
      if (guarded) _sweeping = false;
    }
  }

  Future<void> _batch(
    List<String> hashes,
    void Function(String, Availability) answer,
    CancelToken? cancel,
  ) async {
    final maxBatch = provider.config.maxBatch;
    final work = <Future<void>>[];
    for (var start = 0; start < hashes.length; start += maxBatch) {
      final chunk = hashes.sublist(
        start,
        math.min(start + maxBatch, hashes.length),
      );
      work.add(() async {
        final states = await provider.checkAvailabilityBatch(
          chunk,
          cancel: cancel,
        );
        for (final hash in chunk) {
          final state = states[hash] ?? Availability.unknown;
          client.remember(hash, state);
          if (state != Availability.unknown) answer(hash, state);
        }
      }());
    }
    await Future.wait(work);
  }

  Future<void> _sweep(
    List<String> hashes,
    void Function(String, Availability) answer,
    CancelToken? cancel,
  ) async {
    var next = 0;
    var failures = 0;
    DebridFailure? stopped;

    Future<void> worker() async {
      while (stopped == null && next < hashes.length) {
        final hash = hashes[next++];
        try {
          final state = await _probe(hash, cancel);
          if (state != null) {
            answer(hash, state);
            failures = 0;
          }
        } on CancelledException {
          rethrow;
        } on DebridFailure catch (error) {
          failures += 1;
          if (error.kind == DebridErrorKind.auth ||
              provider.throttled(error) ||
              failures >= _maxProbeFailures) {
            stopped = error;
          }
        }
      }
    }

    final workers = math.min(math.max(hashes.length, 1), _maxProbeConcurrency);
    await Future.wait([for (var index = 0; index < workers; index++) worker()]);
    final failure = stopped;
    if (failure != null && failure.kind == DebridErrorKind.auth) throw failure;
  }

  Future<Availability?> _probe(String hash, CancelToken? cancel) async {
    if (!_inFlight.add(hash)) return null;
    try {
      Availability state;
      try {
        state = await provider.probeAvailability(hash, cancel: cancel);
      } on DebridFailure catch (error) {
        final proven = error.provenAvailability;
        if (proven == null) rethrow;
        state = proven;
      }
      if (state == Availability.unknown) {
        throw DebridFailure.service(
          '${provider.config.title} gave no usable answer for $hash',
        );
      }
      client.remember(hash, state);
      return state;
    } finally {
      _inFlight.remove(hash);
    }
  }
}

sealed class _ResolveRace {
  const _ResolveRace();
}

class _Resolved extends _ResolveRace {
  const _Resolved(this.value);
  final ResolvedFiles value;
}

class _ResolveError extends _ResolveRace {
  const _ResolveError(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

class _Deadline extends _ResolveRace {
  const _Deadline(this.elapsedMs);
  final int elapsedMs;
}

class _DeadlineCancelled extends _ResolveRace {
  const _DeadlineCancelled();
}
