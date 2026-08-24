import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/availability.dart';
import 'package:zeroshiru/infrastructure/debrid/providers/provider.dart';
import 'package:zeroshiru/infrastructure/debrid/providers/realdebrid.dart';
import 'package:zeroshiru/infrastructure/media/filename.dart';

import 'testing.dart';

const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> info(String id, String status) => {
  'id': id,
  'hash': hashA.toUpperCase(),
  'filename': 'Test Torrent',
  'status': status,
  'files': [
    {'id': 1, 'path': '/Test/Episode 01.mkv', 'bytes': 1000, 'selected': 1},
    {'id': 2, 'path': '/Test/readme.nfo', 'bytes': 10, 'selected': 1},
    {'id': 3, 'path': '/Test/Episode 02.mkv', 'bytes': 2000, 'selected': 1},
  ],
  'links': ['https://rd/link1', 'https://rd/link2', 'https://rd/link3'],
};

void main() {
  test('Real-Debrid retains probe mode and documented headroom', () {
    final config = RealDebridProvider.providerConfig;
    expect(config.availabilityCheck, AvailabilityCheck.probe);
    expect(config.checkAddsMagnets, isTrue);
    expect(config.maxAsk, 10);
    expect(config.maxConcurrent, 4);
    expect(config.reservoir, (200, 60000));
  });

  test('account listing exposes only settled availability states', () async {
    final transport = MockTransport([
      Route.json(
        '/torrents?limit=',
        200,
        jsonEncode([
          {'hash': hashA.toUpperCase(), 'status': 'downloaded'},
          {
            'hash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'status': 'downloading',
          },
          {
            'hash': 'cccccccccccccccccccccccccccccccccccccccc',
            'status': 'waiting_files_selection',
          },
        ]),
      ),
    ]);
    final provider = RealDebridProvider('key', transport, ManualClock());

    final answers = await provider.listAvailability();

    expect(answers, {
      hashA: Availability.cached,
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb': Availability.available,
    });
  });

  test('a cache probe always removes the temporary torrent', () async {
    final transport = ScriptTransport([
      ('/torrents/addMagnet', fixed(201, jsonEncode({'id': 'probe'}))),
      (
        '/torrents/info/probe',
        (hit) => (
          200,
          jsonEncode(
            info('probe', hit == 0 ? 'waiting_files_selection' : 'downloaded'),
          ),
        ),
      ),
      ('/torrents/selectFiles/probe', fixed(204, '')),
      ('/torrents/delete/probe', fixed(204, '')),
    ]);
    final provider = RealDebridProvider('key', transport, ManualClock());

    final answer = await provider.probeAvailability(hashA);

    expect(answer, Availability.cached);
    expect(
      transport.requests.where(
        (request) => request.url.path.endsWith('/torrents/delete/probe'),
      ),
      hasLength(1),
    );
  });

  test(
    'downloaded account torrents unrestrict playable files concurrently',
    () async {
      final transport = ScriptTransport([
        (
          '/torrents?limit=',
          fixed(
            200,
            jsonEncode([
              {'id': '42', 'hash': hashA.toUpperCase(), 'status': 'downloaded'},
            ]),
          ),
        ),
        ('/torrents/info/42', fixed(200, jsonEncode(info('42', 'downloaded')))),
        (
          '/unrestrict/link',
          (hit) => (
            200,
            jsonEncode({
              'filename': hit == 0 ? 'Episode 01.mkv' : 'Episode 02.mkv',
              'filesize': hit == 0 ? 1100 : 2200,
              'download': hit == 0
                  ? 'https://cdn.test/one'
                  : 'https://cdn.test/two',
              'mimeType': 'video/x-matroska',
            }),
          ),
        ),
      ]);
      final provider = RealDebridProvider('key', transport, ManualClock());

      final resolved = await provider.resolve(
        hashA,
        ResolveOptions(fileFilter: isVideoPath),
      );

      expect(resolved.hash, hashA);
      expect(resolved.targetPath, '/Test/Episode 02.mkv');
      expect(resolved.files.map((file) => file.path), [
        '/Test/Episode 01.mkv',
        '/Test/Episode 02.mkv',
      ]);
      expect(resolved.files.map((file) => file.size), [1100, 2200]);
      expect(
        transport.requests.where(
          (request) => request.url.path.endsWith('/unrestrict/link'),
        ),
        hasLength(2),
      );
    },
  );
}
