import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/ports/debrid_client.dart';
import 'package:zeroshiru/infrastructure/debrid/debrid_client_impl.dart';

import 'testing.dart';

const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  test('the registry retains the provider menu order and measured facts', () {
    expect(debridServices, DebridService.values);
    expect(
      debridProviderConfig(DebridService.alldebrid).checkAddsMagnets,
      isTrue,
    );
    expect(debridProviderConfig(DebridService.premiumize).maxFiles, 60);
    expect(
      debridProviderConfig(DebridService.realdebrid).availabilityCheck.name,
      'probe',
    );
    expect(debridProviderConfig(DebridService.torbox).maxFiles, 12);
  });

  test(
    'resolved links map to PlayerFile identity and are cached per account',
    () async {
      final transport = MockTransport([
        Route.json(
          '/transfer/directdl',
          200,
          jsonEncode({
            'status': 'success',
            'content': [
              {
                'path': 'Show/Show - 01.mkv',
                'size': 1000,
                'link': 'https://cdn.test/one',
              },
              {
                'path': 'Show/Show - 02.mkv',
                'size': 2000,
                'link': 'https://cdn.test/two',
              },
            ],
          }),
        ),
      ]);
      final client = ProviderDebridClient(
        DebridService.premiumize,
        transport,
        ManualClock(),
      );

      final first = await client.resolve('account-one', hashA, episode: 1);
      final second = await client.resolve('account-one', hashA, episode: 2);

      expect(transport.requests, hasLength(1));
      expect(first.target?.name, 'Show - 01.mkv');
      expect(second.target?.name, 'Show - 02.mkv');
      expect(first.files.first.infoHash, hashA);
      expect(
        first.files.first.fileHash,
        '8168f4f3cd25e8841d3e21ec09ebe8175617771a',
      );
      expect(first.files.first.torrentName, 'Show');
      expect(first.files.first.path, '/Show/Show - 01.mkv');

      await client.forgetResolved('account-one', hashA);
      await client.resolve('account-one', hashA, episode: 1);
      expect(transport.requests, hasLength(2));
    },
  );

  test(
    'provider memory and signed links never cross API-key accounts',
    () async {
      final transport = MockTransport([
        Route.json(
          '/cache/check',
          200,
          jsonEncode({
            'status': 'success',
            'response': [true],
          }),
        ),
      ]);
      final client = ProviderDebridClient(
        DebridService.premiumize,
        transport,
        ManualClock(),
      );

      await client.availability('first-key', [hashA]);
      await client.availability('first-key', [hashA]);
      await client.availability('second-key', [hashA]);

      expect(transport.requests, hasLength(2));
      expect(
        transport.requests[0].headers['Authorization'],
        'Bearer first-key',
      );
      expect(
        transport.requests[1].headers['Authorization'],
        'Bearer second-key',
      );
      expect(
        transport.requests.every(
          (request) => !request.url.toString().contains('key'),
        ),
        isTrue,
      );
    },
  );
}
