import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/infrastructure/debrid/providers/alldebrid.dart';
import 'package:zero/infrastructure/debrid/providers/provider.dart';
import 'package:zero/domain/media/filename.dart';
import 'package:zero/domain/ports/http_transport.dart';

import 'testing.dart';

const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String ok(Object? data) => jsonEncode({'status': 'success', 'data': data});

void main() {
  test('AllDebrid batch checks retain the magnet-owning caps', () {
    final config = AllDebridProvider.providerConfig;
    expect(config.availabilityCheck, AvailabilityCheck.batch);
    expect(config.checkAddsMagnets, isTrue);
    expect(config.maxAsk, 10);
    expect(config.maxBatch, 10);
  });

  test('batch checks delete only magnets that the check added', () async {
    final transport = MockTransport([
      Route.json(
        '/v4.1/magnet/status',
        200,
        ok({
          'magnets': [
            {'id': 9, 'filename': 'already mine'},
          ],
        }),
      ),
      Route.json(
        '/v4/magnet/upload',
        200,
        ok({
          'magnets': [
            {'id': 9, 'hash': hashA, 'ready': true},
            {'id': 10, 'hash': hashB, 'ready': false},
          ],
        }),
      ),
      Route.json('/v4/magnet/delete', 200, ok({'message': 'deleted'})),
    ]);
    final provider = AllDebridProvider('secret', transport, ManualClock());

    final answers = await provider.checkAvailabilityBatch([hashA, hashB]);

    expect(answers, {
      hashA: Availability.cached,
      hashB: Availability.available,
    });
    final deletes = transport.requests
        .where((request) => request.url.path.endsWith('/magnet/delete'))
        .toList();
    expect(deletes, hasLength(1));
    expect((deletes.single.body! as FormBody).fields, [('id', '10')]);
    expect(
      transport.requests.every(
        (request) => !request.url.toString().contains('secret'),
      ),
      isTrue,
    );
    expect(
      transport.requests.every(
        (request) => request.headers['Authorization'] == 'Bearer secret',
      ),
      isTrue,
    );
  });

  test(
    'resolve flattens the v4.1 tree and unlocks files concurrently',
    () async {
      final transport = ScriptTransport([
        (
          '/v4.1/magnet/status',
          (hit) => (
            200,
            hit == 0
                ? ok({'magnets': []})
                : ok({
                    'magnets': {
                      'id': 42,
                      'filename': 'Test Pack',
                      'statusCode': 4,
                      'files': [
                        {
                          'n': 'Test Pack',
                          'e': [
                            {
                              'n': 'Episode 01.mkv',
                              's': 1000,
                              'l': 'https://locked.test/one',
                            },
                            {
                              'n': 'readme.nfo',
                              's': 10,
                              'l': 'https://locked.test/readme',
                            },
                            {
                              'n': 'Episode 02.mkv',
                              's': 2000,
                              'l': 'https://locked.test/two',
                            },
                          ],
                        },
                      ],
                    },
                  }),
          ),
        ),
        (
          '/v4/magnet/upload',
          fixed(
            200,
            ok({
              'magnets': [
                {'id': 42, 'hash': hashA, 'ready': true},
              ],
            }),
          ),
        ),
        (
          'one',
          fixed(200, ok({'link': 'https://cdn.test/one', 'filesize': 1100})),
        ),
        (
          'two',
          fixed(200, ok({'link': 'https://cdn.test/two', 'filesize': 2200})),
        ),
      ]);
      final provider = AllDebridProvider('key', transport, ManualClock());

      final resolved = await provider.resolve(
        hashA,
        ResolveOptions(fileFilter: isPlaybackPath),
      );

      expect(resolved.name, 'Test Pack');
      expect(resolved.targetPath, '/Test Pack/Episode 02.mkv');
      expect(resolved.files.map((file) => file.path), [
        '/Test Pack/Episode 01.mkv',
        '/Test Pack/Episode 02.mkv',
      ]);
      expect(resolved.files.map((file) => file.size), [1100, 2200]);
      expect(
        transport.requests.where(
          (request) => request.url.path.contains('unlock'),
        ),
        hasLength(2),
      );
    },
  );
}
