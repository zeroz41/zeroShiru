import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/infrastructure/network/ssrf_guard.dart';
import 'package:zero/domain/ports/http_transport.dart';

import 'test_support.dart';

Blocked blocked(String url) {
  final reason = checkUrl(url);
  expect(
    reason,
    isNotNull,
    reason: '$url should not be reachable from page content',
  );
  return reason!;
}

void main() {
  group('checkUrl (the 11 guard.rs tests)', () {
    test('ordinary sites are reachable', () {
      for (final url in [
        'https://nyaa.si/?page=rss&q=one+piece',
        'http://feed.animetosho.org/json?q=frieren',
        'https://torrentio.strem.fun/manifest.json',
        'https://sub.domain.example.co.uk/path',
        'https://1.1.1.1/dns-query',
        'HTTPS://Example.COM/',
      ]) {
        expect(checkUrl(url), isNull, reason: url);
      }
    });

    test('only http urls are fetched', () {
      expect(blocked('file:///etc/passwd'), Blocked.scheme);
      expect(blocked('zero://localhost/app.html'), Blocked.scheme);
      expect(blocked('ftp://example.com/x'), Blocked.scheme);
      expect(blocked('javascript:alert(1)'), Blocked.scheme);
      expect(blocked('/just/a/path'), Blocked.scheme);
    });

    test('this machine is not a website', () {
      for (final url in [
        'http://localhost:8080/admin',
        'http://127.0.0.1/',
        'http://127.1.2.3/',
        'http://[::1]:9000/',
        'http://0.0.0.0/',
      ]) {
        expect(blocked(url), Blocked.private, reason: url);
      }
    });

    test('the local network is not the internet', () {
      for (final url in [
        'http://192.168.1.1/', // the router's admin page
        'http://10.0.0.5/',
        'http://172.16.4.4/',
        'http://[fd00::1]/', // unique local
        'http://100.64.0.1/', // carrier-grade NAT
      ]) {
        expect(blocked(url), Blocked.private, reason: url);
      }
    });

    test('link-local metadata services are not reachable', () {
      // where a cloud instance keeps its credentials
      expect(
        blocked('http://169.254.169.254/latest/meta-data/'),
        Blocked.private,
      );
      expect(blocked('http://[fe80::1]/'), Blocked.private);
    });

    test('names that cannot be public are refused', () {
      expect(blocked('http://printer.local/'), Blocked.private);
      expect(blocked('http://db.internal/'), Blocked.private);
      expect(blocked('http://something.onion/'), Blocked.private);
      expect(blocked('http://intranet/'), Blocked.notPublicName);
      expect(
        blocked('http://LOCALHOST./'),
        Blocked.private,
        reason: 'a trailing dot is the same name',
      );
    });

    test('userinfo cannot smuggle a host past the check', () {
      expect(blocked('http://example.com@127.0.0.1/'), Blocked.private);
      expect(blocked('http://user:pass@[::1]/'), Blocked.private);
      expect(checkUrl('http://user:pass@example.com/'), isNull);
    });

    test('a port is not part of the host', () {
      expect(checkUrl('https://example.com:8443/x'), isNull);
      expect(blocked('https://127.0.0.1:8443/x'), Blocked.private);
    });

    test('an ipv4 written as ipv6 is still that address', () {
      expect(blocked('http://[::ffff:127.0.0.1]/'), Blocked.private);
      expect(blocked('http://[::ffff:192.168.0.1]/'), Blocked.private);
    });

    test('resolved addresses are judged the same way', () {
      expect(isPublicAddress(InternetAddress('127.0.0.1')), isFalse);
      expect(isPublicAddress(InternetAddress('192.168.0.1')), isFalse);
      expect(isPublicAddress(InternetAddress('::1')), isFalse);
      expect(isPublicAddress(InternetAddress('1.1.1.1')), isTrue);
      expect(isPublicAddress(InternetAddress('2606:4700::1111')), isTrue);
    });

    test('a url with no host is refused', () {
      expect(blocked('http:///path'), Blocked.noHost);
      expect(blocked('http://:8080/'), Blocked.noHost);
    });
  });

  group('the full blocked-range table', () {
    test('v4 special ranges are private, public neighbours are not', () {
      const notPublic = [
        '0.1.2.3',
        '100.64.0.1',
        '100.127.255.255',
        '192.0.0.1',
        '192.0.2.1',
        '198.18.0.1',
        '198.19.255.255',
        '198.51.100.7',
        '203.0.113.9',
        '224.0.0.1',
        '240.0.0.1',
        '255.255.255.255',
      ];
      for (final ip in notPublic) {
        expect(isPublicAddress(InternetAddress(ip)), isFalse, reason: ip);
      }
      const public = [
        '100.128.0.1',
        '198.20.0.1',
        '9.9.9.9',
        '223.255.255.254',
        '192.1.0.1',
      ];
      for (final ip in public) {
        expect(isPublicAddress(InternetAddress(ip)), isTrue, reason: ip);
      }
    });

    test('v6 special ranges are private, public neighbours are not', () {
      const notPublic = [
        '::',
        '::1',
        'ff02::1',
        'fc00::1',
        'fdab::2',
        'fe80::5',
        '0100::1',
        '2001:db8::1',
      ];
      for (final ip in notPublic) {
        expect(isPublicAddress(InternetAddress(ip)), isFalse, reason: ip);
      }
      const public = ['2001:4860:4860::8888', '2607:f8b0::1', '2001:db9::1'];
      for (final ip in public) {
        expect(isPublicAddress(InternetAddress(ip)), isTrue, reason: ip);
      }
    });
  });

  group('GuardedHttpTransport (the net.rs redirect policy)', () {
    HttpRequest get(String url) => HttpRequest(HttpMethod.get, Uri.parse(url));
    Future<List<InternetAddress>> resolvePublicHost(String _) async => [
      InternetAddress('1.1.1.1'),
    ];
    GuardedHttpTransport guard(
      HttpTransport inner, {
      int maxBodyBytes = 8 * 1024 * 1024,
    }) => GuardedHttpTransport(
      inner,
      maxBodyBytes: maxBodyBytes,
      resolveHost: resolvePublicHost,
    );

    test(
      'a blocked destination is refused before any request is made',
      () async {
        final inner = ScriptTransport([answer(200, 'never')]);
        final guarded = guard(inner);
        await expectLater(
          guarded.send(get('http://127.0.0.1:9000/')),
          throwsA(
            isA<UrlBlockedException>()
                .having((e) => e.reason, 'reason', Blocked.private)
                .having((e) => e.redirected, 'redirected', isFalse),
          ),
        );
        expect(inner.asked, isEmpty);
      },
    );

    test('a redirect into the local network is refused', () async {
      // the ordinary way a command like this gets abused: a public URL that bounces inward
      for (final target in [
        'http://127.0.0.1:9000/',
        'http://169.254.169.254/latest/meta-data/',
      ]) {
        final inner = ScriptTransport([
          answer(302, '', headers: {'location': target}),
          answer(200, 'the metadata service'),
        ]);
        final guarded = guard(inner);
        await expectLater(
          guarded.send(get('https://example.com/')),
          throwsA(
            isA<UrlBlockedException>()
                .having((e) => e.reason, 'reason', Blocked.private)
                .having((e) => e.redirected, 'redirected', isTrue),
          ),
        );
        expect(inner.asked.length, 1, reason: 'the hop was never followed');
      }
    });

    test('a redirect to a non-http scheme is refused', () async {
      final inner = ScriptTransport([
        answer(302, '', headers: {'location': 'file:///etc/passwd'}),
      ]);
      await expectLater(
        guard(inner).send(get('https://example.com/')),
        throwsA(
          isA<UrlBlockedException>().having(
            (e) => e.reason,
            'reason',
            Blocked.scheme,
          ),
        ),
      );
    });

    test('an ordinary redirect is followed', () async {
      final inner = ScriptTransport([
        answer(302, '', headers: {'location': 'https://cdn.example.net/file'}),
        answer(200, 'the file'),
      ]);
      final response = await guard(inner).send(get('https://example.com/'));
      expect(response.status, 200);
      expect(inner.asked.length, 2);
      expect(inner.asked[1].url.toString(), 'https://cdn.example.net/file');
    });

    test('credentials are stripped before a cross-origin redirect', () async {
      final inner = ScriptTransport([
        answer(302, '', headers: {'location': 'https://files.example.net/x'}),
        answer(200, 'file'),
      ]);
      await guard(inner).send(
        HttpRequest(
          HttpMethod.get,
          Uri.parse('https://api.example.com/start'),
          headers: const {
            'authorization': 'secret',
            'cookie': 'session=secret',
            'x-client': 'Zero',
          },
        ),
      );

      expect(inner.asked[1].headers['authorization'], isNull);
      expect(inner.asked[1].headers['cookie'], isNull);
      expect(inner.asked[1].headers['x-client'], 'Zero');
    });

    test('a relative redirect resolves against the current url', () async {
      final inner = ScriptTransport([
        answer(302, '', headers: {'location': '/moved/here'}),
        answer(200, 'ok'),
      ]);
      await guard(inner).send(get('https://example.com/old'));
      expect(inner.asked[1].url.toString(), 'https://example.com/moved/here');
    });

    test('a redirect loop ends', () async {
      final inner = ScriptTransport([
        for (var i = 0; i < 20; i++)
          answer(302, '', headers: {'location': 'https://example.com/loop'}),
      ]);
      await expectLater(
        guard(inner).send(get('https://example.com/')),
        throwsA(isA<NetworkException>()),
      );
      expect(inner.asked.length, lessThanOrEqualTo(9), reason: 'max 8 hops');
    });

    test(
      'headers the transport owns are dropped, the caller\'s kept',
      () async {
        final inner = ScriptTransport([answer(200, 'ok')]);
        await guard(inner).send(
          HttpRequest(
            HttpMethod.get,
            Uri.parse('https://example.com/'),
            headers: const {
              'Host': 'evil.example',
              'content-length': '999',
              'Connection': 'keep-alive',
              'Transfer-Encoding': 'chunked',
              'upgrade': 'websocket',
              'User-Agent': 'zero',
              'Referer': 'https://example.com/',
              'Cookie': 'session=1',
              'Authorization': 'Bearer x',
              'X-Api-Key': 'y',
            },
          ),
        );
        final sent = inner.asked.single.headers;
        for (final owned in [
          'Host',
          'content-length',
          'Connection',
          'Transfer-Encoding',
          'upgrade',
        ]) {
          expect(
            sent.containsKey(owned),
            isFalse,
            reason: '$owned belongs to the connection',
          );
        }
        for (final kept in [
          'User-Agent',
          'Referer',
          'Cookie',
          'Authorization',
          'X-Api-Key',
        ]) {
          expect(
            sent.containsKey(kept),
            isTrue,
            reason: '$kept is the caller\'s business',
          );
        }
      },
    );

    test('a 303 turns the follow-up into a bodiless GET', () async {
      final inner = ScriptTransport([
        answer(303, '', headers: {'location': 'https://example.com/result'}),
        answer(200, 'ok'),
      ]);
      await guard(inner).send(
        HttpRequest(
          HttpMethod.post,
          Uri.parse('https://example.com/submit'),
          body: BytesBody(Uint8List.fromList('payload'.codeUnits)),
        ),
      );
      expect(inner.asked[1].method, HttpMethod.get);
      expect(inner.asked[1].body, isNull);
    });

    test(
      'bodies past the cap are refused, by declared length or actual size',
      () async {
        final declared = ScriptTransport([
          answer(
            200,
            'small',
            headers: {'content-length': '${9 * 1024 * 1024}'},
          ),
        ]);
        await expectLater(
          guard(declared).send(get('https://example.com/')),
          throwsA(isA<NetworkException>()),
        );

        final actual = ScriptTransport([answer(200, 'x' * 200)]);
        await expectLater(
          guard(actual, maxBodyBytes: 100).send(get('https://example.com/')),
          throwsA(isA<NetworkException>()),
        );

        final fine = ScriptTransport([answer(200, 'x' * 50)]);
        final response = await guard(
          fine,
          maxBodyBytes: 100,
        ).send(get('https://example.com/'));
        expect(response.status, 200);
      },
    );

    test('a public-looking name resolving privately is refused', () async {
      final inner = ScriptTransport([answer(200, 'never')]);
      final transport = GuardedHttpTransport(
        inner,
        resolveHost: (_) async => [InternetAddress('192.168.1.10')],
      );

      await expectLater(
        transport.send(get('https://example.com/')),
        throwsA(
          isA<UrlBlockedException>()
              .having((error) => error.reason, 'reason', Blocked.private)
              .having((error) => error.redirected, 'redirected', isFalse),
        ),
      );
      expect(inner.asked, isEmpty);
    });

    test('mixed public and private DNS answers are refused', () async {
      final inner = ScriptTransport([answer(200, 'never')]);
      final transport = GuardedHttpTransport(
        inner,
        resolveHost: (_) async => [
          InternetAddress('1.1.1.1'),
          InternetAddress('127.0.0.1'),
        ],
      );

      await expectLater(
        transport.send(get('https://example.com/')),
        throwsA(isA<UrlBlockedException>()),
      );
      expect(inner.asked, isEmpty);
    });
  });
}
