/// Is there a working connection? Ported from
/// crates/networking/src/reachability.rs (redo branch).
///
/// The endpoints promise `204 No Content` and an empty body, so anything
/// else answering is something else answering (a captive portal, a hotel
/// splash page). The other rule: a slow link is not an outage. A timeout is
/// not a measurement — it is the absence of one — so it reports
/// [Reachability.unknown] and the caller keeps whatever it already believed.
/// Only a connection that fails outright, at every endpoint, is offline.
library;

import '../../domain/ports/http_transport.dart';

/// What a probe found out.
enum Reachability {
  /// An endpoint answered exactly as promised. There is a connection.
  online,

  /// Something answered, but not what was asked for. Reachable, but not the
  /// internet.
  portal,

  /// Every endpoint failed to connect at all. This is a real answer.
  offline,

  /// Nothing answered in time, or the endpoints themselves are broken. NOT
  /// an answer: callers keep the state they had rather than reporting an
  /// outage.
  unknown;

  /// The wire name, which is what crosses the bridge to the UI.
  String get wire => name;
}

/// Endpoints that promise `204 No Content` and an empty body. More than one,
/// so a single vendor having a bad day is never mistaken for the user being
/// offline.
const List<String> reachabilityEndpoints = [
  'https://cp.cloudflare.com/generate_204',
  'https://connectivitycheck.gstatic.com/generate_204',
];

/// The floor under any caller's timeout. A probe is a background question,
/// and answering it impatiently on a slow link is how an app decides a
/// working connection is an outage.
const Duration minProbeTimeout = Duration(seconds: 2);

class ReachabilityProbe {
  /// [endpoints] is overridable so tests need no network.
  const ReachabilityProbe(
    this._transport, {
    this.endpoints = reachabilityEndpoints,
  });

  final HttpTransport _transport;
  final List<String> endpoints;

  /// Asks the endpoints in order, stopping at the first that answers
  /// properly.
  Future<Reachability> probe({Duration timeout = minProbeTimeout}) async {
    final budget = timeout < minProbeTimeout ? minProbeTimeout : timeout;
    var portal = false;
    // Only a connection that fails outright says "offline", and only if
    // they all do.
    var allFailedToConnect = true;
    var asked = false;

    for (final endpoint in endpoints) {
      asked = true;
      try {
        final response = await _transport.send(
          HttpRequest(
            HttpMethod.get,
            Uri.parse(endpoint),
            headers: const {
              // A cached 204 would answer for a connection no longer there.
              'Cache-Control': 'no-store, no-cache',
              'Pragma': 'no-cache',
            },
            timeout: budget,
          ),
        );
        allFailedToConnect = false;
        switch (_read(response)) {
          case Reachability.online:
            return Reachability.online;
          case Reachability.portal:
            portal = true;
          default:
            break; // The endpoint itself is broken; says nothing about us.
        }
      } on TimeoutException {
        // A timeout is not a connect-level failure — it withholds the
        // offline verdict.
        allFailedToConnect = false;
      } on NetworkException {
        // Connect-level failure; counts toward offline.
      }
    }

    if (portal) return Reachability.portal;
    if (asked && allFailedToConnect) return Reachability.offline;
    return Reachability.unknown;
  }

  /// What one answer means. The endpoints promise `204` and nothing else,
  /// so a body or any other success status is somebody else answering on
  /// their behalf.
  static Reachability _read(HttpResponse response) {
    if (response.status == 204 && response.bodyBytes.isEmpty) {
      return Reachability.online;
    }
    if (response.status >= 200 && response.status < 400) {
      return Reachability.portal;
    }
    // 4xx/5xx is the endpoint being unwell, which is not news about the
    // link.
    return Reachability.unknown;
  }
}
