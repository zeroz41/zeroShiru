/// Which destinations page/extension content may ask this host to fetch on
/// its behalf. A native HTTP client can reach anything the machine can —
/// the router's admin page, a cloud metadata service, something listening
/// only on loopback — so this guard stands where a browser's same-origin
/// rules would have: only public http(s) destinations, re-checked on every
/// redirect hop, because a redirect is a destination the caller never named.
///
/// Ported exactly from crates/networking/src/guard.rs and the redirect
/// policy in hosts/tauri/src/net.rs (redo branch).
library;

import 'dart:io';
import 'dart:typed_data';

import '../../domain/ports/http_transport.dart';

/// Why a URL was refused.
enum Blocked {
  /// Only http and https URLs may be fetched.
  scheme,

  /// The URL has no host.
  noHost,

  /// Private, local and link-local addresses may not be fetched.
  private,

  /// Only publicly resolvable names may be fetched.
  notPublicName;

  String describe() => switch (this) {
    Blocked.scheme => 'only http and https URLs may be fetched',
    Blocked.noHost => 'the URL has no host',
    Blocked.private =>
      'private, local and link-local addresses may not be fetched',
    Blocked.notPublicName => 'only publicly resolvable names may be fetched',
  };
}

/// Suffixes that never name something on the public internet.
const List<String> localSuffixes = [
  '.local',
  '.localhost',
  '.internal',
  '.home.arpa',
  '.onion',
];

/// Checks a URL's scheme and host. Returns null when the URL may be fetched.
/// A host given as an IP literal is checked directly; a name is checked for
/// shape only — what it resolves to is the resolver's business, which asks
/// [isPublicAddress] about what came back.
Blocked? checkUrl(String url) {
  final schemeEnd = url.indexOf('://');
  if (schemeEnd < 0) return Blocked.scheme;
  final scheme = url.substring(0, schemeEnd).toLowerCase();
  if (scheme != 'http' && scheme != 'https') return Blocked.scheme;
  final host = _hostOf(url.substring(schemeEnd + 3));
  if (host == null) return Blocked.noHost;
  return _checkHost(host);
}

/// The host part of everything after `scheme://`, without userinfo, port or
/// path. `[::1]:8080` -> `::1`.
String? _hostOf(String rest) {
  final authorityWithUserinfo = rest.split(RegExp('[/?#]')).first;
  // user:password@host — the last '@' wins, so a userinfo containing one
  // cannot smuggle a host past the check.
  final authority = authorityWithUserinfo.split('@').last;
  if (authority.startsWith('[')) {
    final end = authority.indexOf(']');
    if (end > 0) return authority.substring(1, end);
  }
  final host = authority.split(':').first;
  return host.isEmpty ? null : host;
}

Blocked? _checkHost(String rawHost) {
  var host = rawHost.toLowerCase();
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (host.isEmpty) return Blocked.noHost;
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    return isPublicAddress(address) ? null : Blocked.private;
  }
  if (host == 'localhost' ||
      localSuffixes.any((suffix) => host.endsWith(suffix))) {
    return Blocked.private;
  }
  // A name with no dot is a machine on this network, not a site.
  if (!host.contains('.')) return Blocked.notPublicName;
  return null;
}

/// Whether an address is out on the public internet, as opposed to this
/// machine, this network, or somewhere the IP stack treats specially. The
/// resolver asks this about every address a name resolved to — which is how
/// a public name pointed at something local gets caught.
bool isPublicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  return address.type == InternetAddressType.IPv4
      ? _isPublicV4(bytes)
      : _isPublicV6(bytes);
}

bool _isPublicV4(Uint8List octets) {
  final a = octets[0], b = octets[1];
  return !(a ==
          127 // loopback
          ||
      a ==
          10 // private
          ||
      (a == 172 && b >= 16 && b < 32) // private
      ||
      (a == 192 && b == 168) // private
      ||
      (a == 169 && b == 254) // link-local
      ||
      (a == 198 && b == 51 && octets[2] == 100) // documentation
      ||
      (a == 203 && b == 0 && octets[2] == 113) // documentation
      ||
      (a >= 224 && a < 240) // multicast
      ||
      a ==
          0 // unspecified and 0.0.0.0/8
          ||
      (a == 100 && b >= 64 && b < 128) // carrier-grade NAT
      ||
      (a == 192 && b == 0) // IETF protocol assignments (incl. 192.0.2/24 docs)
      ||
      (a == 198 && (b == 18 || b == 19)) // benchmarking
      ||
      a >= 240); // reserved, includes 255.255.255.255 broadcast
}

bool _isPublicV6(Uint8List bytes) {
  // An IPv4 written as IPv6 (::ffff:a.b.c.d) is still that address.
  var mapped = bytes[10] == 0xff && bytes[11] == 0xff;
  for (var i = 0; i < 10 && mapped; i++) {
    if (bytes[i] != 0) mapped = false;
  }
  if (mapped) return _isPublicV4(bytes.sublist(12));

  int segment(int index) => (bytes[2 * index] << 8) | bytes[2 * index + 1];
  var allZero = true;
  for (var i = 0; i < 15; i++) {
    if (bytes[i] != 0) allZero = false;
  }
  final loopback = allZero && bytes[15] == 1;
  final unspecified = allZero && bytes[15] == 0;
  final first = segment(0);
  return !(loopback ||
      unspecified ||
      bytes[0] ==
          0xff // multicast
          ||
      (first & 0xfe00) ==
          0xfc00 // unique local
          ||
      (first & 0xffc0) ==
          0xfe80 // link-local
          ||
      first ==
          0x0100 // discard-only
          ||
      (first == 0x2001 && segment(1) == 0x0db8)); // documentation
}

/// Thrown by [GuardedHttpTransport] when a destination — the one asked for,
/// or one a redirect chose — is refused.
class UrlBlockedException implements Exception {
  const UrlBlockedException(this.reason, this.url, {this.redirected = false});

  final Blocked reason;
  final String url;

  /// True when the refused destination came from a redirect hop, not the
  /// caller.
  final bool redirected;

  @override
  String toString() => redirected
      ? 'redirected somewhere unreachable: ${reason.describe()} ($url)'
      : '${reason.describe()} ($url)';
}

/// The SSRF-guarded transport decorator, ported from hosts/tauri/src/net.rs.
///
/// Every destination is checked against the guard — the original URL and
/// each redirect hop, since a public URL that bounces to `127.0.0.1` is the
/// ordinary way this kind of surface gets abused. Redirects are followed
/// manually (the inner transport must not follow them itself; see
/// PackageHttpTransport) up to [maxRedirects] hops. Bodies past
/// [maxBodyBytes] are refused rather than held in memory. Headers the
/// transport owns are stripped: a caller setting those breaks the
/// connection, not the rules. The method allowlist (GET/POST/PUT/DELETE/
/// PATCH/HEAD) is the [HttpMethod] enum itself — nothing else is
/// representable.
class GuardedHttpTransport implements HttpTransport {
  const GuardedHttpTransport(
    this._inner, {
    this.maxRedirects = 8,
    this.maxBodyBytes = 8 * 1024 * 1024,
  });

  final HttpTransport _inner;
  final int maxRedirects;
  final int maxBodyBytes;

  /// Headers the transport owns; a caller's copies are dropped.
  static const strippedHeaders = {
    'host',
    'content-length',
    'connection',
    'transfer-encoding',
    'upgrade',
  };

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    var headers = {
      for (final entry in request.headers.entries)
        if (!strippedHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };

    var url = request.url;
    var method = request.method;
    var body = request.body;
    var hops = 0;

    while (true) {
      final blocked = checkUrl(url.toString());
      if (blocked != null) {
        throw UrlBlockedException(
          blocked,
          url.toString(),
          redirected: hops > 0,
        );
      }

      final response = await _inner.send(
        HttpRequest(
          method,
          url,
          headers: headers,
          body: body,
          timeout: request.timeout,
        ),
      );

      final location = response.header('location');
      if (_isRedirect(response.status) && location != null) {
        hops++;
        if (hops > maxRedirects) {
          throw const NetworkException('too many redirects');
        }
        final previous = url;
        url = url.resolve(location);
        if (!_sameOrigin(previous, url)) {
          headers = Map<String, String>.of(headers)
            ..removeWhere(
              (name, _) => const {
                'authorization',
                'proxy-authorization',
                'cookie',
              }.contains(name.toLowerCase()),
            );
        }
        // A 303 answers "see other" — and historically 301/302 after a POST
        // are refetched as GET. 307/308 keep the method and body.
        if (response.status == 303 ||
            ((response.status == 301 || response.status == 302) &&
                method == HttpMethod.post)) {
          method = HttpMethod.get;
          body = null;
        }
        continue;
      }

      _checkBodySize(response);
      return response;
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  void _checkBodySize(HttpResponse response) {
    final declared = int.tryParse(response.header('content-length') ?? '');
    final size = response.bodyBytes.length;
    if ((declared ?? 0) > maxBodyBytes || size > maxBodyBytes) {
      throw NetworkException(
        'response is larger than the ${maxBodyBytes ~/ (1024 * 1024)}MB limit',
      );
    }
  }
}
