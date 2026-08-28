import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/tracking_account.dart';
import 'package:zero/infrastructure/tracking/anilist_client.dart';
import 'package:zero/infrastructure/tracking/auth.dart';
import 'package:zero/infrastructure/tracking/tracking_repository_impl.dart';

import 'fakes.dart';

void main() {
  test(
    'account summaries expose identity and health without credentials',
    () async {
      final clock = FakeClock();
      final credentials = InMemoryCredentialStore();
      final auth = TrackingAuthStore(credentials, clock: clock);
      await auth.writeAniList(
        AniListToken.issue(
          'secret-anilist-token',
          now: clock.now(),
          viewerId: 10,
          viewerName: 'Fern',
          viewerAvatar: 'https://img/avatar.png',
        ),
      );
      await auth.writeMal(
        MalToken.issue(
          'secret-mal-token',
          'secret-refresh-token',
          now: clock.now(),
          viewerId: 20,
          viewerName: 'Stark',
        ),
      );
      clock.advance(const Duration(days: 15));

      final repository = TrackingRepositoryImpl(
        anilist: AnilistClient(
          transport: FakeTransport(),
          cache: InMemoryQueryCache(),
        ),
        auth: auth,
        clock: clock,
      );
      final accounts = await repository.accounts();

      expect(accounts, hasLength(2));
      expect(accounts.first.service, TrackingAccountService.aniList);
      expect(accounts.first.displayName, 'Fern');
      expect(accounts.first.health, TrackingAccountHealth.connected);
      expect(accounts.last.service, TrackingAccountService.myAnimeList);
      expect(accounts.last.displayName, 'Stark');
      expect(accounts.last.health, TrackingAccountHealth.attention);
      expect(accounts.toString(), isNot(contains('secret-')));
    },
  );

  group('connectAniList', () {
    TrackingRepositoryImpl repository(
      FakeTransport transport,
      TrackingAuthStore auth,
      FakeClock clock,
    ) => TrackingRepositoryImpl(
      anilist: AnilistClient(transport: transport, cache: InMemoryQueryCache()),
      auth: auth,
      clock: clock,
    );

    Map<String, Object> viewerResponse() => {
      'data': {
        'Viewer': {
          'id': 55,
          'name': 'Frieren',
          'avatar': {'large': 'https://img/frieren.png'},
          'mediaListOptions': {
            'animeList': {'customLists': <Object>[]},
          },
        },
      },
    };

    test('a pasted redirect address stores a validated account', () async {
      final clock = FakeClock();
      final transport = FakeTransport()
        ..onJson('graphql.anilist.co', viewerResponse());
      final credentials = InMemoryCredentialStore();
      final auth = TrackingAuthStore(credentials, clock: clock);

      final account = await repository(transport, auth, clock).connectAniList(
        'shiru://alauth#access_token=fresh-token&token_type=Bearer&expires_in=31536000',
      );

      expect(account.service, TrackingAccountService.aniList);
      expect(account.displayName, 'Frieren');
      expect(account.health, TrackingAccountHealth.connected);
      final stored = (await auth.readAniList())!;
      expect(stored.token, 'fresh-token');
      expect(stored.viewerId, 55);
      expect(stored.viewerName, 'Frieren');
      // The verification request itself carried the pasted token.
      expect(
        transport.requests.single.headers['Authorization'],
        'Bearer fresh-token',
      );
    });

    test('a bare token is accepted without a redirect wrapper', () async {
      final clock = FakeClock();
      final transport = FakeTransport()
        ..onJson('graphql.anilist.co', viewerResponse());
      final auth = TrackingAuthStore(InMemoryCredentialStore(), clock: clock);
      final token = 'ey${'a' * 60}';

      final account = await repository(
        transport,
        auth,
        clock,
      ).connectAniList('  $token  ');

      expect(account.displayName, 'Frieren');
      expect((await auth.readAniList())!.token, token);
    });

    test('text without a token is rejected before any request', () async {
      final clock = FakeClock();
      final transport = FakeTransport();
      final auth = TrackingAuthStore(InMemoryCredentialStore(), clock: clock);

      await expectLater(
        repository(transport, auth, clock).connectAniList('hello world'),
        throwsArgumentError,
      );
      expect(transport.requests, isEmpty);
      expect(await auth.readAniList(), isNull);
    });

    test('a token AniList rejects stores nothing', () async {
      final clock = FakeClock();
      final transport = FakeTransport()
        ..onJson('graphql.anilist.co', {
          'data': {'Viewer': null},
        });
      final auth = TrackingAuthStore(InMemoryCredentialStore(), clock: clock);

      await expectLater(
        repository(
          transport,
          auth,
          clock,
        ).connectAniList('#access_token=bad-token&token_type=Bearer'),
        throwsStateError,
      );
      expect(await auth.readAniList(), isNull);
    });

    test('disconnect removes only the requested service', () async {
      final clock = FakeClock();
      final auth = TrackingAuthStore(InMemoryCredentialStore(), clock: clock);
      await auth.writeAniList(
        AniListToken.issue('ani-token', now: clock.now(), viewerId: 1),
      );
      await auth.writeMal(
        MalToken.issue('mal-token', 'refresh', now: clock.now(), viewerId: 2),
      );
      final repo = repository(FakeTransport(), auth, clock);

      await repo.disconnect(TrackingAccountService.aniList);

      expect(await auth.readAniList(), isNull);
      expect(await auth.readMal(), isNotNull);
    });
  });
}
