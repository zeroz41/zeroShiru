/// Small, forgiving readers for provider JSON. Debrid APIs routinely drift
/// between strings, numbers, and booleans for the same field; these helpers
/// keep that tolerance explicit without spreading `dynamic` through adapters.
library;

Object? field(Object? value, String key) => value is Map ? value[key] : null;

List<Object?> jsonList(Object? value) =>
    value is List ? List<Object?>.from(value) : const [];

Map<String, Object?> jsonMap(Object? value) {
  if (value is! Map) return const {};
  return {for (final entry in value.entries) '${entry.key}': entry.value};
}

String? jsonString(Object? value) => value is String ? value : null;

String? nonEmptyString(Object? value) {
  final text = jsonString(value)?.trim();
  return text == null || text.isEmpty ? null : text;
}

String? scalarText(Object? value) => switch (value) {
  String text when text.isNotEmpty => text,
  num number => number.toString(),
  _ => null,
};

int? jsonInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text.trim()),
  _ => null,
};

double? jsonDouble(Object? value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text.trim()),
  _ => null,
};

bool jsonTruthy(Object? value) => switch (value) {
  null => false,
  false => false,
  num number => number != 0,
  String text => text.isNotEmpty,
  _ => true,
};

String rootedPath(String path) => path.startsWith('/') ? path : '/$path';

String basename(String path) => path.split('/').last;

String? isoFromUnixSeconds(Object? value) {
  final seconds = jsonInt(value);
  if (seconds == null || seconds == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * Duration.millisecondsPerSecond,
    isUtc: true,
  ).toIso8601String();
}

/// Provider detail strings are untrusted and may echo an authenticated URL.
String safeServiceMessage(String? value, String fallback) {
  final source = value?.trim();
  if (source == null || source.isEmpty) return fallback;
  final withoutUrls = source.replaceAll(
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    '[redacted-url]',
  );
  final withoutTokens = withoutUrls.replaceAllMapped(
    RegExp(
      r'(apikey|api_key|token|access_token|authorization)(\s*[:=]\s*)[^\s,;&]+',
      caseSensitive: false,
    ),
    (match) => '${match[1]}${match[2]}[redacted]',
  );
  return withoutTokens.length <= 500
      ? withoutTokens
      : '${withoutTokens.substring(0, 500)}…';
}
