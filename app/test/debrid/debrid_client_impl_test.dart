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

  test('TorBox batch resolution targets the exact requested episode', () async {
    final files = [
      for (var episode = 1; episode <= 30; episode++)
        {
          'id': episode,
          'name': 'Batch/Show - ${episode.toString().padLeft(2, '0')}.mkv',
          'size': 1000 + episode,
          'mimetype': 'video/x-matroska',
        },
    ];
    final transport = MockTransport([
      Route.json(
        '/torrents/mylist',
        200,
        jsonEncode({
          'success': true,
          'data': [
            {
              'id': 42,
              'hash': hashA,
              'name': 'Show batch',
              'download_state': 'completed',
              'download_finished': true,
              'download_present': true,
              'progress': 1,
              'files': files,
            },
          ],
        }),
      ),
      Route.json(
        '/torrents/requestdl',
        200,
        jsonEncode({'success': true, 'data': 'https://cdn.test/video'}),
      ),
    ]);
    final client = ProviderDebridClient(
      DebridService.torbox,
      transport,
      ManualClock(),
    );

    final resolved = await client.resolve('account', hashA, episode: 23);

    expect(resolved.target?.path, '/Batch/Show - 23.mkv');
    final linkRequests = transport.requests
        .where((request) => request.url.path.endsWith('/requestdl'))
        .toList();
    expect(linkRequests, isNotEmpty);
    expect(
      linkRequests.first.url.queryParameters['file_id'],
      '23',
      reason: 'the target link is requested before optional neighbor links',
    );
  });

  test('TorBox inspection warms the account lookup used by a click', () async {
    final files = [
      {
        'id': 1,
        'name': 'Show/Show - 01.mkv',
        'size': 1000,
        'mimetype': 'video/x-matroska',
      },
    ];
    final transport = MockTransport([
      Route.json(
        '/torrents/checkcached',
        200,
        jsonEncode({
          'success': true,
          'data': [
            {'hash': hashA, 'name': 'Show', 'files': files},
          ],
        }),
      ),
      Route.json(
        '/torrents/mylist',
        200,
        jsonEncode({
          'success': true,
          'data': [
            {
              'id': 42,
              'hash': hashA,
              'name': 'Show',
              'download_state': 'completed',
              'download_finished': true,
              'download_present': true,
              'progress': 1,
              'files': files,
            },
          ],
        }),
      ),
      Route.json(
        '/torrents/requestdl',
        200,
        jsonEncode({'success': true, 'data': 'https://cdn.test/video'}),
      ),
    ]);
    final client = ProviderDebridClient(
      DebridService.torbox,
      transport,
      ManualClock(),
    );

    await client.inspectAvailability('account', [hashA]);
    final resolved = await client.resolve('account', hashA, episode: 1);

    expect(resolved.target?.path, '/Show/Show - 01.mkv');
    expect(
      transport.requests.where(
        (request) => request.url.path.endsWith('/torrents/mylist'),
      ),
      hasLength(1),
    );
    expect(
      transport.requests.where(
        (request) => request.url.path.endsWith('/torrents/checkcached'),
      ),
      hasLength(1),
    );
  });
}
