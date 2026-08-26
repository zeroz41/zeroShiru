// ignore_for_file: prefer_initializing_formals

/// Token models + storage for the AniList / MyAnimeList providers.
///
/// Ported from the redo branch's `modules/settings.js`:
/// - AniList is implicit-grant, no refresh. Expiry is set to now + 335 days
///   (about a month before AniList's ~12 month token life). Past expiry the
///   token is flagged `reauth` ("Login Expiring"); past expiry + 30 days it is
///   hard-expired ("Login Expired") and must not be attached to requests.
/// - MAL is OAuth2 PKCE (plain verifier). The refresh token is rotated every
///   14 days (`refreshAt = now + 14d`), well inside MAL's ~31 day window.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../domain/ports/ports.dart';
import '../../domain/ports/http_transport.dart';

/// Soft lifetime of a freshly issued AniList token.
const aniListTokenLifetime = Duration(days: 335);

/// Grace period after [aniListTokenLifetime] before the token is treated as
/// truly dead.
const aniListHardExpiryGrace = Duration(days: 30);

/// How long a MAL access/refresh pair is used before proactively refreshing.
const malRefreshWindow = Duration(days: 14);

enum TokenHealth {
  /// Fine, keep using it.
  valid,

  /// Past the soft expiry — still attached to requests, but the user should
  /// be nudged to reauthenticate ("Login Expiring").
  expiring,

  /// Past hard expiry (or flagged reauth) — never attach to requests.
  expired,
}

/// AniList implicit-grant token (old `localStorage['ALviewer']`).
class AniListToken {
  const AniListToken({
    required this.token,
    required this.expiresAt,
    this.reauth = false,
    this.viewerId,
    this.viewerName,
    this.viewerAvatar,
  });

  /// Issue a token pasted/received right now: soft expiry now + 335 days.
  factory AniListToken.issue(
    String token, {
    required DateTime now,
    int? viewerId,
    String? viewerName,
    String? viewerAvatar,
  }) {
    return AniListToken(
      token: token,
      expiresAt: now.add(aniListTokenLifetime),
      viewerId: viewerId,
      viewerName: viewerName,
      viewerAvatar: viewerAvatar,
    );
  }

  factory AniListToken.fromJson(Map<String, dynamic> json) => AniListToken(
    token: json['token'] as String,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      (json['expiresAt'] as num).toInt(),
    ),
    reauth: json['reauth'] as bool? ?? false,
    viewerId: (json['viewerId'] as num?)?.toInt(),
    viewerName: json['viewerName'] as String?,
    viewerAvatar: json['viewerAvatar'] as String?,
  );

  final String token;
  final DateTime expiresAt;
  final bool reauth;
  final int? viewerId;
  final String? viewerName;
  final String? viewerAvatar;

  DateTime get hardExpiresAt => expiresAt.add(aniListHardExpiryGrace);

  /// Time-based health. `reauth` is only the "already nudged" marker — the
  /// old client kept attaching a reauth-flagged token until hard expiry
  /// (soft expiry + 30 days), and so do we.
  TokenHealth health(DateTime now) {
    if (!now.isBefore(hardExpiresAt)) return TokenHealth.expired;
    if (reauth || !now.isBefore(expiresAt)) return TokenHealth.expiring;
    return TokenHealth.valid;
  }

  /// Whether this token may still be attached to requests.
  bool usable(DateTime now) => health(now) != TokenHealth.expired;

  AniListToken withReauth() => AniListToken(
    token: token,
    expiresAt: expiresAt,
    reauth: true,
    viewerId: viewerId,
    viewerName: viewerName,
    viewerAvatar: viewerAvatar,
  );

  Map<String, dynamic> toJson() => {
    'token': token,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'reauth': reauth,
    if (viewerId != null) 'viewerId': viewerId,
    if (viewerName != null) 'viewerName': viewerName,
    if (viewerAvatar != null) 'viewerAvatar': viewerAvatar,
  };
}

/// MAL token + refresh pair (old `localStorage['MALviewer']`).
class MalToken {
  const MalToken({
    required this.token,
    required this.refresh,
    required this.refreshAt,
    this.reauth = false,
    this.viewerId,
    this.viewerName,
    this.viewerPicture,
  });

  /// A pair obtained from the token endpoint right now: refresh in 14 days.
  factory MalToken.issue(
    String accessToken,
    String refreshToken, {
    required DateTime now,
    int? viewerId,
    String? viewerName,
    String? viewerPicture,
  }) {
    return MalToken(
      token: accessToken,
      refresh: refreshToken,
      refreshAt: now.add(malRefreshWindow),
      viewerId: viewerId,
      viewerName: viewerName,
      viewerPicture: viewerPicture,
    );
  }

  factory MalToken.fromJson(Map<String, dynamic> json) => MalToken(
    token: json['token'] as String,
    refresh: json['refresh'] as String,
    refreshAt: DateTime.fromMillisecondsSinceEpoch(
      (json['refreshAt'] as num).toInt(),
    ),
    reauth: json['reauth'] as bool? ?? false,
    viewerId: (json['viewerId'] as num?)?.toInt(),
    viewerName: json['viewerName'] as String?,
    viewerPicture: json['viewerPicture'] as String?,
  );

  final String token;
  final String refresh;
  final DateTime refreshAt;
  final bool reauth;
  final int? viewerId;
  final String? viewerName;
  final String? viewerPicture;

  bool needsRefresh(DateTime now) => !now.isBefore(refreshAt);

  MalToken withReauth() => MalToken(
    token: token,
    refresh: refresh,
    refreshAt: refreshAt,
    reauth: true,
    viewerId: viewerId,
    viewerName: viewerName,
    viewerPicture: viewerPicture,
  );

  Map<String, dynamic> toJson() => {
    'token': token,
    'refresh': refresh,
    'refreshAt': refreshAt.millisecondsSinceEpoch,
    'reauth': reauth,
    if (viewerId != null) 'viewerId': viewerId,
    if (viewerName != null) 'viewerName': viewerName,
    if (viewerPicture != null) 'viewerPicture': viewerPicture,
  };
}

/// Parses a pasted AniList redirect URL / fragment. The old app listened for
/// a global paste of `…#access_token=<tok>&token_type=Bearer…`.
///
/// Returns the token, or null when the text does not carry one.
String? parseAniListRedirect(String text) {
  if (!text.contains('access_token=')) return null;
  var token = text
      .split('access_token=')
      .elementAtOrNull(1)
      ?.split('&token_type')
      .firstOrNull;
  if (token == null || token.isEmpty) return null;
  token = token.replaceAll(RegExp(r'[\r\n]'), '');
  if (token.endsWith('/')) token = token.substring(0, token.length - 1);
  if (token.isEmpty) return null;
  return token;
}

/// Parses a pasted MAL authorization redirect (`…?code=<code>&state=<state>`).
({String code, String state})? parseMalRedirect(String text) {
  if (!text.contains('code=') || !text.contains('&state')) return null;
  var code =
      text.split('code=').elementAtOrNull(1)?.split('&state').firstOrNull ?? '';
  var state = text.split('&state=').elementAtOrNull(1) ?? '';
  if (code.isEmpty || state.isEmpty) return null;
  if (code.endsWith('/')) code = code.substring(0, code.length - 1);
  if (state.endsWith('/')) state = state.substring(0, state.length - 1);
  if (state.contains('%')) state = Uri.decodeComponent(state);
  code = code.replaceAll(RegExp(r'[\r\n]'), '');
  state = state.replaceAll(RegExp(r'[\r\n]'), '');
  if (code.isEmpty || state.isEmpty) return null;
  return (code: code, state: state);
}

const _pkceChars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// PKCE code verifier for MAL's `plain` challenge method (challenge ==
/// verifier; the MAL app type must be "other").
String generatePkceVerifier([math.Random? random]) {
  final rng = random ?? math.Random.secure();
  return List.generate(
    128,
    (_) => _pkceChars[rng.nextInt(_pkceChars.length)],
  ).join();
}

/// Persists provider tokens through the [CredentialStore] port. Key names
/// mirror the old localStorage keys.
class TrackingAuthStore {
  TrackingAuthStore(this._store, {Clock clock = const SystemClock()})
    : _clock = clock;

  static const aniListKey = 'ALviewer';
  static const malKey = 'MALviewer';

  final CredentialStore _store;
  final Clock _clock;

  Future<AniListToken?> readAniList() async {
    final raw = await _store.read(aniListKey);
    if (raw == null) return null;
    try {
      return AniListToken.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeAniList(AniListToken token) =>
      _store.write(aniListKey, jsonEncode(token.toJson()));

  Future<void> deleteAniList() => _store.delete(aniListKey);

  Future<MalToken?> readMal() async {
    final raw = await _store.read(malKey);
    if (raw == null) return null;
    try {
      return MalToken.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeMal(MalToken token) =>
      _store.write(malKey, jsonEncode(token.toJson()));

  Future<void> deleteMal() => _store.delete(malKey);

  /// Validates the stored AniList token like the old `validateToken()`:
  /// marks `reauth` once soft-expired so the UI can prompt, and reports the
  /// current health so callers can decide whether to attach it.
  Future<TokenHealth?> validateAniList() async {
    final token = await readAniList();
    if (token == null) return null;
    final health = token.health(_clock.now());
    if (health != TokenHealth.valid && !token.reauth) {
      await writeAniList(token.withReauth());
    }
    return health;
  }
}
