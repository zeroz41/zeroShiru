/// HttpTransport over package:http.
///
/// One request, one response. Redirects are NOT followed here — the
/// SSRF-guarded decorator (ssrf_guard.dart) owns redirect following, because
/// every hop has to be re-checked against the guard and a transport that
/// silently follows would hide the hops from it.
library;

import 'dart:async' as async;
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../domain/ports/http_transport.dart';

class PackageHttpTransport implements HttpTransport {
  PackageHttpTransport({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    final stopwatch = Stopwatch()..start();
    try {
      final streamed = await _client
          .send(_build(request))
          .timeout(request.timeout);
      // The body read shares the same budget: a server that answers headers
      // instantly and then trickles bytes forever is still a timeout.
      final body = await http.Response.fromStream(streamed)
          .timeout(request.timeout - stopwatch.elapsed);
      return HttpResponse(body.statusCode, {
        for (final entry in body.headers.entries)
          entry.key.toLowerCase(): entry.value,
      }, body.bodyBytes);
    } on async.TimeoutException {
      throw TimeoutException(stopwatch.elapsed);
    } on http.ClientException catch (error) {
      throw NetworkException(error.message);
    } on SocketException catch (error) {
      throw NetworkException(error.message);
    } on HandshakeException catch (error) {
      throw NetworkException(error.message);
    } on TlsException catch (error) {
      throw NetworkException(error.message);
    }
  }

  http.BaseRequest _build(HttpRequest request) {
    final method = request.method.name.toUpperCase();

    if (request.body case final MultipartBody multipart) {
      final built = http.MultipartRequest(method, request.url)
        ..fields.addAll(multipart.fields)
        ..headers.addAll(request.headers)
        ..followRedirects = false;
      return built;
    }

    final built = http.Request(method, request.url)..followRedirects = false;
    switch (request.body) {
      case null:
        break;
      case final BytesBody bytes:
        built.bodyBytes = bytes.bytes;
        if (bytes.contentType != null) {
          built.headers['content-type'] = bytes.contentType!;
        }
      case final FormBody form:
        built.bodyBytes = _urlEncode(form.fields);
        built.headers['content-type'] =
            'application/x-www-form-urlencoded; charset=utf-8';
      case MultipartBody():
        break; // handled above
    }
    // Caller headers win over the body's derived content-type.
    built.headers.addAll(request.headers);
    return built;
  }

  /// Repeated keys allowed — a list of pairs, urlencoded in order.
  static List<int> _urlEncode(List<(String, String)> fields) {
    final encoded = fields
        .map(
          (field) =>
              '${Uri.encodeQueryComponent(field.$1)}=${Uri.encodeQueryComponent(field.$2)}',
        )
        .join('&');
    return encoded.codeUnits;
  }

  void close() => _client.close();
}
