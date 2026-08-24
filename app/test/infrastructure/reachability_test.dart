import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/infrastructure/network/reachability.dart';
import 'package:zeroshiru/infrastructure/network/transport.dart';

import 'test_support.dart';

const two = [
  'https://first.test/generate_204',
  'https://second.test/generate_204',
];

Future<Reachability> probed(
  List<Object> answers, {
  Duration timeout = minProbeTimeout,
}) => ReachabilityProbe(
  ScriptTransport(answers),
  endpoints: two,
).probe(timeout: timeout);

void main() {
  test('an empty 204 is a connection', () async {
    expect(await probed([answer(204, '')]), Reachability.online);
  });

  test('the first good answer ends the probe', () async {
    final transport = ScriptTransport([answer(204, '')]);
    expect(
      await ReachabilityProbe(transport, endpoints: two).probe(),
      Reachability.online,
    );
    expect(
      transport.asked.length,
      1,
      reason: 'the second endpoint is not worth asking',
    );
  });

  test('a second endpoint covers the first one being down', () async {
    expect(
      await probed([answer(500, 'we are unwell'), answer(204, '')]),
      Reachability.online,
    );
  });

  test('something answering instead of the endpoint is a portal', () async {
    // the shape of a hotel splash page: a 200 with a login form
    expect(
      await probed([answer(200, '<html>sign in</html>')]),
      Reachability.portal,
    );
    // and of a redirect to one
    expect(await probed([answer(302, '')]), Reachability.portal);
    // a 204 that carries a body is not the 204 that was promised
    expect(await probed([answer(204, 'injected')]), Reachability.portal);
  });

  test('a portal outranks a later dead endpoint', () async {
    final result = await probed([
      answer(200, 'sign in'),
      const NetworkException('dns'),
    ]);
    expect(
      result,
      Reachability.portal,
      reason: 'something answered; we are not offline',
    );
  });

  test('only failing to connect everywhere is offline', () async {
    final result = await probed([
      const NetworkException('dns failure'),
      const NetworkException('connection refused'),
    ]);
    expect(result, Reachability.offline);
  });

  test('a slow link is never reported as an outage', () async {
    final result = await probed([
      const TimeoutException(Duration(seconds: 2)),
      const TimeoutException(Duration(seconds: 2)),
    ]);
    expect(
      result,
      Reachability.unknown,
      reason: 'a timeout is not a measurement',
    );
  });

  test(
    'one timeout among dead endpoints still withholds the verdict',
    () async {
      final result = await probed([
        const NetworkException('dns'),
        const TimeoutException(Duration(seconds: 2)),
      ]);
      expect(
        result,
        Reachability.unknown,
        reason: 'the slow one was never answered',
      );
    },
  );

  test('endpoints that are merely broken prove nothing', () async {
    expect(
      await probed([answer(500, ''), answer(503, '')]),
      Reachability.unknown,
    );
  });

  test('an impatient caller is given the floor', () async {
    final transport = ScriptTransport([answer(204, '')]);
    await ReachabilityProbe(
      transport,
      endpoints: two,
    ).probe(timeout: const Duration(milliseconds: 300));
    expect(
      transport.asked[0].timeout,
      minProbeTimeout,
      reason: '300ms is how a slow link becomes an outage',
    );
  });

  test('a generous caller keeps its budget', () async {
    final transport = ScriptTransport([answer(204, '')]);
    await ReachabilityProbe(
      transport,
      endpoints: two,
    ).probe(timeout: const Duration(seconds: 30));
    expect(transport.asked[0].timeout, const Duration(seconds: 30));
  });

  test('the probe is never served from a cache', () async {
    final transport = ScriptTransport([answer(204, '')]);
    await ReachabilityProbe(transport, endpoints: two).probe();
    expect(transport.asked[0].headers['Cache-Control'], 'no-store, no-cache');
    expect(transport.asked[0].headers['Pragma'], 'no-cache');
  });

  test('the wire names are what the bridge promises', () {
    expect(Reachability.online.wire, 'online');
    expect(Reachability.portal.wire, 'portal');
    expect(Reachability.offline.wire, 'offline');
    expect(Reachability.unknown.wire, 'unknown');
  });

  test(
    'the production endpoints are the two connectivity checks, in order',
    () {
      expect(reachabilityEndpoints, [
        'https://cp.cloudflare.com/generate_204',
        'https://connectivitycheck.gstatic.com/generate_204',
      ]);
    },
  );
}
