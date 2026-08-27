/// AniList client: response -> domain Media mapping, cache TTLs, request
/// shape (customLists asArray, POINT_10 score).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/infrastructure/tracking/anilist_client.dart';

import 'fakes.dart';

Map<String, dynamic> sampleMediaJson({
  int id = 21,
  Map<String, dynamic>? entry,
}) => {
  'id': id,
  'idMal': 21,
  'title': {
    'romaji': 'One Piece',
    'english': 'ONE PIECE',
    'native': 'ワンピース',
    'userPreferred': 'One Piece',
  },
  'description': 'Pirates.',
  'season': 'FALL',
  'seasonYear': 1999,
  'format': 'TV',
  'status': 'RELEASING',
  'episodes': null,
  'duration': 24,
  'averageScore': 88,
  'genres': ['Action', 'Adventure'],
  'synonyms': ['OP'],
  'isAdult': false,
  'coverImage': {
    'extraLarge': 'https://img/xl.png',
    'large': 'https://img/l.png',
    'medium': 'https://img/m.png',
    'color': '#e4a15d',
  },
  'bannerImage': 'https://img/banner.png',
  'nextAiringEpisode': {'episode': 1140, 'airingAt': 1766448000},
  'mediaListEntry': entry,
};

void main() {
  late FakeTransport transport;
  late InMemoryQueryCache cache;
  late AnilistClient client;

  setUp(() {
    transport = FakeTransport();
    cache = InMemoryQueryCache();
    client = AnilistClient(
      transport: transport,
      cache: cache,
      token: () => 'ani-token',
      random: math.Random(7),
    );
  });

  Map<String, dynamic> lastBody() =>
      jsonDecode(utf8.decode((transport.requests.last.body! as dynamic).bytes))
          as Map<String, dynamic>;

  group('media mapping', () {
    test('maps a full media object into the domain model', () {
      final media = mediaFromAnilistJson(
        sampleMediaJson(
          entry: {
            'id': 555,
            'progress': 1100,
            'repeat': 1,
            'status': 'CURRENT',
            'score': 9,
            'customLists': [
              {'name': 'Shonen', 'enabled': true},
              {'name': 'Hidden', 'enabled': false},
            ],
          },
        ),
      );

      expect(media.id, 21);
      expect(media.idMal, 21);
      expect(media.title.display, 'One Piece');
      expect(media.format, MediaFormat.tv);
      expect(media.status, MediaStatus.releasing);
      expect(media.season, MediaSeason.fall);
      expect(media.seasonYear, 1999);
      expect(media.episodes, isNull);
      expect(media.duration, 24);
      expect(media.coverImage, 'https://img/xl.png');
      expect(media.coverColor, '#e4a15d');
      expect(media.genres, ['Action', 'Adventure']);
      expect(media.averageScore, 88);
      expect(media.isAdult, isFalse);
      expect(media.synonyms, ['OP']);
      expect(media.nextAiringEpisode!.episode, 1140);
      expect(
        media.nextAiringEpisode!.airingAt,
        DateTime.fromMillisecondsSinceEpoch(1766448000 * 1000),
      );
      expect(media.maxEpisode, 1139, reason: 'nextAiring - 1 while releasing');

      final entry = media.listEntry!;
      expect(entry.status, ListStatus.current);
      expect(entry.progress, 1100);
      expect(entry.repeat, 1);
      expect(entry.score, 9.0);
      expect(entry.customLists, [
        'Shonen',
      ], reason: 'only enabled custom lists survive');
    });

    test('missing optionals map to null/defaults', () {
      final media = mediaFromAnilistJson({
        'id': 1,
        'title': {'romaji': 'X'},
      });
      expect(media.listEntry, isNull);
      expect(media.nextAiringEpisode, isNull);
      expect(media.genres, isEmpty);
      expect(media.format, isNull);
    });

    test('format and status unknown values degrade gracefully', () {
      expect(mediaFormatFromAnilist('TV_SHORT'), MediaFormat.tvShort);
      expect(mediaFormatFromAnilist('SOMETHING_NEW'), MediaFormat.unknown);
      expect(mediaStatusFromAnilist('HIATUS'), MediaStatus.hiatus);
      expect(mediaStatusFromAnilist('???'), isNull);
      expect(listStatusFromAnilist('REPEATING'), ListStatus.repeating);
    });
  });

  group('requests', () {
    test(
      'search POSTs to graphql.anilist.co with auth and filter variables',
      () async {
        transport.onJson('graphql.anilist.co', {
          'data': {
            'Page': {
              'pageInfo': {'hasNextPage': true},
              'media': [sampleMediaJson()],
            },
          },
        });

        final page = await client.search(
          const AnilistSearchFilter(
            search: 'one piece',
            genres: ['Action'],
            genresExclude: ['Hentai'],
            tags: ['Pirates'],
            season: 'FALL',
            year: 1999,
            formats: ['TV'],
            statuses: ['RELEASING'],
            sort: 'POPULARITY_DESC',
            onList: true,
            isAdult: false,
          ),
        );

        expect(page.hasNextPage, isTrue);
        expect(page.media.single.id, 21);

        final request = transport.requests.single;
        expect(request.method.name, 'post');
        expect(request.headers['Authorization'], 'ani-token');
        final body = lastBody();
        final query = body['query'] as String;
        expect(query, contains('customLists(asArray: true)'));
        expect(query, contains('score(format: POINT_10)'));
        final vars = body['variables'] as Map<String, dynamic>;
        expect(vars['search'], 'one piece');
        expect(vars['genre'], ['Action']);
        expect(vars['genre_not'], ['Hentai']);
        expect(vars['tag'], ['Pirates']);
        expect(vars['season'], 'FALL');
        expect(vars['year'], 1999);
        expect(vars['format'], ['TV']);
        expect(vars['status'], ['RELEASING']);
        expect(vars['sort'], 'POPULARITY_DESC');
        expect(vars['onList'], true);
        expect(vars['isAdult'], false);
      },
    );

    test('sort OMIT drops the sort variable entirely', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {'Media': sampleMediaJson()},
      });
      await client.mediaById(21);
      final vars = lastBody()['variables'] as Map<String, dynamic>;
      expect(vars.containsKey('sort'), isFalse);
      expect(vars['id'], 21);
    });

    test('GraphQL errors surface as AnilistException', () async {
      transport.on(
        'graphql.anilist.co',
        (_) => FakeTransport.jsonResponse({
          'errors': [
            {'message': 'Invalid token', 'status': 400},
          ],
        }, status: 400),
      );
      expect(
        () => client.viewer(),
        throwsA(
          isA<AnilistException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.message, 'message', contains('Invalid token')),
        ),
      );
    });
  });

  group('cache TTLs', () {
    test('search caches into query_search with a 75-100 minute TTL and '
        'serves the second read from cache', () async {
      var calls = 0;
      transport.on('graphql.anilist.co', (_) {
        calls++;
        return {
          'data': {
            'Page': {
              'pageInfo': {'hasNextPage': false},
              'media': [sampleMediaJson()],
            },
          },
        };
      });

      await client.search(const AnilistSearchFilter(search: 'op'));
      await client.search(const AnilistSearchFilter(search: 'op'));
      expect(calls, 1, reason: 'second read served from cache');

      final (store, _, ttl) = cache.writes.single;
      expect(store, 'query_search');
      expect(ttl!.inMinutes, inInclusiveRange(75, 100));
    });

    test('userLists caches for exactly 14 minutes', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'MediaListCollection': {
            'lists': [
              {
                'status': 'CURRENT',
                'entries': [
                  {'media': sampleMediaJson()},
                ],
              },
            ],
          },
        },
      });
      final lists = await client.userLists(userId: 99);
      expect(lists.single.status, ListStatus.current);
      expect(lists.single.entries.single.id, 21);
      final (store, _, ttl) = cache.writes.single;
      expect(store, 'user_lists');
      expect(ttl, const Duration(minutes: 14));
    });

    test('expired metadata is served immediately while it refreshes', () async {
      var offline = false;
      var calls = 0;
      final offlineClient = AnilistClient(
        transport: transport,
        cache: cache,
        offline: () => offline,
        random: math.Random(7),
      );
      transport.on('graphql.anilist.co', (_) {
        calls++;
        return {
          'data': {
            'Page': {
              'pageInfo': {'hasNextPage': false},
              'media': [],
            },
          },
        };
      });

      await offlineClient.search(const AnilistSearchFilter(search: 'x'));
      cache.clock.advance(const Duration(hours: 2)); // past every search TTL
      await offlineClient.search(const AnilistSearchFilter(search: 'x'));
      expect(calls, 2, reason: 'expired online -> background refresh');

      cache.clock.advance(const Duration(hours: 2));
      offline = true;
      await offlineClient.search(const AnilistSearchFilter(search: 'x'));
      expect(calls, 2, reason: 'offline ignores expiry');
    });

    test('stale metadata does not wait for a slow refresh', () async {
      var calls = 0;
      final refresh = Completer<Object>();
      Map<String, dynamic> page(int id) => {
        'data': {
          'Page': {
            'pageInfo': {'hasNextPage': false},
            'media': [sampleMediaJson(id: id)],
          },
        },
      };
      transport.on('graphql.anilist.co', (_) {
        calls++;
        return calls == 1 ? page(21) : refresh.future;
      });

      final first = await client.search(
        const AnilistSearchFilter(search: 'persistent'),
      );
      expect(first.media.single.id, 21);
      cache.clock.advance(const Duration(hours: 2));

      final stale = await client.search(
        const AnilistSearchFilter(search: 'persistent'),
      );
      expect(stale.media.single.id, 21);
      expect(calls, 2);

      refresh.complete(page(22));
      await pumpEventQueue();
      final updated = await client.search(
        const AnilistSearchFilter(search: 'persistent'),
      );
      expect(updated.media.single.id, 22);
      expect(calls, 2, reason: 'the background response refreshed SQLite');
    });

    test('mediaById and searchIds use the query_search_ids store with their '
        'own TTL bands', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'Media': sampleMediaJson(),
          'Page': {
            'pageInfo': {'hasNextPage': false},
            'media': [sampleMediaJson()],
          },
        },
      });
      await client.mediaById(21);
      await client.searchIds(ids: [21, 22]);
      expect(cache.writes, hasLength(2));
      final (store1, _, ttl1) = cache.writes[0];
      final (store2, _, ttl2) = cache.writes[1];
      expect(store1, 'query_search_ids');
      expect(store2, 'query_search_ids');
      expect(ttl1!.inMinutes, inInclusiveRange(80, 100));
      expect(ttl2!.inMinutes, inInclusiveRange(24, 30));
    });

    test('episodesAiring uses query_episodes with 75-100min and maps the '
        'schedule', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'Page': {
            'airingSchedules': [
              {'episode': 1, 'airingAt': 1600000000},
              {'episode': 2, 'airingAt': 1600604800},
            ],
          },
        },
      });
      final episodes = await client.episodesAiring(21);
      expect(episodes, hasLength(2));
      expect(episodes.first.episode, 1);
      final (store, key, ttl) = cache.writes.single;
      expect(store, 'query_episodes');
      expect(key, '21');
      expect(ttl!.inMinutes, inInclusiveRange(75, 100));
    });

    test(
      'recommendations use query_recommendations with 1500-2000min',
      () async {
        transport.onJson('graphql.anilist.co', {
          'data': {
            'Media': {
              'id': 21,
              'recommendations': {
                'edges': [
                  {
                    'node': {
                      'rating': 120,
                      'mediaRecommendation': {
                        'id': 30,
                        'genres': ['Action'],
                        'isAdult': false,
                      },
                    },
                  },
                ],
              },
            },
          },
        });
        final recs = await client.recommendations(21);
        expect(recs.single.id, 30);
        expect(recs.single.rating, 120);
        final (store, _, ttl) = cache.writes.single;
        expect(store, 'query_recommendations');
        expect(ttl!.inMinutes, inInclusiveRange(1500, 2000));
      },
    );
  });

  group('mutations', () {
    test('saveMediaListEntry sends scoreRaw and fuzzy dates, returns the '
        'saved entry', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'SaveMediaListEntry': {
            'id': 777,
            'status': 'CURRENT',
            'progress': 5,
            'score': 8.5,
            'repeat': 0,
          },
        },
      });
      final saved = await client.saveMediaListEntry(
        mediaId: 21,
        status: ListStatus.current,
        progress: 5,
        score: 85,
        startedAt: {'year': 2026, 'month': 8, 'day': 23},
      );
      expect(saved!.entryId, 777);
      expect(saved.status, ListStatus.current);
      expect(saved.progress, 5);

      final vars = lastBody()['variables'] as Map<String, dynamic>;
      expect(vars['id'], 21);
      expect(vars['status'], 'CURRENT');
      expect(vars['episode'], 5);
      expect(vars['score'], 85);
      expect(vars['startedAt'], {'year': 2026, 'month': 8, 'day': 23});
      expect(lastBody()['query'], contains('scoreRaw: \$score'));
    });

    test('deleteMediaListEntry reports deleted', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'DeleteMediaListEntry': {'deleted': true},
        },
      });
      expect(await client.deleteMediaListEntry(777), isTrue);
      final vars = lastBody()['variables'] as Map<String, dynamic>;
      expect(vars['id'], 777);
    });

    test('toggleFavourite hits ToggleFavourite(animeId:)', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'ToggleFavourite': {
            'anime': {
              'nodes': [
                {'id': 21},
              ],
            },
          },
        },
      });
      expect(await client.toggleFavourite(21), isTrue);
      expect(lastBody()['query'], contains('ToggleFavourite(animeId: \$id)'));
    });

    test('mutations are never cached', () async {
      transport.onJson('graphql.anilist.co', {
        'data': {
          'SaveMediaListEntry': {'id': 1, 'status': 'CURRENT', 'progress': 1},
        },
      });
      await client.saveMediaListEntry(
        mediaId: 21,
        status: ListStatus.current,
        progress: 1,
      );
      expect(cache.writes, isEmpty);
    });
  });
}
