/// Exercises the package:http-backed transport against a loopback server —
/// no live network is touched.
library;

import 'dart:async' as async;
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/infrastructure/network/http_transport_impl.dart';
import 'package:zero/domain/ports/http_transport.dart';

void main() {
  late io.HttpServer server;
  late PackageHttpTransport transport;
  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  setUp(() async {
    server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    transport = PackageHttpTransport();
  });

  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });

  void serve(Future<void> Function(io.HttpRequest) handler) {
    server.listen((request) {
      handler(request).catchError((Object _) {});
    });
  }

  test('a GET roundtrips status, body and lowercased headers', () async {
    serve((request) async {
      request.response
        ..statusCode = 201
        ..headers.set('X-Custom-Header', 'VALUE')
        ..write('the body');
      await request.response.close();
    });
    final response = await transport.send(
      HttpRequest(HttpMethod.get, url('/thing')),
    );
    expect(response.status, 201);
    expect(response.ok, isTrue);
    expect(utf8.decode(response.bodyBytes), 'the body');
    expect(response.headers['x-custom-header'], 'VALUE');
    expect(response.header('X-CUSTOM-HEADER'), 'VALUE');
  });

  test('request headers and method arrive as sent', () async {
    late String method;
    String? apiKey;
    serve((request) async {
      method = request.method;
      apiKey = request.headers.value('x-api-key');
      await request.response.close();
    });
    await transport.send(
      HttpRequest(
        HttpMethod.delete,
        url('/x'),
        headers: const {'X-Api-Key': 'k123'},
      ),
    );
    expect(method, 'DELETE');
    expect(apiKey, 'k123');
  });

  test('a BytesBody is sent verbatim with its content type', () async {
    late String contentType;
    late String body;
    serve((request) async {
      contentType = request.headers.contentType.toString();
      body = await utf8.decoder.bind(request).join();
      await request.response.close();
    });
    await transport.send(
      HttpRequest(
        HttpMethod.post,
        url('/x'),
        body: BytesBody(
          Uint8List.fromList(utf8.encode('{"a":1}')),
          contentType: 'application/json',
        ),
      ),
    );
    expect(contentType, contains('application/json'));
    expect(body, '{"a":1}');
  });

  test('a FormBody urlencodes, repeated keys allowed', () async {
    late String contentType;
    late String body;
    serve((request) async {
      contentType = request.headers.contentType.toString();
      body = await utf8.decoder.bind(request).join();
      await request.response.close();
    });
    await transport.send(
      HttpRequest(
        HttpMethod.post,
        url('/x'),
        body: const FormBody([
          ('magnets[]', 'magnet:?xt=urn:btih:aaa'),
          ('magnets[]', 'magnet:?xt=urn:btih:bbb'),
          ('agent', 'zero zero'),
        ]),
      ),
    );
    expect(contentType, contains('application/x-www-form-urlencoded'));
    final pairs = body.split('&');
    expect(pairs, hasLength(3));
    expect(pairs[0], startsWith('magnets%5B%5D='));
    expect(pairs[1], startsWith('magnets%5B%5D='));
    expect(Uri.splitQueryString(body)['agent'], 'zero zero');
  });

  test(
    'a MultipartBody is sent as multipart/form-data with its fields',
    () async {
      late String contentType;
      late String body;
      serve((request) async {
        contentType = request.headers.contentType.toString();
        body = await utf8.decoder.bind(request).join();
        await request.response.close();
      });
      await transport.send(
        HttpRequest(
          HttpMethod.post,
          url('/x'),
          body: const MultipartBody({'src': 'magnet:?xt=x', 'dest': 'cloud'}),
        ),
      );
      expect(contentType, contains('multipart/form-data'));
      expect(body, contains('name="src"'));
      expect(body, contains('magnet:?xt=x'));
      expect(body, contains('name="dest"'));
    },
  );

  test(
    'redirects are not followed here — the guard decorator owns them',
    () async {
      serve((request) async {
        request.response
          ..statusCode = 302
          ..headers.set('location', 'http://127.0.0.1:${server.port}/next');
        await request.response.close();
      });
      final response = await transport.send(
        HttpRequest(HttpMethod.get, url('/')),
      );
      expect(response.status, 302);
      expect(response.header('location'), isNotNull);
    },
  );

  test('a server that never answers is a TimeoutException carrying the elapsed time', () async {
    serve((request) async {
      // never respond; hold the connection open
      await async.Completer<void>().future;
    });
    try {
      await transport.send(
        HttpRequest(
          HttpMethod.get,
          url('/slow'),
          timeout: const Duration(milliseconds: 200),
        ),
      );
      fail('expected a TimeoutException');
    } on TimeoutException catch (error) {
      expect(
        error.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
    }
  });

  test('a refused connection is a NetworkException', () async {
    final port = server.port;
    await server.close(force: true);
    server = await io.HttpServer.bind(
      io.InternetAddress.loopbackIPv4,
      0,
    ); // keep tearDown happy
    await expectLater(
      transport.send(
        HttpRequest(HttpMethod.get, Uri.parse('http://127.0.0.1:$port/')),
      ),
      throwsA(isA<NetworkException>()),
    );
  });

  test('HEAD answers with headers and no body', () async {
    serve((request) async {
      request.response.headers.set('x-len', '5');
      await request.response.close();
    });
    final response = await transport.send(
      HttpRequest(HttpMethod.head, url('/')),
    );
    expect(response.header('x-len'), '5');
    expect(response.bodyBytes, isEmpty);
  });
}
