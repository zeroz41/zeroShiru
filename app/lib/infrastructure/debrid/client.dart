/// The request machinery every provider shares: rate limiting, retries,
/// authentication schemes, body encoding, latency-stretched poll budgets,
/// availability memory and the account listing cache.
/// Port of crates/debrid/src/client.rs.
library;

import 'dart:convert';

import '../../domain/models/availability.dart';
import '../../domain/ports/debrid_client.dart';
import '../network/transport.dart' as net;
import 'errors.dart';
import 'hash.dart';
import 'limiter.dart';
import 'providers/provider.dart';

/// How far a poll budget may stretch on a slow link.
const double _maxStretch = 3.0;

/// How many times a removal this client owes the account is retried before it
/// is written off.
const int _maxCleanupAttempts = 3;

/// How many times a request refused for going too fast is sent again.
const int _rateLimitRetries = 2;

/// How long to wait out a `429` that arrived without a `retry-after` header.
const int _rateLimitFallbackMs = 5000;

/// How long one unanswered round trip keeps the whole account treated as
/// quiet. TorBox wedges per endpoint — connections accepted and never
/// answered, for minutes, while curl proves the server up. One full-budget
/// timeout has already been paid; while it is fresh, later requests only
/// probe whether the service came back.
const int quietCooldownMs = 30000;

/// The round-trip budget while the service is quiet. Stretched by the measured
/// link latency like every other budget, so a slow connection is not mistaken
/// for a quiet service.
const int quietProbeMs = 3000;

/// The longest `retry-after` worth obeying. TorBox has answered a link burst
/// with `retry-after: 300`, and honouring it froze playback for five minutes.
const int _rateLimitMaxWaitMs = 30000;

/// How long to leave a request that timed out before trying it once more.
const int _networkRetryDelayMs = 3000;

/// How long the account listing is reused.
const int listingTtlMs = 60000;

extension ClockMs on net.Clock {
  int get nowMs => now().millisecondsSinceEpoch;
  Future<void> sleepMs(int ms) => sleep(Duration(milliseconds: ms));
}

/// Per-request overrides, mirroring the JS request options object.
class RequestOpts {
  const RequestOpts({
    this.method,
    this.body,
    this.encoding,
    this.auth,
    this.authParam,
    this.timeoutMs,
  });

  final net.HttpMethod? method;

  /// Key/value body fields; a List value becomes the same key repeated.
  final List<(String, Object?)>? body;
  final BodyEncoding? encoding;
  final AuthScheme? auth;
  final String? authParam;
  final int? timeoutMs;
}

/// A diagnostic view of one debrid client.
class ClientHealth {
  const ClientHealth({
    required this.quiet,
    required this.unansweredTimeouts,
    required this.latencyMs,
    required this.rememberedAnswers,
    required this.orphanedRemovals,
    required this.limiter,
  });

  final bool quiet;
  final int unansweredTimeouts;
  final int latencyMs;
  final int rememberedAnswers;
  final int orphanedRemovals;
  final LimiterHealth limiter;
}

/// A provider's response conventions: how envelopes unwrap and errors map.
abstract class Dialect {
  const Dialect();

  /// Unpacks a successful response body. Providers whose APIs report failures
  /// inside a 200 throw a [DebridFailure] from here.
  Object? unwrap(Object? json) => json;

  /// Maps an HTTP error response to a typed error.
  DebridFailure mapError(int status, Object? json) {
    String? message;
    String? code;
    if (json is Map) {
      final raw = json['error'] ?? json['message'];
      if (raw is String) message = raw;
      final rawCode = json['error_code'];
      if (rawCode != null) code = rawCode.toString();
    }
    message ??= 'Request failed with status $status';
    if (status == 401 || status == 403) {
      return DebridFailure.auth(message, status: status, code: code);
    }
    return DebridFailure.service(message, status: status, code: code);
  }
}

/// Default dialect: plain JSON bodies, standard status-code mapping.
class PlainDialect extends Dialect {
  const PlainDialect();
}

class _AttemptFailure implements Exception {
  const _AttemptFailure(this.error, this.retryAfterSeconds);

  final DebridFailure error;
  final int? retryAfterSeconds;
}

/// The stateful per-account client every provider is built on.
class DebridApiClient {
  DebridApiClient(this.config, this._apiKey, this._transport, this.clock)
    : limiter = Limiter(
        Limits(
          maxConcurrent: config.maxConcurrent,
          minTimeMs: config.minTimeMs,
          reservoir: config.reservoir,
        ),
      );

  final ProviderConfig config;
  final String _apiKey;
  final net.HttpTransport _transport;
  final net.Clock clock;
  final Limiter limiter;

  /// Rolling estimate of one round trip, 0 until the first answer.
  int _latencyMs = 0;

  /// Round trips in a row that never came back, and when the last gave up.
  int _quietTimeouts = 0;
  int _quietAtMs = 0;

  /// What the service has already said about a hash, with when it said it.
  final Map<String, (Availability, int)> _availability = {};

  /// The real release name behind a hash, as the service knows it.
  final Map<String, String> _releaseNames = {};

  /// Removals that failed, to try again. Keyed by the whole request, since
  /// services that name the torrent in the body would collide on one url.
  final Map<String, (String, RequestOpts, int)> _orphans = {};

  /// The account's own torrent listing behind an async mutex, so a second
  /// caller arriving mid-read waits for that read instead of starting another.
  (int, Object?)? _listing;
  Future<void> _listingTail = Future.value();

  /// Applies the service's authentication scheme.
  (String, Map<String, String>) _authorize(
    String url,
    AuthScheme auth,
    String authParam,
  ) {
    switch (auth) {
      case AuthScheme.bearer:
        return (url, {'Authorization': 'Bearer $_apiKey'});
      case AuthScheme.query:
        final separator = url.contains('?') ? '&' : '?';
        return ('$url$separator$authParam=$_apiKey', const {});
    }
  }

  /// Encodes a request body. A List value becomes the same key repeated.
  static net.HttpBody encodeBody(
    List<(String, Object?)> fields,
    BodyEncoding encoding,
  ) {
    switch (encoding) {
      case BodyEncoding.json:
        final map = <String, Object?>{
          for (final (key, value) in fields) key: value,
        };
        return net.BytesBody(
          utf8.encode(jsonEncode(map)),
          contentType: 'application/json',
        );
      case BodyEncoding.multipart:
        final flat = _flatten(fields);
        return net.MultipartBody({for (final (key, value) in flat) key: value});
      case BodyEncoding.form:
        return net.FormBody(_flatten(fields));
    }
  }

  static List<(String, String)> _flatten(List<(String, Object?)> fields) {
    final flat = <(String, String)>[];
    for (final (key, value) in fields) {
      if (value is List) {
        for (final item in value) {
          flat.add((key, _scalar(item)));
        }
      } else {
        flat.add((key, _scalar(value)));
      }
    }
    return flat;
  }

  static String _scalar(Object? value) =>
      value is String ? value : jsonEncode(value);

  /// One authenticated request, paced against the service's allowance and
  /// retried only where retrying is what the service asked for:
  /// - 429: up to two more tries, honouring retry-after (default 5s) but
  ///   refusing to wait past 30s; the pause applies to the whole account.
  /// - Timeout: exactly one more attempt after 3s — unless the service was
  ///   already known-quiet at entry.
  /// - Everything else (auth, 5xx, unreachable): no retry.
  Future<Object?> request(
    Dialect dialect,
    String url,
    RequestOpts opts, {
    CancelToken? cancel,
  }) async {
    if (_apiKey.isEmpty) {
      throw const DebridFailure.auth('No debrid API key configured');
    }
    var rateLimited = 0;
    var timedOut = 0;
    // whether the service was already known-quiet before this call spent
    // anything: a timeout then is confirmation rather than news
    final quietAtEntry = quiet;
    while (true) {
      _AttemptFailure failure;
      // the permit lives exactly as long as the round trip, so a request that
      // failed hands its place back before anything waits on the retry
      final permit = await limiter.acquire(clock, cancel: cancel);
      try {
        return await _attempt(dialect, url, opts, cancel);
      } on _AttemptFailure catch (caught) {
        failure = caught;
      } finally {
        permit.release();
      }
      final error = failure.error;
      if (error.throttled && rateLimited < _rateLimitRetries) {
        final wait = failure.retryAfterSeconds != null
            ? failure.retryAfterSeconds! * 1000
            : _rateLimitFallbackMs;
        if (wait > _rateLimitMaxWaitMs) throw error;
        limiter.pauseFor(clock, wait);
        await raced(clock.sleepMs(wait), cancel);
        rateLimited += 1;
        continue;
      }
      if (error.kind == DebridErrorKind.timeout &&
          timedOut < 1 &&
          !quietAtEntry) {
        await raced(clock.sleepMs(_networkRetryDelayMs), cancel);
        timedOut += 1;
        continue;
      }
      throw error;
    }
  }

  /// One authenticated round trip, with the provider's error conventions
  /// applied. Failures carry the retry-after alongside, because only the loop
  /// above knows whether this request has retries left to spend.
  Future<Object?> _attempt(
    Dialect dialect,
    String url,
    RequestOpts opts,
    CancelToken? cancel,
  ) async {
    final auth = opts.auth ?? config.auth;
    final authParam = opts.authParam ?? config.authParam;
    final (authorizedUrl, headers) = _authorize(url, auth, authParam);
    final body = opts.body == null
        ? null
        : encodeBody(opts.body!, opts.encoding ?? config.encoding);
    var timeoutMs = opts.timeoutMs ?? config.timeouts.requestMs;
    // while the service is quiet the full budget has already been paid once;
    // this round trip only asks whether it came back
    if (quiet) {
      final probe = budget(quietProbeMs);
      if (probe < timeoutMs) timeoutMs = probe;
    }
    final request = net.HttpRequest(
      opts.method ?? net.HttpMethod.get,
      Uri.parse(authorizedUrl),
      headers: headers,
      body: body,
      timeout: Duration(milliseconds: timeoutMs),
    );
    final sent = clock.nowMs;
    final net.HttpResponse response;
    try {
      response = await raced(_transport.send(request), cancel);
    } on net.TimeoutException catch (error) {
      // an unanswered round trip is the evidence the quiet state runs on
      _quietTimeouts += 1;
      _quietAtMs = clock.nowMs;
      throw _AttemptFailure(
        DebridFailure.timeout(
          'request timed out after ${error.elapsed.inMilliseconds}ms',
        ),
        null,
      );
    } on net.NetworkException catch (error) {
      throw _AttemptFailure(DebridFailure.network(error.message), null);
    }
    // only round trips that came back, so a timeout cannot inflate it
    observeLatency(clock.nowMs - sent);
    // any answer at all — even an error status — is the service talking again
    _quietTimeouts = 0;
    return _finish(dialect, response);
  }

  Object? _finish(Dialect dialect, net.HttpResponse response) {
    if (!response.ok) {
      Object? json;
      try {
        json = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        json = null;
      }
      final error = dialect.mapError(response.status, json);
      // a retry-after in seconds; anything else reads as absent
      int? retryAfter;
      if (response.status == 429) {
        retryAfter = int.tryParse(response.header('retry-after')?.trim() ?? '');
      }
      throw _AttemptFailure(error, retryAfter);
    }
    if (response.status == 204 || response.bodyBytes.isEmpty) return null;
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      json = null;
    }
    try {
      return dialect.unwrap(json);
    } on DebridFailure catch (error) {
      throw _AttemptFailure(error, null);
    }
  }

  /// The account's own torrent listing, read at most once per TTL and shared
  /// by every caller. `fresh` forces a read, for polling a change just made.
  /// A failed read is never remembered.
  Future<Object?> listing(bool fresh, Future<Object?> Function() fetch) async {
    final previous = _listingTail;
    Object? result;
    Object? failure;
    StackTrace? failureStack;
    final work = () async {
      await previous;
      if (!fresh) {
        final known = _listing;
        if (known != null && clock.nowMs - known.$1 < listingTtlMs) {
          return known.$2;
        }
      }
      final read = await fetch();
      _listing = (clock.nowMs, read);
      return read;
    }();
    _listingTail = work.then(
      (value) {
        result = value;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
      },
    );
    await _listingTail;
    if (failure != null) {
      return Future.error(failure!, failureStack);
    }
    return result;
  }

  /// Drops the remembered listing, because the account just changed.
  void forgetListing() {
    _listing = null;
  }

  /// Replaces or appends one entry in the remembered listing, for when the
  /// account changed by exactly that entry. `same` says whether two entries
  /// describe the same torrent.
  void amendListing(Object? entry, bool Function(Object?, Object?) same) {
    final known = _listing;
    if (known == null) return;
    final items = known.$2;
    if (items is List) {
      final index = items.indexWhere((item) => same(item, entry));
      if (index >= 0) {
        items[index] = entry;
      } else {
        items.add(entry);
      }
    }
  }

  /// Undoes something this client created on the account. Never fails: it
  /// runs from error paths, where it would mask the real failure. A removal
  /// that fails is remembered and retried; 404 counts as gone.
  Future<void> release(Dialect dialect, String url, RequestOpts opts) async {
    final key = _requestKey(url, opts);
    var gone = false;
    try {
      await request(dialect, url, opts);
      gone = true;
    } on DebridFailure catch (error) {
      gone = error.status == 404;
    } on CancelledException {
      // the caller moved on mid-delete; the removal is still owed
    } catch (_) {}
    if (gone) {
      _orphans.remove(key);
      return;
    }
    final attempts = (_orphans[key]?.$3 ?? 0) + 1;
    if (attempts < _maxCleanupAttempts) {
      _orphans[key] = (url, opts, attempts);
    } else {
      // a service that will not take the removal is not worth asking forever
      _orphans.remove(key);
    }
  }

  /// Identifies one removal: two different torrents must never look like the
  /// same outstanding removal.
  static String _requestKey(String url, RequestOpts opts) {
    final body = opts.body;
    if (body == null) return url;
    return '$url|${jsonEncode([
      for (final (key, value) in body) [key, value],
    ])}';
  }

  /// How many removals are still outstanding.
  int get orphaned => _orphans.length;

  /// Whether the service is quiet right now: a round trip recently spent its
  /// whole budget without an answer, and nothing has answered since.
  bool get quiet =>
      _quietTimeouts > 0 && clock.nowMs - _quietAtMs < quietCooldownMs;

  /// Everything worth knowing about this client's health in one read.
  ClientHealth get health => ClientHealth(
    quiet: quiet,
    unansweredTimeouts: _quietTimeouts,
    latencyMs: _latencyMs,
    rememberedAnswers: _availability.length,
    orphanedRemovals: orphaned,
    limiter: limiter.snapshot(clock),
  );

  /// Records a removal the account is owed without sending it, for cleanup
  /// paths that cannot make a request (a cancelled call speaks from here).
  void noteOrphan(String url, RequestOpts opts) {
    _orphans[_requestKey(url, opts)] = (url, opts, 0);
  }

  /// Retries removals that failed earlier. Never persisted: a stale id would
  /// eventually name something else.
  Future<void> retryCleanup(Dialect dialect) async {
    final pending = [for (final (url, opts, _) in _orphans.values) (url, opts)];
    for (final (url, opts) in pending) {
      await release(dialect, url, opts);
    }
  }

  /// Folds one round trip into the latency estimate, weighted recent.
  void observeLatency(int ms) {
    _latencyMs = _latencyMs == 0 ? ms : (_latencyMs * 7 + ms * 3) ~/ 10;
  }

  int get latencyMs => _latencyMs;

  /// A poll budget stretched to fit the connection in use, up to 3x.
  int budget(int baseMs) {
    final stretch = (_latencyMs / config.nominalLatencyMs).clamp(
      1.0,
      _maxStretch,
    );
    return (baseMs * stretch).round();
  }

  /// Records what is known about a release so later checks are free. Unknown
  /// is not an answer, so recording it forgets what was there.
  void remember(String magnetOrHash, Availability state) {
    final hash = parseHash(magnetOrHash);
    if (hash == null) return;
    if (state == Availability.unknown) {
      _availability.remove(hash);
    } else {
      _availability[hash] = (state, clock.nowMs);
    }
  }

  /// A remembered answer that has not expired, or `null` when the hash needs
  /// asking about.
  Availability? recall(String hash) {
    final known = _availability[hash];
    if (known == null) return null;
    final (state, at) = known;
    if (clock.nowMs - at < state.ttl.inMilliseconds) return state;
    _availability.remove(hash); // stale, ask again
    return null;
  }

  /// Records the real name of a release, whenever the service mentions one.
  void rememberRelease(String magnetOrHash, String name) {
    if (name.isEmpty) return;
    final hash = parseHash(magnetOrHash);
    if (hash != null) _releaseNames[hash] = name;
  }

  /// Every release name the service has mentioned so far, keyed by info hash.
  Map<String, String> get releaseNames => Map.of(_releaseNames);

  /// The service's own name for a release, or `null`.
  String? releaseName(String magnetOrHash) {
    final hash = parseHash(magnetOrHash);
    return hash == null ? null : _releaseNames[hash];
  }

  /// Lowercase, deduplicated hashes, order preserved, stopping at [limit].
  static List<String> normalizeHashes(List<String> magnetsOrHashes, int limit) {
    final seen = <String>{};
    final hashes = <String>[];
    for (final entry in magnetsOrHashes) {
      final hash = parseHash(entry);
      if (hash != null && seen.add(hash)) {
        hashes.add(hash);
        if (hashes.length >= limit) break;
      }
    }
    return hashes;
  }
}

/// Arms removals that fire only if the surrounding call dies without
/// disarming them. Rust armed this on `Drop`; here a [CancelledException]
/// unwinding through the provider's `catch` calls [settle], which owes each
/// removal to the client's orphan list for the next cleanup sweep.
class OrphanGuard {
  OrphanGuard(this._client);

  final DebridApiClient _client;
  final List<(String, RequestOpts)> _requests = [];

  /// Arms the guard with a request that would undo something just created.
  void arm(String url, RequestOpts opts) => _requests.add((url, opts));

  /// Stands the guard down: the caller takes responsibility another way.
  void disarm() => _requests.clear();

  /// The call died still armed: every removal is now owed.
  void settle() {
    for (final (url, opts) in _requests) {
      _client.noteOrphan(url, opts);
    }
    _requests.clear();
  }
}

/// Turns candidates into stream links, skipping ones the service cannot serve
/// — packs do contain dead files. Auth failures abort, since every other link
/// would fail the same way. Concurrent, in order: the first candidate takes
/// the first limiter ticket.
Future<List<DebridFileInfo>> mapFiles<T>(
  List<T> candidates,
  Future<DebridFileInfo?> Function(T) toFile,
) async {
  final outcomes = List<Object?>.filled(candidates.length, null);
  final work = <Future<void>>[];
  for (var index = 0; index < candidates.length; index++) {
    final slot = index;
    final candidate = candidates[index];
    // started in order, so the first candidate is first into the limiter
    work.add(() async {
      try {
        outcomes[slot] = await toFile(candidate);
      } catch (error) {
        outcomes[slot] = _MapFailure(error);
      }
    }());
  }
  await Future.wait(work);
  final files = <DebridFileInfo>[];
  for (final outcome in outcomes) {
    if (outcome is DebridFileInfo) {
      files.add(outcome);
    } else if (outcome is _MapFailure) {
      final error = outcome.error;
      if (error is CancelledException) throw error;
      if (error is DebridFailure && error.kind == DebridErrorKind.auth) {
        throw error;
      }
      // skipping a file the service would not link
    }
  }
  return files;
}

class _MapFailure {
  const _MapFailure(this.error);

  final Object error;
}
