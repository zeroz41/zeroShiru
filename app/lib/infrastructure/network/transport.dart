/// The HTTP seam the service layer is written against (mirrors the old
/// crates/networking abstraction). Every provider test injects a mock of
/// this; production backs it with package:http.
library;

import 'dart:typed_data';

enum HttpMethod { get, post, put, delete, patch, head }

sealed class HttpBody {
  const HttpBody();
}

class BytesBody extends HttpBody {
  const BytesBody(this.bytes, {this.contentType});

  final Uint8List bytes;
  final String? contentType;
}

class FormBody extends HttpBody {
  const FormBody(this.fields);

  /// Repeated keys allowed — list of pairs, urlencoded.
  final List<(String, String)> fields;
}

class MultipartBody extends HttpBody {
  const MultipartBody(this.fields);

  final Map<String, String> fields;
}

class HttpRequest {
  const HttpRequest(
    this.method,
    this.url, {
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 30),
  });

  final HttpMethod method;
  final Uri url;
  final Map<String, String> headers;
  final HttpBody? body;
  final Duration timeout;
}

class HttpResponse {
  const HttpResponse(this.status, this.headers, this.bodyBytes);

  final int status;

  /// Lowercased keys.
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  String? header(String name) => headers[name.toLowerCase()];
  bool get ok => status >= 200 && status < 300;
}

sealed class TransportException implements Exception {
  const TransportException();
}

class NetworkException extends TransportException {
  const NetworkException([this.message = 'network error']);

  final String message;
}

class TimeoutException extends TransportException {
  const TimeoutException(this.elapsed);

  final Duration elapsed;
}

/// One request, one response. No retries, no auth, no redirect re-checking —
/// those live in the layers above (client policy) or below (SSRF-guarded
/// transport decorator).
abstract interface class HttpTransport {
  Future<HttpResponse> send(HttpRequest request);
}

/// Injectable clock so time-based policy (quiet-service state, limiter
/// windows, TTLs) is testable without wall time.
abstract interface class Clock {
  DateTime now();
  Future<void> sleep(Duration duration);
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Future<void> sleep(Duration duration) => Future.delayed(duration);
}
