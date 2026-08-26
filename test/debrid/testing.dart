/// Test doubles shared by the debrid tests: a scripted HTTP transport and a
/// manual clock. Port of crates/debrid/src/testing.rs.
library;

import 'dart:async' show Completer;
import 'dart:convert';
import 'dart:typed_data';

import 'package:zero/domain/ports/http_transport.dart';

/// What a matched route does: answer, or fail the way a bad connection does.
sealed class Outcome {
  const Outcome();
}

class AnswerOutcome extends Outcome {
  const AnswerOutcome(this.status, this.body, [this.headers = const {}]);

  final int status;
  final String body;
  final Map<String, String> headers;
}

/// The link is down, or the app considers itself offline.
class NetworkOutcome extends Outcome {
  const NetworkOutcome(this.message);

  final String message;
}

/// The request outlived its budget. Says nothing about the release.
class TimeoutOutcome extends Outcome {
  const TimeoutOutcome(this.afterMs);

  final int afterMs;
}

/// The request never completes — the connection is accepted and nothing comes
/// back. For tests that cancel a call mid-flight at a known request.
class PendingOutcome extends Outcome {
  const PendingOutcome();
}

/// One scripted exchange: a URL substring to match and what to answer with.
class Route {
  const Route(this.matches, this.outcome);

  Route.json(this.matches, int status, String body)
    : outcome = AnswerOutcome(status, body);

  /// A route the link never delivers.
  Route.offline(this.matches)
    : outcome = const NetworkOutcome('Network request failed');

  /// A route that outlives its budget.
  Route.timeout(this.matches, int afterMs) : outcome = TimeoutOutcome(afterMs);

  /// A route that never answers and never times out.
  Route.pending(this.matches) : outcome = const PendingOutcome();

  final String matches;
  final Outcome outcome;

  Route withHeaders(Map<String, String> headers) {
    final current = outcome;
    if (current is AnswerOutcome) {
      return Route(
        matches,
        AnswerOutcome(current.status, current.body, headers),
      );
    }
    return this;
  }
}

/// Answers requests from a script, recording everything it was asked.
/// Optionally simulates a link: every round trip costs `latencyMs` on the
/// clock it shares with the provider.
class MockTransport implements HttpTransport {
  MockTransport(this._routes);

  List<Route> _routes;
  final List<HttpRequest> requests = [];
  ManualClock? _linkClock;
  int _linkLatencyMs = 0;

  /// Makes every request take [latencyMs] of clock time, like a slow link.
  MockTransport onLink(ManualClock clock, int latencyMs) {
    _linkClock = clock;
    _linkLatencyMs = latencyMs;
    return this;
  }

  /// Replaces the script, for a link that comes back up mid-test.
  void rescript(List<Route> routes) {
    _routes = routes;
  }

  /// URLs of every request made, in order.
  List<String> get urls => [
    for (final request in requests) request.url.toString(),
  ];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    final url = request.url.toString();
    requests.add(request);
    _linkClock?.advance(_linkLatencyMs);
    Route? route;
    for (final candidate in _routes) {
      if (url.contains(candidate.matches)) {
        route = candidate;
        break;
      }
    }
    if (route == null) {
      throw NetworkException('no scripted answer for $url');
    }
    switch (route.outcome) {
      case AnswerOutcome(:final status, :final body, :final headers):
        return HttpResponse(status, {
          for (final entry in headers.entries)
            entry.key.toLowerCase(): entry.value,
        }, Uint8List.fromList(utf8.encode(body)));
      case NetworkOutcome(:final message):
        throw NetworkException(message);
      case TimeoutOutcome(:final afterMs):
        throw TimeoutException(Duration(milliseconds: afterMs));
      case PendingOutcome():
        return Completer<HttpResponse>().future;
    }
  }
}

/// Like MockTransport but bodies may vary per hit, for status polling and
/// paging. First matching URL substring wins, so order routes carefully.
/// Port of the Real-Debrid tests' `Script` transport.
class ScriptTransport implements HttpTransport {
  ScriptTransport(this.routes);

  /// (pattern, respond(hit) -> (status, body))
  final List<(String, (int, String) Function(int))> routes;
  final Map<String, int> _hits = {};
  final List<HttpRequest> requests = [];

  List<String> get urls => [
    for (final request in requests) request.url.toString(),
  ];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    final url = request.url.toString();
    requests.add(request);
    for (final (pattern, respond) in routes) {
      if (url.contains(pattern)) {
        final hit = _hits[pattern] ?? 0;
        _hits[pattern] = hit + 1;
        final (status, body) = respond(hit);
        return HttpResponse(
          status,
          const {},
          Uint8List.fromList(utf8.encode(body)),
        );
      }
    }
    throw NetworkException('no scripted answer for $url');
  }
}

/// A fixed response whatever the hit count.
(int, String) Function(int) fixed(int status, String body) =>
    (_) => (status, body);

/// A clock tests advance by hand; sleeping advances it instead of waiting —
/// but still yields through the event queue, so a test can watch two requests
/// genuinely overlap.
class ManualClock implements Clock {
  int _nowMs = 1000000;

  int get nowMs => _nowMs;

  void advance(int ms) {
    _nowMs += ms;
  }

  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_nowMs);

  @override
  Future<void> sleep(Duration duration) async {
    advance(duration.inMilliseconds);
    await Future<void>(() {});
  }
}

/// Lets a test pump the event loop until parked work has progressed.
Future<void> pumpEventQueue([int times = 20]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>(() {});
  }
}

/// A cyclic barrier: [wait] completes once [parties] callers have arrived,
/// then resets for the next cycle. Stand-in for tokio::sync::Barrier.
class Barrier {
  Barrier(this.parties);

  final int parties;
  int _arrived = 0;
  Completer<void> _gate = Completer<void>();

  Future<void> wait() {
    _arrived += 1;
    if (_arrived >= parties) {
      final gate = _gate;
      _arrived = 0;
      _gate = Completer<void>();
      gate.complete();
      return Future.value();
    }
    return _gate.future;
  }
}
