import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/ports/debrid_client.dart';
import 'package:zero/infrastructure/debrid/providers/premiumize.dart';
import 'package:zero/infrastructure/debrid/providers/provider.dart';
import 'package:zero/domain/media/filename.dart';
import 'package:zero/domain/ports/http_transport.dart';

import 'testing.dart';

const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  test('Premiumize uses its measured provider limits', () {
    final config = PremiumizeProvider.providerConfig;
    expect(config.id, 'premiumize');
    expect(config.availabilityCheck, AvailabilityCheck.batch);
    expect(config.checkAddsMagnets, isFalse);
    expect(config.maxBatch, 100);
    expect(config.maxConcurrent, 3);
    expect(config.minTimeMs, 250);
  });

  test(
    'cache answers stay positional and the key only travels as a header',
    () async {
      final transport = MockTransport([
        Route.json(
          '/cache/check',
          200,
          jsonEncode({
            'status': 'success',
            'response': [true, false],
          }),
        ),
      ]);
      final provider = PremiumizeProvider(
        'secret-key',
        transport,
        ManualClock(),
      );

      final answers = await provider.checkAvailabilityBatch([hashA, hashB]);

      expect(answers, {
        hashA: Availability.cached,
        hashB: Availability.available,
      });
      final request = transport.requests.single;
      expect(request.url.toString(), isNot(contains('secret-key')));
      expect(request.headers['Authorization'], 'Bearer secret-key');
      final body = request.body! as FormBody;
      expect(body.fields, [
        ('items[]', 'magnet:?xt=urn:btih:$hashA'),
        ('items[]', 'magnet:?xt=urn:btih:$hashB'),
      ]);
    },
  );

  test(
    'directdl produces rooted secure files and keeps the selected target',
    () async {
      final transport = MockTransport([
        Route.json(
          '/transfer/directdl',
          200,
          jsonEncode({
            'status': 'success',
            'content': [
              {
                'path': 'Show/Episode 01.mkv',
                'size': 1000,
                'link': 'https://cdn.test/one',
              },
              {
                'path': 'Show/readme.nfo',
                'size': 10,
                'link': 'https://cdn.test/readme',
              },
              {
                'path': 'Show/Episode 02.mkv',
                'size': '2000',
                'link': 'https://cdn.test/two',
              },
            ],
          }),
        ),
      ]);
      final provider = PremiumizeProvider('key', transport, ManualClock());

      final resolved = await provider.resolve(
        hashA,
        ResolveOptions(fileFilter: isPlaybackPath, pickFile: (files) => 1),
      );

      expect(resolved.hash, hashA);
      expect(resolved.name, 'Show');
      expect(resolved.files.map((file) => file.path), [
        '/Show/Episode 01.mkv',
        '/Show/Episode 02.mkv',
      ]);
      expect(resolved.targetPath, '/Show/Episode 02.mkv');
      expect(resolved.files.last.size, 2000);
    },
  );

  test(
    'permanent Premiumize failures become proven unavailable answers',
    () async {
      final transport = MockTransport([
        Route.json(
          '/transfer/directdl',
          200,
          jsonEncode({
            'status': 'error',
            'code': 'service_unsupported',
            'message': 'no',
          }),
        ),
      ]);
      final provider = PremiumizeProvider('key', transport, ManualClock());

      await expectLater(
        provider.resolve(hashA, const ResolveOptions()),
        throwsA(
          isA<DebridException>().having(
            (error) => error.kind,
            'kind',
            DebridErrorKind.unavailable,
          ),
        ),
      );
    },
  );
}
