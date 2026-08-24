/// Shared fakes for infrastructure tests: a manual clock and a scripted
/// transport (the Dart cousins of crates/debrid/src/testing.rs).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zeroshiru/infrastructure/network/transport.dart';

class ManualClock implements Clock {
  ManualClock([DateTime? start])
    : _now = start ?? DateTime.fromMillisecondsSinceEpoch(1700000000000);

  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration duration) {
    _now = _now.add(duration);
  }

  /// Advances the clock and yields, like the Rust ManualClock.
  @override
  Future<void> sleep(Duration duration) async {
    advance(duration);
    await Future<void>.delayed(Duration.zero);
  }
}

/// One scripted outcome per request, in the order they arrive. An exception
/// in the list is thrown; a response is returned. Records what was asked.
class ScriptTransport implements HttpTransport {
  ScriptTransport(this.answers);

  final List<Object> answers;
  final List<HttpRequest> asked = [];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    asked.add(request);
    if (answers.isEmpty) {
      throw const NetworkException('script ran out');
    }
    final answer = answers.removeAt(0);
    if (answer is HttpResponse) return answer;
    if (answer is Exception) throw answer;
    throw StateError('unscriptable answer: $answer');
  }
}

HttpResponse answer(
  int status,
  String body, {
  Map<String, String> headers = const {},
}) => HttpResponse(status, {
  for (final e in headers.entries) e.key.toLowerCase(): e.value,
}, Uint8List.fromList(utf8.encode(body)));
