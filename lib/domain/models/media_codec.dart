/// JSON snapshot codec for [Media].
///
/// Durable local stores (watch history) persist the show a user actually
/// played so rails can render it instantly and offline, without re-asking the
/// catalog. The tracker list entry is account state rather than show
/// metadata, so it is not part of the snapshot; readers overlay their own
/// progress source.
library;

import 'media.dart';

Map<String, Object?> mediaToJson(Media media) => {
  'id': media.id,
  'idMal': media.idMal,
  'title': {
    'romaji': media.title.romaji,
    'english': media.title.english,
    'native': media.title.native,
    'userPreferred': media.title.userPreferred,
  },
  'format': media.format?.name,
  'status': media.status?.name,
  'season': media.season?.name,
  'seasonYear': media.seasonYear,
  'episodes': media.episodes,
  'duration': media.duration,
  'coverImage': media.coverImage,
  'bannerImage': media.bannerImage,
  'coverColor': media.coverColor,
  'description': media.description,
  'genres': media.genres,
  'averageScore': media.averageScore,
  'isAdult': media.isAdult,
  'nextAiringEpisode': media.nextAiringEpisode == null
      ? null
      : {
          'episode': media.nextAiringEpisode!.episode,
          'airingAt': media.nextAiringEpisode!.airingAt.millisecondsSinceEpoch,
        },
  'synonyms': media.synonyms,
  'studios': media.studios,
  'sourceMaterial': media.sourceMaterial,
};

Media? mediaFromJson(Object? value) {
  if (value is! Map) return null;
  final id = value['id'];
  if (id is! int) return null;
  final title = value['title'];
  final airing = value['nextAiringEpisode'];
  final airingEpisode = airing is Map ? airing['episode'] : null;
  final airingAt = airing is Map ? airing['airingAt'] : null;
  return Media(
    id: id,
    idMal: value['idMal'] as int?,
    title: title is Map
        ? MediaTitle(
            romaji: title['romaji'] as String?,
            english: title['english'] as String?,
            native: title['native'] as String?,
            userPreferred: title['userPreferred'] as String?,
          )
        : const MediaTitle(),
    format: _enumByName(MediaFormat.values, value['format']),
    status: _enumByName(MediaStatus.values, value['status']),
    season: _enumByName(MediaSeason.values, value['season']),
    seasonYear: value['seasonYear'] as int?,
    episodes: value['episodes'] as int?,
    duration: value['duration'] as int?,
    coverImage: value['coverImage'] as String?,
    bannerImage: value['bannerImage'] as String?,
    coverColor: value['coverColor'] as String?,
    description: value['description'] as String?,
    genres: _stringList(value['genres']),
    averageScore: value['averageScore'] as int?,
    isAdult: value['isAdult'] == true,
    nextAiringEpisode: airingEpisode is int && airingAt is int
        ? AiringEpisode(
            episode: airingEpisode,
            airingAt: DateTime.fromMillisecondsSinceEpoch(airingAt),
          )
        : null,
    synonyms: _stringList(value['synonyms']),
    studios: _stringList(value['studios']),
    sourceMaterial: value['sourceMaterial'] as String?,
  );
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

List<String> _stringList(Object? value) =>
    value is List ? value.whereType<String>().toList(growable: false) : const [];
