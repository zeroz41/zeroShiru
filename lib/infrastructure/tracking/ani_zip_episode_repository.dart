import 'dart:convert';

import '../../domain/models/media.dart';
import '../../domain/ports/episode_repository.dart';
import '../../domain/ports/http_transport.dart';

/// Episode artwork/title enrichment from the same AniZip mapping endpoint the
/// original app used. The adapter is deliberately tolerant of partial rows;
/// a missing field falls back to the parent media in the feature layer.
class AniZipEpisodeRepository implements EpisodeRepository {
  const AniZipEpisodeRepository(this._transport);

  final HttpTransport _transport;

  @override
  Future<List<EpisodeInfo>> episodes(Media media) async {
    final response = await _transport.send(
      HttpRequest(
        HttpMethod.get,
        Uri.https('api.ani.zip', '/mappings', {'anilist_id': '${media.id}'}),
        headers: const {'accept': 'application/json'},
        timeout: const Duration(seconds: 12),
      ),
    );
    if (!response.ok) {
      throw StateError('episode mapping request failed (${response.status})');
    }
    final root = jsonDecode(utf8.decode(response.bodyBytes));
    if (root is! Map) return const [];
    final rawEpisodes = root['episodes'];
    if (rawEpisodes is! Map) return const [];

    final byNumber = <int, Map>{};
    for (final entry in rawEpisodes.entries) {
      if (entry.value is! Map) continue;
      final row = entry.value as Map;
      final number =
          _integer(row['episodeNumber']) ?? _episodeKey(entry.key.toString());
      if (number == null || number < 1) continue;
      byNumber.putIfAbsent(number, () => row);
    }
    final reportedCount = _integer(root['episodeCount']) ?? 0;
    final mappedCount = byNumber.keys.fold(
      0,
      (max, item) => item > max ? item : max,
    );
    final count = [
      media.maxEpisode ?? 0,
      reportedCount,
      mappedCount,
    ].reduce((a, b) => a > b ? a : b);
    if (count <= 0) return const [];

    return [
      for (var number = 1; number <= count; number++)
        _episodeInfo(number, byNumber[number], media),
    ];
  }
}

EpisodeInfo _episodeInfo(int number, Map? row, Media media) {
  final title = _episodeTitle(row?['title'], media);
  return EpisodeInfo(
    number: number,
    title: title,
    summary: _text(row?['overview']) ?? _text(row?['summary']),
    imageUrl:
        _text(row?['image']) ??
        _text(row?['thumbnail']) ??
        media.bannerImage ??
        media.coverImage,
    durationMinutes:
        _integer(row?['runtime']) ?? _integer(row?['length']) ?? media.duration,
    airDate: _date(row?['airDate']) ?? _date(row?['airdate']),
    rating: _decimal(row?['rating']),
  );
}

String? _episodeTitle(Object? value, Media media) {
  final title = _title(value);
  if (title == null) return null;
  final normalized = _normalizedTitle(title);
  final seriesTitles = [
    media.title.userPreferred,
    media.title.english,
    media.title.romaji,
    media.title.native,
  ].whereType<String>().map(_normalizedTitle);
  return seriesTitles.contains(normalized) ? null : title;
}

String? _title(Object? value) {
  if (value is Map) {
    return _text(value['en']) ??
        _text(value['ja']) ??
        _text(value['jp']) ??
        _text(value['x-jat']);
  }
  return _text(value);
}

String _normalizedTitle(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int? _integer(Object? value) {
  if (value is num) return value.round();
  return value is String ? num.tryParse(value)?.round() : null;
}

double? _decimal(Object? value) {
  if (value is num) return value.toDouble();
  return value is String ? double.tryParse(value) : null;
}

int? _episodeKey(String key) {
  final normalized = key.startsWith('O') ? key.substring(1) : key;
  return _integer(normalized);
}

DateTime? _date(Object? value) {
  final text = _text(value);
  return text == null ? null : DateTime.tryParse(text)?.toLocal();
}
