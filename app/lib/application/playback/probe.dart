/// Proof that a stream link actually serves bytes, before and after the player
/// trusts it. Port of `frontend/common/modules/playback/probe.js`.
///
/// The lesson this encodes: a debrid resolve can succeed in under a second and
/// hand back a link whose CDN node never sends a single byte. "Cached" is a
/// claim about the service's storage; it says nothing about the one host the
/// link points at. And the link cannot be swapped for a fresh one — TorBox pins
/// one URL per (torrent, file), so asking again returns the identical dead
/// address. The only honest moves are to prove the link early, retry it in
/// place, or give up fast and let the fallback machinery play something that
/// works. Waiting is never one of them.
///
/// A probe is the player's own opening move made early — an open-ended range
/// request read until a real chunk has arrived, then dropped. Against a healthy
/// node it costs a few hundred milliseconds and doubles as the warm-up (DNS,
/// TLS, and the CDN locating the file all happen under it, on the connection
/// pool playback is about to use).
library;

import 'dart:async';

import '../../infrastructure/network/transport.dart';

/// How long one probe waits before calling the link dead. Generous against a
/// slow CDN round trip, but two probes and the pause between them must land
/// well inside the stall watchdog's 15s window, so a dead link is decided
/// before the spinner machinery stirs.
const int probeTimeoutMs = 6000;

/// The pause before a failed probe is tried once more. One flap is weather; two
/// is a verdict.
const int probeRetryDelayMs = 1500;

/// How much body a probe must actually receive before the link counts as
/// streaming. Sized to prove sustained delivery without costing real time: a
/// healthy node serves it in well under a second, and a sick one has been
/// watched serving headers and two-byte ranges instantly while never delivering
/// a streaming body at all.
const int probeBytes = 262144;

/// What a probe decided about a link.
class ProbeVerdict {
  const ProbeVerdict({
    required this.alive,
    this.status,
    this.reason,
    required this.elapsedMs,
    this.received = 0,
    this.attempts,
  });

  final bool alive;
  final int? status;
  final String? reason;
  final int elapsedMs;
  final int received;

  /// How many probes it took, when the verdict came from [verifiedStream].
  final int? attempts;

  ProbeVerdict withAttempts(int attempts) => ProbeVerdict(
    alive: alive,
    status: status,
    reason: reason,
    elapsedMs: elapsedMs,
    received: received,
    attempts: attempts,
  );
}

/// The file a resolve should be judged by: the one the service picked to play.
/// Pack files land on different CDN nodes, so probing an arbitrary file proves
/// nothing about the one the user is about to watch.
({String? path, String? url})? probeTarget(
  List<({String? path, String? url})>? files,
  String? targetPath,
) {
  if (files == null || files.isEmpty) return null;
  if (targetPath != null) {
    for (final file in files) {
      if (file.path == targetPath) return file;
    }
  }
  // a resolve that named no pick — or one that matches nothing — is judged by
  // its first file rather than probing nothing
  return files.first;
}

/// The URL to re-open a stream under after `attempt` failed tries. The CDN
/// accepts unknown query parameters, and a changed URL is a changed identity at
/// every layer — connection pool, media pipeline, any middlebox — where
/// re-loading the same address has been observed to change nothing at all.
/// Attempt 0 leaves the URL alone.
String bustedUrl(String? url, [int attempt = 0]) {
  if (url == null || url.isEmpty || attempt == 0) return url ?? '';
  return '$url${url.contains('?') ? '&' : '?'}zsr=$attempt';
}

/// Asks the link to actually STREAM, with the SAME request shape the player
/// sends: an open-ended range (`bytes=0-`), alive only once the body has
/// delivered [probeBytes]. Not a HEAD, not two bytes, and never a bounded
/// range — TorBox CDN nodes have been caught answering bounded ranges and
/// headers instantly while starving the open-ended request the media pipeline
/// makes, so a probe that asks a different question than the player blesses
/// exactly the links that stall it. Once the mark is proven the connection is
/// torn down; the CDN is never left streaming a whole file into a cancelled
/// reader. An error status is a dead link with a name (an expired token 403s),
/// and a body that goes quiet inside the deadline is the failure this whole
/// module exists for.
Future<ProbeVerdict> probeStream(
  String? url, {
  StreamingTransport? transport,
  int timeoutMs = probeTimeoutMs,
  int minBytes = probeBytes,
}) {
  final started = Stopwatch()..start();
  int elapsed() => started.elapsedMilliseconds;
  if (transport == null || url == null || url.isEmpty) {
    return Future.value(
      const ProbeVerdict(
        alive: false,
        reason: 'nothing to probe with',
        elapsedMs: 0,
      ),
    );
  }

  final done = Completer<ProbeVerdict>();
  StreamedResponse? response;
  StreamSubscription<List<int>>? subscription;
  var received = 0;
  var timedOut = false;

  void finish(ProbeVerdict verdict) {
    if (!done.isCompleted) done.complete(verdict);
  }

  String timeoutReason() => received > 0
      ? 'the stream stopped after $received bytes and went quiet for the rest '
            'of ${(timeoutMs / 1000).round()}s'
      : 'the stream host did not answer within ${(timeoutMs / 1000).round()}s';

  final deadline = Timer(Duration(milliseconds: timeoutMs), () {
    timedOut = true;
    finish(
      ProbeVerdict(
        alive: false,
        received: received,
        reason: timeoutReason(),
        elapsedMs: elapsed(),
      ),
    );
  });

  Future<void>(() async {
    final opened = await transport.open(
      HttpRequest(
        HttpMethod.get,
        Uri.parse(url),
        headers: const {
          // the player asks open-ended: sick nodes serve bounded ranges instantly
          // while starving exactly this request, so any other question blesses
          // dead links
          'range': 'bytes=0-',
          // a cached answer would prove nothing about the host
          'cache-control': 'no-store',
        },
        timeout: Duration(milliseconds: timeoutMs),
      ),
    );
    response = opened;
    if (!opened.ok) {
      finish(
        ProbeVerdict(
          alive: false,
          status: opened.status,
          reason: 'the stream host answered ${opened.status}',
          elapsedMs: elapsed(),
        ),
      );
      return;
    }
    if (minBytes <= 0) {
      finish(
        ProbeVerdict(alive: true, status: opened.status, elapsedMs: elapsed()),
      );
      return;
    }
    // the body is the point: read it until the mark is proven
    subscription = opened.body.listen(
      (chunk) {
        received += chunk.length;
        if (received >= minBytes) {
          finish(
            ProbeVerdict(
              alive: true,
              status: opened.status,
              elapsedMs: elapsed(),
              received: received,
            ),
          );
        }
      },
      onDone: () {
        // a body shorter than the mark that properly ENDED is delivery (a tiny
        // file); only one that goes quiet without ending is starvation — and
        // that path arrives as the deadline above, not as a short read
        if (received == 0) {
          finish(
            ProbeVerdict(
              alive: false,
              status: opened.status,
              reason: 'the stream host sent headers but no data',
              elapsedMs: elapsed(),
            ),
          );
        } else {
          finish(
            ProbeVerdict(
              alive: true,
              status: opened.status,
              elapsedMs: elapsed(),
              received: received,
            ),
          );
        }
      },
      onError: (Object error) {
        finish(
          ProbeVerdict(
            alive: false,
            received: received,
            reason: timedOut
                ? timeoutReason()
                : 'the stream host was unreachable ($error)',
            elapsedMs: elapsed(),
          ),
        );
      },
      cancelOnError: true,
    );
  }).catchError((Object error) {
    finish(
      ProbeVerdict(
        alive: false,
        received: received,
        reason: timedOut
            ? timeoutReason()
            : 'the stream host was unreachable ($error)',
        elapsedMs: elapsed(),
      ),
    );
  });

  return done.future.whenComplete(() {
    deadline.cancel();
    // NEVER await these, and never await anything between the verdict and this
    // teardown. The reasoning that keeps producing the opposite ("finish
    // releasing the range before the player opens its own") is seductive and
    // wrong, and it cost two separate outages: a mock body lets go instantly
    // where an open-ended range against a real CDN need not. The request is
    // open-ended by design; whatever happened above, the connection dies here.
    unawaited(subscription?.cancel());
    response?.cancel();
  });
}

/// The full verdict on a link: one probe, and on failure one more after a short
/// pause, because a single flap is not worth abandoning a debrid stream over.
/// Both misses make it a dead link.
Future<ProbeVerdict> verifiedStream(
  String? url, {
  StreamingTransport? transport,
  int timeoutMs = probeTimeoutMs,
  int retryDelayMs = probeRetryDelayMs,
  Future<void> Function(int ms)? sleep,
}) async {
  final wait =
      sleep ?? (ms) => Future<void>.delayed(Duration(milliseconds: ms));
  final first = await probeStream(
    url,
    transport: transport,
    timeoutMs: timeoutMs,
  );
  if (first.alive) return first.withAttempts(1);
  await wait(retryDelayMs);
  final second = await probeStream(
    url,
    transport: transport,
    timeoutMs: timeoutMs,
  );
  return second.withAttempts(2);
}
