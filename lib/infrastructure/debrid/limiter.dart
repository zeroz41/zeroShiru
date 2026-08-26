/// Request pacing. Port of crates/debrid/src/limiter.rs — the Bottleneck
/// limiter the JS base class wrapped every request in.
///
/// This exists for a measured reason: TorBox answered a 60-link burst against
/// `/torrents/requestdl` with `429` and `retry-after: 300`, five minutes of
/// the account frozen mid-play. With pacing, a pack's links go out together
/// and still stay inside the allowance.
///
/// Three things hold a request back, checked in that order:
/// 1. A pause the service asked for (a 429's retry-after stops the account).
/// 2. The allowance, where the service publishes one: N per rolling window.
/// 3. Concurrency and spacing: at most `maxConcurrent` in flight, starts never
///    closer together than `minTimeMs`.
///
/// FIFO ticketing is load-bearing: providers deliberately put the user's
/// episode at the head of a pack's link burst; a limiter that reorders plays
/// the wrong episode under load.
library;

import 'dart:collection';

import '../../domain/ports/http_transport.dart';
import 'errors.dart';

/// How often a request waiting on a full pipe looks again.
const int _busyPollMs = 20;

/// What a service will put up with. The numbers live on `ProviderConfig`.
class Limits {
  const Limits({
    required this.maxConcurrent,
    required this.minTimeMs,
    this.reservoir,
  });

  /// Requests in flight at once.
  final int maxConcurrent;

  /// Smallest gap between two request starts, milliseconds.
  final int minTimeMs;

  /// Requests per window where the service publishes an allowance:
  /// `(count, windowMs)`.
  final (int, int)? reservoir;
}

/// A diagnostic view of the limiter. Plain data.
class LimiterHealth {
  const LimiterHealth({
    required this.inFlight,
    required this.waiting,
    required this.pausedForMs,
  });

  final int inFlight;
  final int waiting;
  final int pausedForMs;
}

/// A request's place in the pipe, given back when the request finishes —
/// including when it fails, which is what keeps a run of errors from wedging
/// the limiter. Always release in a `finally`.
class Permit {
  Permit._(this._limiter);

  final Limiter _limiter;
  bool _held = true;

  void release() {
    if (!_held) return;
    _held = false;
    if (_limiter._inFlight > 0) _limiter._inFlight -= 1;
  }
}

class Limiter {
  Limiter(this.limits) : _tokens = limits.reservoir?.$1 ?? 0;

  final Limits limits;

  int _inFlight = 0;

  /// Earliest a request may start, so starts stay `minTimeMs` apart.
  int _nextStart = 0;

  /// Nothing starts before this: the service asked for a pause.
  int _pausedUntil = 0;

  /// Requests left in the current window, and when that window opened.
  int _tokens;
  int _windowOpened = 0;

  /// Everyone waiting, in the order they arrived. Only the front may take a
  /// slot — first acquire() call gets the first slot, whatever order the
  /// event loop wakes waiters in.
  final SplayTreeSet<int> _waiting = SplayTreeSet<int>();
  int _nextTicket = 0;

  /// Waits until this request may go out, then holds a slot until the permit
  /// is released. The ticket is given up whether the request goes out or the
  /// caller is cancelled mid-wait — a dropped waiter must not wedge the queue.
  Future<Permit> acquire(Clock clock, {CancelToken? cancel}) async {
    final ticket = _nextTicket++;
    _waiting.add(ticket);
    try {
      while (true) {
        if (cancel != null && cancel.isCancelled) {
          throw const CancelledException();
        }
        final wait = _take(clock.now().millisecondsSinceEpoch, ticket);
        if (wait == 0) return Permit._(this);
        await raced(clock.sleep(Duration(milliseconds: wait)), cancel);
      }
    } finally {
      _waiting.remove(ticket);
    }
  }

  /// Takes a slot, or says how long to wait before asking again.
  int _take(int now, int ticket) {
    // whoever arrived first goes first
    if (_waiting.isNotEmpty && _waiting.first != ticket) return _busyPollMs;
    if (now < _pausedUntil) return _pausedUntil - now;
    final reservoir = limits.reservoir;
    if (reservoir != null) {
      final (count, window) = reservoir;
      if (now - _windowOpened >= window) {
        _tokens = count;
        _windowOpened = now;
      }
      if (_tokens == 0) {
        // the window closes when it closes; asking sooner only earns a refusal
        final wait = _windowOpened + window - now;
        return wait < 1 ? 1 : wait;
      }
    }
    if (_inFlight >= limits.maxConcurrent) return _busyPollMs;
    if (now < _nextStart) return _nextStart - now;
    _inFlight += 1;
    _nextStart = now + limits.minTimeMs;
    if (reservoir != null && _tokens > 0) _tokens -= 1;
    return 0;
  }

  /// The service asked for a pause — a `429` with a `retry-after`. It stops
  /// every request on this account, not only the one that earned it. Extends
  /// an existing pause, never shortens it.
  void pauseFor(Clock clock, int ms) {
    final until = clock.now().millisecondsSinceEpoch + ms;
    if (until > _pausedUntil) _pausedUntil = until;
  }

  /// Whether the service has this account paused right now.
  bool paused(Clock clock) => clock.now().millisecondsSinceEpoch < _pausedUntil;

  /// The pipe as it stands, for diagnostics.
  LimiterHealth snapshot(Clock clock) {
    final now = clock.now().millisecondsSinceEpoch;
    return LimiterHealth(
      inFlight: _inFlight,
      waiting: _waiting.length,
      pausedForMs: _pausedUntil > now ? _pausedUntil - now : 0,
    );
  }
}
