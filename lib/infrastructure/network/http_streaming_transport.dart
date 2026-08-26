import 'dart:async' as async;
import 'dart:io';

import '../../domain/ports/http_transport.dart';

/// Open-ended HTTP transport used only for media-stream health probes.
///
/// It uses dart:io directly so cancellation aborts exactly one range request;
/// closing the shared package:http client would also kill unrelated AniList
/// and debrid work.
class IoStreamingTransport implements StreamingTransport {
  IoStreamingTransport() : _client = HttpClient()..autoUncompress = false;

  final HttpClient _client;

  @override
  Future<StreamedResponse> open(HttpRequest request) async {
    final started = Stopwatch()..start();
    HttpClientRequest? pending;
    try {
      pending = await _client
          .openUrl(request.method.name.toUpperCase(), request.url)
          .timeout(request.timeout);
      pending.followRedirects = false;
      for (final entry in request.headers.entries) {
        pending.headers.set(entry.key, entry.value);
      }
      final remaining = request.timeout - started.elapsed;
      if (remaining <= Duration.zero) {
        pending.abort();
        throw TimeoutException(started.elapsed);
      }
      final response = await pending.close().timeout(remaining);
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      return StreamedResponse(
        status: response.statusCode,
        headers: headers,
        body: response,
        cancel: () => pending?.abort(),
      );
    } on async.TimeoutException {
      pending?.abort();
      throw TimeoutException(started.elapsed);
    } on SocketException catch (error) {
      pending?.abort();
      throw NetworkException(error.message);
    } on HandshakeException catch (error) {
      pending?.abort();
      throw NetworkException(error.message);
    } on TlsException catch (error) {
      pending?.abort();
      throw NetworkException(error.message);
    }
  }

  void close() => _client.close(force: true);
}
