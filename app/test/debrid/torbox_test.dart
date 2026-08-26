import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/availability.dart';
import 'package:zeroshiru/infrastructure/debrid/providers/provider.dart';
import 'package:zeroshiru/infrastructure/debrid/providers/torbox.dart';
import 'package:zeroshiru/infrastructure/media/filename.dart';

import 'testing.dart';

const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String ok(Object? data) =>
    jsonEncode({'success': true, 'error': null, 'detail': 'ok', 'data': data});

Map<String, Object?> torrent({List<Map<String, Object?>>? files}) => {
  'id': 42,
  'hash': hashA.toUpperCase(),
  'name': 'Test Torrent',
  'download_state': 'completed',
  'download_finished': true,
  'download_present': true,
  'progress': 1,
  'files':
      files ??
      [
        {
          'id': 0,
          'name': 'Test/Episode 01.mkv',
          'size': 1000,
          'mimetype': 'video/x-matroska',
        },
        {'id': 1, 'name': 'Test/readme.nfo', 'size': 10},
        {
          'id': 2,
          'name': 'Test/Episode 02.mkv',
          'size': 2000,
          'mimetype': 'video/x-matroska',
        },
      ],
};

void main() {
  test('TorBox retains the measured link-burst limits', () {
    final config = TorBoxProvider.providerConfig;
    expect(config.maxFiles, 12);
    expect(config.maxBatch, 75);
    expect(config.maxConcurrent, 3);
    expect(config.minTimeMs, 200);
    expect(config.reservoir, (300, 60000));
  });

  test(
    'checkcached accepts object responses and treats omissions as fetchable',
    () async {
      final transport = MockTransport([
        Route.json(
          '/torrents/checkcached',
          200,
          ok({
            hashA: {'name': 'Canonical release'},
          }),
        ),
      ]);
      final provider = TorBoxProvider('key', transport, ManualClock());

      final answers = await provider.checkAvailabilityBatch([hashA, hashB]);

      expect(answers, {
        hashA: Availability.cached,
        hashB: Availability.available,
      });
      expect(provider.client.releaseName(hashA), 'Canonical release');
    },
  );

  test('cache inspection returns member names for episode filtering', () async {
    final transport = MockTransport([
      Route.json(
        '/torrents/checkcached',
        200,
        ok([
          {
            'hash': hashA,
            'name': 'Partial batch',
            'files': [
              {'name': 'Show/Show - 40.mkv', 'size': 1000},
              {'path': 'Show/Show - 41.mkv', 'length': 1100},
            ],
          },
        ]),
      ),
    ]);
    final provider = TorBoxProvider('key', transport, ManualClock());

    final details = await provider.inspectAvailabilityBatch([hashA, hashB]);

    expect(details[hashA]?.availability, Availability.cached);
    expect(details[hashA]?.files?.map((file) => (file.path, file.size)), [
      ('Show/Show - 40.mkv', 1000),
      ('Show/Show - 41.mkv', 1100),
    ]);
    expect(details[hashB]?.availability, Availability.available);
    expect(details[hashB]?.files, isNull);
    expect(transport.requests.single.url.queryParameters['list_files'], 'true');
  });

  test('selected pack file takes the first requestdl ticket', () async {
    final transport = MockTransport([
      Route.json('/torrents/mylist', 200, ok([torrent()])),
      Route.json('file_id=2', 200, ok('https://cdn.test/two')),
      Route.json('file_id=0', 200, ok('https://cdn.test/one')),
    ]);
    final provider = TorBoxProvider('secret-key', transport, ManualClock());

    final resolved = await provider.resolve(
      hashA,
      ResolveOptions(fileFilter: isVideoPath),
    );

    expect(resolved.targetPath, '/Test/Episode 02.mkv');
    expect(resolved.files.map((file) => file.path), ['/Test/Episode 02.mkv']);
    final links = transport.requests
        .where((request) => request.url.path.endsWith('/requestdl'))
        .toList();
    expect(links, hasLength(1));
    expect(links.first.url.queryParameters['file_id'], '2');
    expect(
      links.every(
        (request) => request.url.queryParameters['token'] == 'secret-key',
      ),
      isTrue,
    );
    final account = transport.requests.first;
    expect(account.url.toString(), isNot(contains('secret-key')));
    expect(account.headers['Authorization'], 'Bearer secret-key');
  });

  test(
    'a silent neighbor cannot hide an already playable target link',
    () async {
      final clock = ManualClock();
      final transport = MockTransport([
        Route.json(
          '/torrents/mylist',
          200,
          ok([
            torrent(
              files: [
                {'id': 0, 'name': 'Target.mkv', 'size': 2000},
                {'id': 1, 'name': 'Neighbor.mkv', 'size': 1000},
              ],
            ),
          ]),
        ),
        Route.json('file_id=0', 200, ok('https://cdn.test/target')),
        Route.pending('file_id=1'),
      ]);
      final provider = TorBoxProvider('key', transport, clock);

      final resolved = await provider.resolve(
        hashA,
        ResolveOptions(fileFilter: isVideoPath),
      );

      expect(resolved.files.map((file) => file.name), ['Target.mkv']);
      expect(
        clock.nowMs,
        lessThan(1001000),
        reason: 'optional neighbors must not hold a ready target for seconds',
      );
      expect(provider.client.health.limiter.inFlight, 0);
    },
  );
}
