// ignore_for_file: prefer_initializing_formals

/// AniList GraphQL client over the [HttpTransport] seam, ported from the redo
/// branch's `providers/anilist/anilist.js`.
///
/// Reads go through the [QueryCache] port with the same store + TTL table the
/// old app used:
///
/// | operation        | store               | expiry                |
/// |------------------|---------------------|-----------------------|
/// | search           | query_search        | random 75-100 min     |
/// | mediaById        | query_search_ids    | random 80-100 min     |
/// | searchIds        | query_search_ids    | random 24-30 min      |
/// | userLists        | user_lists          | 14 min                |
/// | episodesAiring   | query_episodes      | random 75-100 min     |
/// | recommendations  | query_recommendations | random 1500-2000 min|
///
/// The media fragment requests `customLists(asArray: true)` and
/// `score(format: POINT_10)` exactly like the old app.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../domain/models/media.dart';
import '../../domain/ports/query_cache.dart';
import '../../domain/ports/http_transport.dart';

/// The media fragment body (old `queryObjects`, trimmed to what the domain
/// model carries plus what the sync rules need).
const anilistMediaFragment = '''
id,
idMal,
title { romaji, english, native, userPreferred },
description(asHtml: false),
season,
seasonYear,
format,
status,
episodes,
duration,
averageScore,
genres,
synonyms,
isAdult,
coverImage { extraLarge, large, medium, color },
bannerImage,
nextAiringEpisode { episode, airingAt },
mediaListEntry {
  id,
  progress,
  repeat,
  status,
  customLists(asArray: true),
  score(format: POINT_10),
  updatedAt,
  startedAt { year, month, day },
  completedAt { year, month, day }
}''';

/// Stable cache key for a variables map: sorted keys, JSON encoded.
String anilistCanonicalKey(Map<String, dynamic> variables) {
  final sorted = Map.fromEntries(
    variables.entries.where((e) => e.value != null).toList()
      ..sort((a, b) => a.key.compareTo(b.key)),
  );
  return jsonEncode(sorted);
}

class AnilistViewer {
  const AnilistViewer({
    required this.id,
    required this.name,
    this.avatar,
    this.customLists = const [],
  });

  final int id;
  final String name;
  final String? avatar;
  final List<String> customLists;
}

class AnilistPage {
  const AnilistPage({required this.hasNextPage, required this.media});

  final bool hasNextPage;
  final List<Media> media;
}

/// One MediaListCollection list (Watching, Completed, ...).
class AnilistList {
  const AnilistList({this.status, required this.entries});

  final ListStatus? status;
  final List<Media> entries;
}

class AnilistRecommendation {
  const AnilistRecommendation({
    required this.id,
    required this.rating,
    this.genres = const [],
    this.isAdult = false,
  });

  final int id;
  final int rating;
  final List<String> genres;
  final bool isAdult;
}

/// The list entry a SaveMediaListEntry mutation returns (richer than the
/// domain [ListEntry] — carries the entry id and fuzzy dates).
class AnilistSavedEntry {
  const AnilistSavedEntry({
    this.entryId,
    this.status,
    this.progress,
    this.score,
    this.repeat,
  });

  final int? entryId;
  final ListStatus? status;
  final int? progress;
  final double? score;
  final int? repeat;
}

/// The search filter variables the old app used (Page media query).
class AnilistSearchFilter {
  const AnilistSearchFilter({
    this.page = 1,
    this.perPage = 50,
    this.sort,
    this.search,
    this.genres,
    this.genresExclude,
    this.tags,
    this.tagsExclude,
    this.season,
    this.year,
    this.formats,
    this.formatsExclude,
    this.statuses,
    this.statusesExclude,
    this.onList,
    this.isAdult,
    this.ids,
    this.idsExclude,
    this.idsMal,
  });

  final int page;
  final int perPage;

  /// AniList MediaSort, e.g. 'TRENDING_DESC'. Null keeps the default
  /// TRENDING_DESC; 'OMIT' sends no sort at all (id lookups).
  final String? sort;
  final String? search;
  final List<String>? genres;
  final List<String>? genresExclude;
  final List<String>? tags;
  final List<String>? tagsExclude;
  final String? season;
  final int? year;
  final List<String>? formats;
  final List<String>? formatsExclude;
  final List<String>? statuses;
  final List<String>? statusesExclude;
  final bool? onList;
  final bool? isAdult;
  final List<int>? ids;
  final List<int>? idsExclude;
  final List<int>? idsMal;

  Map<String, dynamic> toVariables() => {
    'page': page,
    'perPage': perPage,
    if (sort != null) 'sort': sort,
    if (search != null) 'search': search,
    if (genres != null) 'genre': genres,
    if (genresExclude != null) 'genre_not': genresExclude,
    if (tags != null) 'tag': tags,
    if (tagsExclude != null) 'tag_not': tagsExclude,
    if (season != null) 'season': season,
    if (year != null) 'year': year,
    if (formats != null) 'format': formats,
    if (formatsExclude != null) 'format_not': formatsExclude,
    if (statuses != null) 'status': statuses,
    if (statusesExclude != null) 'status_not': statusesExclude,
    if (onList != null) 'onList': onList,
    if (isAdult != null) 'isAdult': isAdult,
    if (ids != null) 'id': ids,
    if (idsExclude != null) 'id_not': idsExclude,
    if (idsMal != null) 'idMal': idsMal,
  };
}

class AnilistException implements Exception {
  const AnilistException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'AnilistException($status, $message)';
}

class AnilistClient {
  AnilistClient({
    required HttpTransport transport,
    required QueryCache cache,
    String? Function()? token,
    bool Function()? offline,
    math.Random? random,
  }) : _transport = transport,
       _cache = cache,
       _token = token,
       _offline = offline,
       _random = random ?? math.Random();

  static final endpoint = Uri.parse('https://graphql.anilist.co');

  final HttpTransport _transport;
  final QueryCache _cache;
  final String? Function()? _token;
  final bool Function()? _offline;
  final math.Random _random;

  bool get _isOffline => _offline?.call() ?? false;

  /// Random TTL in [min]..[max] minutes inclusive, like the old
  /// `getRandomInt(min, max) * 60 * 1000`.
  Duration _ttlMinutes(int min, int max) =>
      Duration(minutes: min + _random.nextInt(max - min + 1));

  /// POST a GraphQL document. Variables default to page 1 / perPage 50 /
  /// sort TRENDING_DESC; a sort of 'OMIT' drops sort entirely.
  Future<Map<String, dynamic>> request(
    String query,
    Map<String, dynamic> variables, {
    String? token,
  }) async {
    final vars = <String, dynamic>{
      'page': 1,
      'perPage': 50,
      'sort': 'TRENDING_DESC',
      ...variables,
    }..removeWhere((_, v) => v == null);
    if (vars['sort'] == 'OMIT') vars.remove('sort');

    final auth = token ?? _token?.call();
    final response = await _transport.send(
      HttpRequest(
        HttpMethod.post,
        endpoint,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': ?auth,
        },
        body: BytesBody(
          utf8.encode(jsonEncode({'query': query, 'variables': vars})),
          contentType: 'application/json',
        ),
      ),
    );

    Map<String, dynamic>? json;
    try {
      json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on FormatException {
      json = null;
    }
    if (!response.ok) {
      final message =
          (json?['errors'] as List?)
              ?.map((e) => (e as Map)['message'])
              .whereType<String>()
              .join('; ') ??
          'AniList request failed';
      throw AnilistException(response.status, message);
    }
    return json ?? const {};
  }

  /// Cached read helper: serve a live cache hit (stale only when offline),
  /// otherwise fetch and write with [ttl].
  Future<Map<String, dynamic>> _cachedRequest(
    CacheStoreSpec store,
    String key,
    Duration ttl,
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    final hit = await _cache.read(store, key, ignoreExpiry: _isOffline);
    if (hit != null && (!hit.stale || _isOffline)) return hit.value;
    final fresh = await fetch();
    await _cache.write(store, key, fresh, maxAge: ttl);
    return fresh;
  }

  // --- queries -----------------------------------------------------------

  Future<AnilistViewer?> viewer({String? token}) async {
    const query = '''
    query {
      Viewer {
        id,
        name,
        avatar { medium, large },
        mediaListOptions { animeList { customLists } }
      }
    }''';
    final res = await request(query, const {'sort': 'OMIT'}, token: token);
    final v = _dig(res, ['data', 'Viewer']);
    if (v == null) return null;
    return AnilistViewer(
      id: (v['id'] as num).toInt(),
      name: v['name'] as String? ?? '?',
      avatar:
          _dig(v, ['avatar'])?['large'] as String? ??
          _dig(v, ['avatar'])?['medium'] as String?,
      customLists:
          ((_dig(v, ['mediaListOptions', 'animeList'])?['customLists']
                      as List?) ??
                  const [])
              .cast<String>(),
    );
  }

  /// Page media search with the old filter variables.
  Future<AnilistPage> search(AnilistSearchFilter filter) async {
    final variables = filter.toVariables();
    const query =
        '''
    query(\$page: Int, \$perPage: Int, \$sort: [MediaSort], \$search: String, \$onList: Boolean, \$status: [MediaStatus], \$status_not: [MediaStatus], \$season: MediaSeason, \$year: Int, \$genre: [String], \$genre_not: [String], \$tag: [String], \$tag_not: [String], \$format: [MediaFormat], \$format_not: [MediaFormat], \$id_not: [Int], \$id: [Int], \$idMal: [Int], \$isAdult: Boolean) {
      Page(page: \$page, perPage: \$perPage) {
        pageInfo { hasNextPage },
        media(id_not_in: \$id_not, id_in: \$id, idMal_in: \$idMal, type: ANIME, search: \$search, sort: \$sort, onList: \$onList, status_in: \$status, status_not_in: \$status_not, season: \$season, seasonYear: \$year, genre_in: \$genre, genre_not_in: \$genre_not, tag_in: \$tag, tag_not_in: \$tag_not, format_in: \$format, format_not: MUSIC, format_not_in: \$format_not, isAdult: \$isAdult) {
          $anilistMediaFragment
        }
      }
    }''';
    final res = await _cachedRequest(
      CacheStores.querySearch,
      anilistCanonicalKey(variables),
      _ttlMinutes(75, 100),
      () => request(query, variables),
    );
    return _pageFromJson(res);
  }

  /// Batch id lookup (old `searchIDS`). Pass AniList [ids] or MAL [idsMal].
  Future<AnilistPage> searchIds({
    List<int>? ids,
    List<int>? idsMal,
    int page = 1,
    int perPage = 50,
    String sort = 'OMIT',
    bool? onList,
    bool? isAdult,
  }) async {
    final variables = <String, dynamic>{
      'page': page,
      'perPage': perPage,
      'sort': sort,
      'id': ?ids,
      'idMal': ?idsMal,
      'onList': ?onList,
      'isAdult': ?isAdult,
    };
    const query =
        '''
    query(\$id: [Int], \$idMal: [Int], \$page: Int, \$perPage: Int, \$onList: Boolean, \$sort: [MediaSort], \$isAdult: Boolean) {
      Page(page: \$page, perPage: \$perPage) {
        pageInfo { hasNextPage },
        media(id_in: \$id, idMal_in: \$idMal, type: ANIME, onList: \$onList, sort: \$sort, isAdult: \$isAdult) {
          $anilistMediaFragment
        }
      }
    }''';
    final res = await _cachedRequest(
      CacheStores.querySearchIds,
      anilistCanonicalKey(variables),
      _ttlMinutes(24, 30),
      () => request(query, variables),
    );
    return _pageFromJson(res);
  }

  /// Single media lookup by AniList (or MAL) id — old `searchIDSingle`.
  Future<Media?> mediaById(int id, {bool isMal = false}) async {
    final variables = <String, dynamic>{
      if (isMal) 'idMal': id else 'id': id,
      'sort': 'OMIT',
    };
    const query =
        '''
    query(\$id: Int, \$idMal: Int) {
      Media(id: \$id, idMal: \$idMal, type: ANIME) {
        $anilistMediaFragment
      }
    }''';
    final res = await _cachedRequest(
      CacheStores.querySearchIds,
      anilistCanonicalKey(variables),
      _ttlMinutes(80, 100),
      () => request(query, variables),
    );
    final media = _dig(res, ['data', 'Media']);
    return media == null ? null : mediaFromAnilistJson(media);
  }

  /// MediaListCollection for [userId] — 14 minute TTL, re-fetched by the
  /// app's 15-minute interval.
  Future<List<AnilistList>> userLists({
    required int userId,
    String? token,
    String sort = 'UPDATED_TIME_DESC',
  }) async {
    final variables = {'id': userId, 'sort': sort};
    const query =
        '''
    query(\$id: Int, \$sort: [MediaListSort]) {
      MediaListCollection(userId: \$id, type: ANIME, sort: \$sort, forceSingleCompletedList: true) {
        lists {
          status,
          entries {
            media {
              $anilistMediaFragment
            }
          }
        }
      }
    }''';
    final res = await _cachedRequest(
      CacheStores.userLists,
      anilistCanonicalKey(variables),
      const Duration(minutes: 14),
      () => request(query, variables, token: token),
    );
    final lists =
        _dig(res, ['data', 'MediaListCollection'])?['lists'] as List? ??
        const [];
    return [
      for (final list in lists.whereType<Map>())
        AnilistList(
          status: listStatusFromAnilist(list['status'] as String?),
          entries: [
            for (final entry
                in (list['entries'] as List? ?? const []).whereType<Map>())
              if (entry['media'] is Map)
                mediaFromAnilistJson(
                  (entry['media'] as Map).cast<String, dynamic>(),
                ),
          ],
        ),
    ];
  }

  /// Full airing schedule for a media (old `episodes`).
  Future<List<AiringEpisode>> episodesAiring(int mediaId) async {
    const query = r'''
    query($id: Int) {
      Page(page: 1, perPage: 1000) {
        airingSchedules(mediaId: $id) { airingAt, episode }
      }
    }''';
    final res = await _cachedRequest(
      CacheStores.queryEpisodes,
      '$mediaId',
      _ttlMinutes(75, 100),
      () => request(query, {'id': mediaId, 'sort': 'OMIT'}),
    );
    final schedules =
        _dig(res, ['data', 'Page'])?['airingSchedules'] as List? ?? const [];
    return [
      for (final node in schedules.whereType<Map>())
        if (node['episode'] is num && node['airingAt'] is num)
          AiringEpisode(
            episode: (node['episode'] as num).toInt(),
            airingAt: DateTime.fromMillisecondsSinceEpoch(
              (node['airingAt'] as num).toInt() * 1000,
            ),
          ),
    ];
  }

  Future<List<AnilistRecommendation>> recommendations(int mediaId) async {
    const query = r'''
    query($id: Int) {
      Media(id: $id, type: ANIME) {
        id,
        idMal,
        recommendations {
          edges {
            node {
              rating,
              mediaRecommendation { id, genres, isAdult }
            }
          }
        }
      }
    }''';
    final res = await _cachedRequest(
      CacheStores.queryRecommendations,
      '$mediaId',
      _ttlMinutes(1500, 2000),
      () => request(query, {'id': mediaId, 'sort': 'OMIT'}),
    );
    final edges =
        _dig(res, ['data', 'Media', 'recommendations'])?['edges'] as List? ??
        const [];
    return [
      for (final edge in edges.whereType<Map>())
        if (_dig(edge.cast<String, dynamic>(), [
              'node',
              'mediaRecommendation',
            ]) !=
            null)
          AnilistRecommendation(
            id:
                (_dig(edge.cast<String, dynamic>(), [
                          'node',
                          'mediaRecommendation',
                        ])!['id']
                        as num)
                    .toInt(),
            rating:
                ((_dig(edge.cast<String, dynamic>(), ['node'])?['rating'])
                            as num? ??
                        0)
                    .toInt(),
            genres:
                ((_dig(edge.cast<String, dynamic>(), [
                              'node',
                              'mediaRecommendation',
                            ])!['genres']
                            as List?) ??
                        const [])
                    .cast<String>(),
            isAdult:
                _dig(edge.cast<String, dynamic>(), [
                      'node',
                      'mediaRecommendation',
                    ])!['isAdult']
                    as bool? ??
                false,
          ),
    ];
  }

  // --- mutations ---------------------------------------------------------

  /// SaveMediaListEntry. [score] is POINT_100 raw (the sync rules already
  /// multiplied by 10).
  Future<AnilistSavedEntry?> saveMediaListEntry({
    required int mediaId,
    required ListStatus status,
    required int progress,
    int repeat = 0,
    int score = 0,
    Map<String, dynamic>? startedAt,
    Map<String, dynamic>? completedAt,
    String? token,
  }) async {
    const query = r'''
    mutation($id: Int, $status: MediaListStatus, $episode: Int, $repeat: Int, $score: Int, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) {
      SaveMediaListEntry(mediaId: $id, status: $status, progress: $episode, repeat: $repeat, scoreRaw: $score, startedAt: $startedAt, completedAt: $completedAt) {
        id, status, progress, score, repeat, updatedAt,
        startedAt { year, month, day },
        completedAt { year, month, day }
      }
    }''';
    final res = await request(query, {
      'id': mediaId,
      'status': anilistListStatusName(status),
      'episode': progress,
      'repeat': repeat,
      'score': score,
      'startedAt': startedAt,
      'completedAt': completedAt,
      'sort': 'OMIT',
    }, token: token);
    final saved = _dig(res, ['data', 'SaveMediaListEntry']);
    if (saved == null) return null;
    return AnilistSavedEntry(
      entryId: (saved['id'] as num?)?.toInt(),
      status: listStatusFromAnilist(saved['status'] as String?),
      progress: (saved['progress'] as num?)?.toInt(),
      score: (saved['score'] as num?)?.toDouble(),
      repeat: (saved['repeat'] as num?)?.toInt(),
    );
  }

  /// DeleteMediaListEntry — takes the LIST ENTRY id, not the media id.
  Future<bool> deleteMediaListEntry(int entryId, {String? token}) async {
    const query = r'''
    mutation($id: Int) {
      DeleteMediaListEntry(id: $id) { deleted }
    }''';
    final res = await request(query, {
      'id': entryId,
      'sort': 'OMIT',
    }, token: token);
    return _dig(res, ['data', 'DeleteMediaListEntry'])?['deleted'] as bool? ??
        false;
  }

  /// ToggleFavourite for an anime. Returns true when the request went out.
  Future<bool> toggleFavourite(int mediaId, {String? token}) async {
    const query = r'''
    mutation($id: Int) {
      ToggleFavourite(animeId: $id) { anime { nodes { id } } }
    }''';
    final res = await request(query, {
      'id': mediaId,
      'sort': 'OMIT',
    }, token: token);
    return _dig(res, ['data', 'ToggleFavourite']) != null;
  }
}

// --- response -> domain mapping ------------------------------------------

Map<String, dynamic>? _dig(Map<String, dynamic>? json, List<String> path) {
  dynamic cursor = json;
  for (final key in path) {
    if (cursor is! Map) return null;
    cursor = cursor[key];
  }
  return cursor is Map ? cursor.cast<String, dynamic>() : null;
}

AnilistPage _pageFromJson(Map<String, dynamic> res) {
  final page = _dig(res, ['data', 'Page']);
  final media = page?['media'] as List? ?? const [];
  return AnilistPage(
    hasNextPage: _dig(page, ['pageInfo'])?['hasNextPage'] as bool? ?? false,
    media: [
      for (final m in media.whereType<Map>())
        mediaFromAnilistJson(m.cast<String, dynamic>()),
    ],
  );
}

MediaFormat? mediaFormatFromAnilist(String? format) => switch (format) {
  'TV' => MediaFormat.tv,
  'TV_SHORT' => MediaFormat.tvShort,
  'MOVIE' => MediaFormat.movie,
  'SPECIAL' => MediaFormat.special,
  'OVA' => MediaFormat.ova,
  'ONA' => MediaFormat.ona,
  'MUSIC' => MediaFormat.music,
  null => null,
  _ => MediaFormat.unknown,
};

MediaStatus? mediaStatusFromAnilist(String? status) => switch (status) {
  'FINISHED' => MediaStatus.finished,
  'RELEASING' => MediaStatus.releasing,
  'NOT_YET_RELEASED' => MediaStatus.notYetReleased,
  'CANCELLED' => MediaStatus.cancelled,
  'HIATUS' => MediaStatus.hiatus,
  _ => null,
};

MediaSeason? mediaSeasonFromAnilist(String? season) => switch (season) {
  'WINTER' => MediaSeason.winter,
  'SPRING' => MediaSeason.spring,
  'SUMMER' => MediaSeason.summer,
  'FALL' => MediaSeason.fall,
  _ => null,
};

ListStatus? listStatusFromAnilist(String? status) => switch (status) {
  'CURRENT' => ListStatus.current,
  'PLANNING' => ListStatus.planning,
  'COMPLETED' => ListStatus.completed,
  'DROPPED' => ListStatus.dropped,
  'PAUSED' => ListStatus.paused,
  'REPEATING' => ListStatus.repeating,
  _ => null,
};

String anilistListStatusName(ListStatus status) => switch (status) {
  ListStatus.current => 'CURRENT',
  ListStatus.planning => 'PLANNING',
  ListStatus.completed => 'COMPLETED',
  ListStatus.dropped => 'DROPPED',
  ListStatus.paused => 'PAUSED',
  ListStatus.repeating => 'REPEATING',
};

/// Maps a raw AniList media object into the domain [Media].
Media mediaFromAnilistJson(Map<String, dynamic> json) {
  final title = _dig(json, ['title']) ?? const {};
  final cover = _dig(json, ['coverImage']);
  final airing = _dig(json, ['nextAiringEpisode']);
  final entry = _dig(json, ['mediaListEntry']);

  ListEntry? listEntry;
  final entryStatus = listStatusFromAnilist(entry?['status'] as String?);
  if (entry != null && entryStatus != null) {
    listEntry = ListEntry(
      status: entryStatus,
      progress: (entry['progress'] as num?)?.toInt() ?? 0,
      score: (entry['score'] as num?)?.toDouble(),
      repeat: (entry['repeat'] as num?)?.toInt() ?? 0,
      customLists: [
        for (final list
            in (entry['customLists'] as List? ?? const []).whereType<Map>())
          if (list['enabled'] == true && list['name'] is String)
            list['name'] as String,
      ],
    );
  }

  return Media(
    id: (json['id'] as num).toInt(),
    idMal: (json['idMal'] as num?)?.toInt(),
    title: MediaTitle(
      romaji: title['romaji'] as String?,
      english: title['english'] as String?,
      native: title['native'] as String?,
      userPreferred: title['userPreferred'] as String?,
    ),
    format: mediaFormatFromAnilist(json['format'] as String?),
    status: mediaStatusFromAnilist(json['status'] as String?),
    season: mediaSeasonFromAnilist(json['season'] as String?),
    seasonYear: (json['seasonYear'] as num?)?.toInt(),
    episodes: (json['episodes'] as num?)?.toInt(),
    duration: (json['duration'] as num?)?.toInt(),
    coverImage:
        cover?['extraLarge'] as String? ??
        cover?['large'] as String? ??
        cover?['medium'] as String?,
    bannerImage: json['bannerImage'] as String?,
    coverColor: cover?['color'] as String?,
    description: json['description'] as String?,
    genres: (json['genres'] as List? ?? const []).cast<String>(),
    averageScore: (json['averageScore'] as num?)?.toInt(),
    isAdult: json['isAdult'] as bool? ?? false,
    nextAiringEpisode:
        airing != null && airing['episode'] is num && airing['airingAt'] is num
        ? AiringEpisode(
            episode: (airing['episode'] as num).toInt(),
            airingAt: DateTime.fromMillisecondsSinceEpoch(
              (airing['airingAt'] as num).toInt() * 1000,
            ),
          )
        : null,
    listEntry: listEntry,
    synonyms: (json['synonyms'] as List? ?? const []).cast<String>(),
  );
}
