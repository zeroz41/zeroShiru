/// AniList-shaped media domain model — the app's lingua franca for shows.
library;

enum MediaSeason { winter, spring, summer, fall }

enum MediaFormat { tv, tvShort, movie, special, ova, ona, music, unknown }

enum MediaStatus { finished, releasing, notYetReleased, cancelled, hiatus }

enum ListStatus { current, planning, completed, dropped, paused, repeating }

class MediaTitle {
  const MediaTitle({
    this.romaji,
    this.english,
    this.native,
    this.userPreferred,
  });

  final String? romaji;
  final String? english;
  final String? native;
  final String? userPreferred;

  String get display => userPreferred ?? romaji ?? english ?? native ?? '?';
}

class AiringEpisode {
  const AiringEpisode({required this.episode, required this.airingAt});

  final int episode;
  final DateTime airingAt;
}

class ListEntry {
  const ListEntry({
    required this.status,
    required this.progress,
    this.score,
    this.repeat = 0,
    this.customLists = const [],
  });

  final ListStatus status;
  final int progress;

  /// POINT_10 scale (AniList requested with POINT_10; MAL raw 0-10).
  final double? score;
  final int repeat;
  final List<String> customLists;
}

class Media {
  const Media({
    required this.id,
    required this.title,
    this.idMal,
    this.format,
    this.status,
    this.season,
    this.seasonYear,
    this.episodes,
    this.duration,
    this.coverImage,
    this.bannerImage,
    this.coverColor,
    this.description,
    this.genres = const [],
    this.averageScore,
    this.isAdult = false,
    this.nextAiringEpisode,
    this.listEntry,
    this.synonyms = const [],
  });

  final int id;
  final int? idMal;
  final MediaTitle title;
  final MediaFormat? format;
  final MediaStatus? status;
  final MediaSeason? season;
  final int? seasonYear;

  /// Total episode count; null while unknown/releasing.
  final int? episodes;

  /// Minutes per episode.
  final int? duration;
  final String? coverImage;
  final String? bannerImage;

  /// AniList's dominant cover color, e.g. '#e4a15d'.
  final String? coverColor;
  final String? description;
  final List<String> genres;
  final int? averageScore;
  final bool isAdult;
  final AiringEpisode? nextAiringEpisode;
  final ListEntry? listEntry;
  final List<String> synonyms;

  /// Highest episode number that can currently exist.
  int? get maxEpisode =>
      episodes ??
      (nextAiringEpisode != null ? nextAiringEpisode!.episode - 1 : null);
}
