import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/tracking_account.dart';
import 'package:zeroshiru/infrastructure/tracking/anilist_client.dart';
import 'package:zeroshiru/infrastructure/tracking/auth.dart';
import 'package:zeroshiru/infrastructure/tracking/tracking_repository_impl.dart';

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
}
