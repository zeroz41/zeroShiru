/// Typed debrid errors and the cooperative-cancellation primitive the layer's
/// try/finally discipline runs on. Port of crates/debrid/src/error.rs; where
/// Rust released claims from `Drop`, Dart releases them from `finally` blocks
/// unwound by a [CancelledException].
library;

import 'dart:async' show Completer;

import '../../domain/models/availability.dart';
import '../../domain/ports/debrid_client.dart';

/// The rich internal error: the domain's [DebridException] vocabulary plus the
/// HTTP status and service error code retry policy and sweeps key off.
class DebridFailure extends DebridException {
  const DebridFailure(super.kind, super.message, {this.status, this.code});

  const DebridFailure.auth(String message, {int? status, String? code})
    : this(DebridErrorKind.auth, message, status: status, code: code);

  const DebridFailure.network(String message)
    : this(DebridErrorKind.network, message);

  const DebridFailure.timeout(String message)
    : this(DebridErrorKind.timeout, message);

  const DebridFailure.notCached()
    : this(
        DebridErrorKind.notCached,
        'Torrent is not cached on the debrid service',
      );

  const DebridFailure.unavailable([
    String message = 'The debrid service cannot serve this torrent',
  ]) : this(DebridErrorKind.unavailable, message);

  const DebridFailure.rejected(String message)
    : this(DebridErrorKind.rejected, message);

  const DebridFailure.service(String message, {int? status, String? code})
    : this(DebridErrorKind.service, message, status: status, code: code);

  /// HTTP status, when one applies (auth and service errors only).
  final int? status;

  /// The service's own error code, when it named one.
  final String? code;

  /// What this error proves about a release, or `null` when it proves nothing.
  /// A timeout or a rate limit describes the moment, not the release.
  Availability? get provenAvailability => switch (kind) {
    DebridErrorKind.notCached => Availability.available,
    DebridErrorKind.unavailable => Availability.unavailable,
    _ => null,
  };

  /// Whether the service wants fewer requests rather than this release being a
  /// problem. A `429` always counts; providers with their own codes override
  /// at the provider level.
  bool get throttled => status == 429;
}

/// Thrown out of a raced await when the caller walked away. Every claim on the
/// way up (limiter tickets, sweep flags, in-flight hashes, orphan guards) is
/// released by the `finally`/`catch` blocks this unwinds through.
class CancelledException implements Exception {
  const CancelledException();

  @override
  String toString() => 'CancelledException: the caller moved on';
}

/// Cooperative cancellation: the Dart stand-in for Rust dropping a future.
/// Await points that must stop promptly race through [race]; cancelling makes
/// each of them throw [CancelledException], so `try`/`finally` runs.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _waiters = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final waiters = List.of(_waiters);
    _waiters.clear();
    for (final wake in waiters) {
      wake();
    }
  }

  /// Completes with [future]'s result, or throws [CancelledException] the
  /// moment [cancel] runs. The abandoned [future]'s eventual result or error
  /// is swallowed.
  Future<T> race<T>(Future<T> future) {
    if (_cancelled) {
      // still consume the future's error so nothing surfaces unhandled
      future.then((_) {}, onError: (Object _) {});
      return Future.error(const CancelledException());
    }
    final completer = Completer<T>();
    void onCancel() {
      if (!completer.isCompleted) {
        completer.completeError(const CancelledException());
      }
    }

    _waiters.add(onCancel);
    future.then(
      (value) {
        _waiters.remove(onCancel);
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        _waiters.remove(onCancel);
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    return completer.future;
  }
}

/// Races [future] against [cancel] when a token is present.
Future<T> raced<T>(Future<T> future, CancelToken? cancel) =>
    cancel == null ? future : cancel.race(future);
