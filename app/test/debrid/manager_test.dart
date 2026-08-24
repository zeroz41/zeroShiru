import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/availability.dart';
import 'package:zeroshiru/domain/ports/debrid_client.dart';
import 'package:zeroshiru/infrastructure/debrid/client.dart';
import 'package:zeroshiru/infrastructure/debrid/errors.dart';
import 'package:zeroshiru/infrastructure/debrid/manager.dart';
import 'package:zeroshiru/infrastructure/debrid/providers/provider.dart';
import 'package:zeroshiru/infrastructure/network/transport.dart';

import 'testing.dart' as support;

const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const hashC = 'cccccccccccccccccccccccccccccccccccccccc';

void main() {
  test(
    'batch chunks answer concurrently and remembered answers are free',
    () async {
      final clock = support.ManualClock();
      final provider = FakeProvider(
        _config(availability: AvailabilityCheck.batch, maxBatch: 2),
        clock,
      );
      provider.batch = (hashes, _) async {
        provider.batchCalls.add(List.of(hashes));
        return {for (final hash in hashes) hash: Availability.cached};
      };
      final managed = ManagedDebridProvider(provider);

      final first = await managed.checkAvailability([hashA, hashB, hashC]);
      final second = await managed.checkAvailability([hashA, hashB, hashC]);

      expect(first, {
        hashA: Availability.cached,
        hashB: Availability.cached,
        hashC: Availability.cached,
      });
      expect(second, first);
      expect(provider.batchCalls, [
        [hashA, hashB],
        [hashC],
      ]);
    },
  );

  test('cancelling a magnet-owning sweep releases every claim', () async {
    final clock = support.ManualClock();
    final provider = FakeProvider(
      _config(availability: AvailabilityCheck.probe, checkAddsMagnets: true),
      clock,
    );
    final parked = Completer<Availability>();
    provider.probe = (_, cancel) => raced(parked.future, cancel);
    final managed = ManagedDebridProvider(provider);
    final cancel = CancelToken();

    final checking = managed.checkAvailability([
      hashA,
      hashB,
      hashC,
    ], cancel: cancel);
    final expectation = expectLater(
      checking,
      throwsA(isA<CancelledException>()),
    );
    await support.pumpEventQueue();
    expect(managed.sweeping, isTrue);
    expect(managed.unknownHashes([hashA, hashB, hashC]), isEmpty);

    cancel.cancel();
    await expectation;

    expect(managed.sweeping, isFalse);
    expect(managed.unknownHashes([hashA, hashB, hashC]), [hashA, hashB, hashC]);
  });

  test(
    'probe failures only become answers when they prove availability',
    () async {
      final provider = FakeProvider(
        _config(availability: AvailabilityCheck.probe, checkAddsMagnets: true),
        support.ManualClock(),
      );
      provider.probe = (hash, _) async => switch (hash) {
        hashA => throw const DebridFailure.notCached(),
        hashB => throw const DebridFailure.unavailable(),
        _ => throw const DebridFailure.timeout('no answer'),
      };
      final managed = ManagedDebridProvider(provider);

      final answers = await managed.checkAvailability([hashA, hashB, hashC]);

      expect(answers, {
        hashA: Availability.available,
        hashB: Availability.unavailable,
      });
      expect(managed.unknownHashes([hashA, hashB, hashC]), [hashC]);
    },
  );

  test('manager enforces HTTPS even when a provider forgets', () async {
    final provider = FakeProvider(_config(), support.ManualClock());
    provider.resolveResult = ResolvedFiles(
      hash: hashA,
      name: 'Show',
      files: const [
        DebridFileInfo(
          name: 'bad.mkv',
          path: '/bad.mkv',
          size: 1,
          url: 'http://cdn.test/bad',
        ),
        DebridFileInfo(
          name: 'good.mkv',
          path: '/good.mkv',
          size: 2,
          url: 'https://cdn.test/good',
        ),
      ],
      targetPath: '/good.mkv',
    );

    final resolved = await ManagedDebridProvider(provider)
        .resolve(hashA, const ResolveOptions());

    expect(resolved.files.map((file) => file.name), ['good.mkv']);
  });

  test('an end-to-end deadline cancels a silent provider', () async {
    final provider = FakeProvider(
      _config(resolveMs: 1000),
      support.ManualClock(),
    );
    final parked = Completer<ResolvedFiles>();
    provider.resolveCall = (_, _, cancel) => raced(parked.future, cancel);

    await expectLater(
      ManagedDebridProvider(provider).resolve(hashA, const ResolveOptions()),
      throwsA(
        isA<DebridFailure>().having(
          (error) => error.kind,
          'kind',
          DebridErrorKind.timeout,
        ),
      ),
    );
  });
}

ProviderConfig _config({
  AvailabilityCheck availability = AvailabilityCheck.none,
  bool checkAddsMagnets = false,
  int maxBatch = 100,
  int resolveMs = 60000,
}) => ProviderConfig(
  id: 'fake',
  title: 'Fake Debrid',
  auth: AuthScheme.bearer,
  authParam: 'key',
  encoding: BodyEncoding.form,
  timeouts: Timeouts(resolveMs: resolveMs),
  nominalLatencyMs: 300,
  maxFiles: 12,
  availabilityCheck: availability,
  checkAddsMagnets: checkAddsMagnets,
  maxBatch: maxBatch,
  maxProbes: 10,
  maxConcurrent: 3,
  minTimeMs: 0,
);

class FakeProvider implements DebridProvider {
  FakeProvider(this.config, Clock clock)
    : client = DebridApiClient(config, 'key', _UnusedTransport(), clock);

  @override
  final ProviderConfig config;

  @override
  final DebridApiClient client;

  final List<List<String>> batchCalls = [];
  Future<Map<String, Availability>> Function(List<String>, CancelToken?)? batch;
  Future<Availability> Function(String, CancelToken?)? probe;
  Future<ResolvedFiles> Function(String, ResolveOptions, CancelToken?)?
  resolveCall;
  ResolvedFiles? resolveResult;

  @override
  Future<AccountInfo> validate({CancelToken? cancel}) async =>
      const AccountInfo(username: 'fake');

  @override
  Future<Map<String, Availability>> listAvailability({
    CancelToken? cancel,
  }) async => const {};

  @override
  Future<Map<String, Availability>> checkAvailabilityBatch(
    List<String> hashes, {
    CancelToken? cancel,
  }) => batch?.call(hashes, cancel) ?? Future.value(const {});

  @override
  Future<Availability> probeAvailability(String hash, {CancelToken? cancel}) =>
      probe?.call(hash, cancel) ?? Future.value(Availability.unknown);

  @override
  Future<ResolvedFiles> resolve(
    String magnet,
    ResolveOptions opts, {
    CancelToken? cancel,
  }) =>
      resolveCall?.call(magnet, opts, cancel) ??
      Future.value(
        resolveResult ??
            ResolvedFiles(hash: hashA, name: 'fake', files: const []),
      );

  @override
  Future<void> retryCleanup() async {}

  @override
  bool throttled(DebridFailure error) => error.throttled;
}

class _UnusedTransport implements HttpTransport {
  @override
  Future<HttpResponse> send(HttpRequest request) =>
      Future.error(const NetworkException('unexpected request'));
}
