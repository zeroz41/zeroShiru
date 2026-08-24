// ignore_for_file: prefer_initializing_formals

/// MyAnimeList REST client over the [HttpTransport] seam, ported from the
/// redo branch's `providers/myanimelist/myanimelist.js`.
///
/// - `GET  users/@me`                          — viewer
/// - `GET  users/@me/animelist` (paged, nsfw)  — user list
/// - `PATCH anime/{idMal}/my_list_status`      — save entry
/// - `DELETE anime/{idMal}/my_list_status`     — delete entry
/// - `POST https://myanimelist.net/v1/oauth2/token` — PKCE code exchange and
///   refresh_token rotation (refresh window: 14 days, see auth.dart).
///
/// Status mapping (both directions):
///   watching<->CURRENT, plan_to_watch<->PLANNING, completed<->COMPLETED,
///   dropped<->DROPPED, on_hold<->PAUSED, and REPEATING is `watching` with
///   `is_rewatching: true` (MAL has no separate rewatching list).
library;

import 'dart:convert';

import '../../domain/models/media.dart';
import '../network/transport.dart';
import 'sync_rules.dart';

/// MAL app client id (app type "other", plain PKCE).
const malClientId = 'bb7dce3881d803e656c45aa39bda9ccc';

/// The fields the old app requested for list entries.
const malListFields = [
  'synopsis',
  'alternative_titles',
  'mean',
  'rank',
  'popularity',
  'num_list_users',
  'num_scoring_users',
  'related_anime',
  'media_type',
  'num_episodes',
  'status',
  'my_list_status',
  'start_date',
  'end_date',
  'start_season',
  'broadcast',
  'studios',
  'authors{first_name,last_name}',
  'source',
  'genres',
  'average_episode_duration',
  'rating',
];

/// MAL status string -> AniList-shaped [ListStatus].
ListStatus? listStatusFromMal(String? status, {bool isRewatching = false}) {
  if (isRewatching) return ListStatus.repeating;
  return switch (status) {
    'watching' => ListStatus.current,
    'rewatching' => ListStatus.repeating,
    'plan_to_watch' => ListStatus.planning,
    'completed' => ListStatus.completed,
    'dropped' => ListStatus.dropped,
    'on_hold' => ListStatus.paused,
    _ => null,
  };
}

/// [ListStatus] -> MAL status string. REPEATING maps to `watching`; callers
/// must also send `is_rewatching: true` (which [MalClient.setListStatus]
/// does).
String malStatusOf(ListStatus status) => switch (status) {
  ListStatus.current => 'watching',
  ListStatus.repeating => 'watching',
  ListStatus.planning => 'plan_to_watch',
  ListStatus.completed => 'completed',
  ListStatus.dropped => 'dropped',
  ListStatus.paused => 'on_hold',
};

class MalViewer {
  const MalViewer({required this.id, required this.name, this.picture});

  final int id;
  final String name;
  final String? picture;
}

class MalOAuthToken {
  const MalOAuthToken({
    required this.accessToken,
    required this.refreshToken,
    this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final Duration? expiresIn;
}

/// One entry of the user's animelist (`{node: {...}}`).
class MalListItem {
  const MalListItem({
    required this.idMal,
    required this.title,
    this.status,
    this.progress = 0,
    this.score,
    this.repeat = 0,
    this.numEpisodes,
    this.startDate,
    this.finishDate,
    required this.raw,
  });

  final int idMal;
  final String title;

  /// Already mapped to the AniList-shaped status (is_rewatching honoured).
  final ListStatus? status;
  final int progress;

  /// Raw 0-10 MAL score.
  final double? score;
  final int repeat;
  final int? numEpisodes;
  final String? startDate;
  final String? finishDate;

  /// The full `node` payload for anything the typed view doesn't carry.
  final Map<String, dynamic> raw;
}

class MalException implements Exception {
  const MalException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'MalException($status, $message)';
}

class MalClient {
  MalClient({required HttpTransport transport, String? Function()? token})
    : _transport = transport,
      _token = token;

  static const apiBase = 'https://api.myanimelist.net/v2';
  static final tokenEndpoint = Uri.parse(
    'https://myanimelist.net/v1/oauth2/token',
  );

  final HttpTransport _transport;
  final String? Function()? _token;

  Future<Map<String, dynamic>?> _request(
    HttpMethod method,
    String path, {
    String? token,
    List<(String, String)>? form,
  }) async {
    final auth = token ?? _token?.call();
    if (auth == null) {
      throw const MalException(401, 'no MyAnimeList token available');
    }
    final response = await _transport.send(
      HttpRequest(
        method,
        Uri.parse('$apiBase/$path'),
        headers: {
          'Authorization': 'Bearer $auth',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form == null ? null : FormBody(form),
      ),
    );
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      json = decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      json = null;
    }
    if (!response.ok) {
      if (response.status == 404) return null;
      throw MalException(
        response.status,
        json?['error'] as String? ??
            json?['message'] as String? ??
            'MyAnimeList request failed',
      );
    }
    return json ?? const {};
  }

  // --- OAuth2 PKCE -------------------------------------------------------

  Future<MalOAuthToken> _tokenGrant(List<(String, String)> fields) async {
    final response = await _transport.send(
      HttpRequest(
        HttpMethod.post,
        tokenEndpoint,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: FormBody(fields),
      ),
    );
    if (!response.ok) {
      throw MalException(response.status, 'token grant failed');
    }
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return MalOAuthToken(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresIn: json['expires_in'] is num
          ? Duration(seconds: (json['expires_in'] as num).toInt())
          : null,
    );
  }

  /// authorization_code grant with the plain PKCE verifier.
  Future<MalOAuthToken> exchangeCode({
    required String code,
    required String codeVerifier,
  }) => _tokenGrant([
    ('client_id', malClientId),
    ('grant_type', 'authorization_code'),
    ('code', code),
    ('code_verifier', codeVerifier),
  ]);

  /// refresh_token grant (rotation — MAL hands back a fresh pair).
  Future<MalOAuthToken> refreshToken(String refreshToken) => _tokenGrant([
    ('client_id', malClientId),
    ('grant_type', 'refresh_token'),
    ('refresh_token', refreshToken),
  ]);

  // --- queries -----------------------------------------------------------

  Future<MalViewer?> viewer({String? token}) async {
    final res = await _request(HttpMethod.get, 'users/@me', token: token);
    if (res == null || res['id'] is! num) return null;
    return MalViewer(
      id: (res['id'] as num).toInt(),
      name: res['name'] as String? ?? '?',
      // MAL doesn't return the default avatar when none is set.
      picture:
          res['picture'] as String? ??
          'https://cdn.myanimelist.net/images/kaomoji_mal_white.png',
    );
  }

  /// The whole animelist, paged at the API max of 1000 with `nsfw=true`.
  Future<List<MalListItem>> userList({
    String? token,
    String sort = 'list_updated_at',
  }) async {
    const limit = 1000;
    var offset = 0;
    final items = <MalListItem>[];
    while (true) {
      final fields = malListFields.join(',');
      final res = await _request(
        HttpMethod.get,
        'users/@me/animelist?fields=$fields&nsfw=true&limit=$limit&offset=$offset&sort=$sort',
        token: token,
      );
      final data = res?['data'] as List? ?? const [];
      for (final item in data.whereType<Map>()) {
        final node = (item['node'] as Map?)?.cast<String, dynamic>();
        if (node == null || node['id'] is! num) continue;
        final myStatus = (node['my_list_status'] as Map?)
            ?.cast<String, dynamic>();
        items.add(
          MalListItem(
            idMal: (node['id'] as num).toInt(),
            title: node['title'] as String? ?? '?',
            status: listStatusFromMal(
              myStatus?['status'] as String?,
              isRewatching: myStatus?['is_rewatching'] as bool? ?? false,
            ),
            progress: (myStatus?['num_episodes_watched'] as num?)?.toInt() ?? 0,
            score: (myStatus?['score'] as num?)?.toDouble(),
            repeat: (myStatus?['num_times_rewatched'] as num?)?.toInt() ?? 0,
            numEpisodes: (node['num_episodes'] as num?)?.toInt(),
            startDate: myStatus?['start_date'] as String?,
            finishDate: myStatus?['finish_date'] as String?,
            raw: node,
          ),
        );
      }
      if (data.length < limit) break;
      offset += limit;
    }
    return items;
  }

  // --- mutations ---------------------------------------------------------

  static String? _formatDate(FuzzyDate? date) =>
      (date?.isComplete ?? false) ? date!.sortKey : null;

  /// PATCH `anime/{idMal}/my_list_status`. [score] is MAL-raw 0-10.
  /// Returns the updated `my_list_status` payload, or null on 404.
  Future<Map<String, dynamic>?> setListStatus({
    required int idMal,
    required ListStatus status,
    required int progress,
    int repeat = 0,
    int score = 0,
    FuzzyDate? startedAt,
    FuzzyDate? completedAt,
    String? token,
  }) async {
    var startDate = _formatDate(startedAt);
    var finishDate = _formatDate(completedAt);
    // Same guard as the old client: a start date after the finish date
    // collapses to yesterday/today.
    if (startDate != null &&
        finishDate != null &&
        startDate.compareTo(finishDate) > 0) {
      final now = DateTime.now();
      finishDate = FuzzyDate.of(now).sortKey;
      startDate = FuzzyDate.of(now.subtract(const Duration(days: 1))).sortKey;
    }
    return _request(
      HttpMethod.patch,
      'anime/$idMal/my_list_status',
      token: token,
      form: [
        ('status', malStatusOf(status)),
        ('is_rewatching', (status == ListStatus.repeating).toString()),
        ('num_watched_episodes', progress.toString()),
        ('num_times_rewatched', repeat.toString()),
        ('score', score.toString()),
        if (startDate != null) ('start_date', startDate),
        if (finishDate != null) ('finish_date', finishDate),
      ],
    );
  }

  /// DELETE `anime/{idMal}/my_list_status`. Returns false on 404.
  Future<bool> deleteListStatus(int idMal, {String? token}) async {
    final res = await _request(
      HttpMethod.delete,
      'anime/$idMal/my_list_status',
      token: token,
    );
    return res != null;
  }
}
