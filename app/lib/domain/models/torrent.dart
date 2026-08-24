/// Source-search and playback-file shapes shared across the app.
/// Ported from frontend/extensions/index.d.ts and crates/torrent (redo branch).
library;

/// One release returned by a source.
class TorrentResult {
  const TorrentResult({
    required this.title,
    required this.link,
    this.hash,
    this.size,
    this.seeders,
    this.leechers,
    this.downloads,
    this.date,
    this.id,
    this.accuracy,
    this.type,
    this.sourceId,
  });

  final String title;

  /// Magnet link, info hash, or .torrent URL.
  final String link;
  final String? hash;
  final int? size;
  final int? seeders;
  final int? leechers;
  final int? downloads;
  final DateTime? date;
  final String? id;

  /// 'high' | 'medium' | 'low'
  final String? accuracy;

  /// 'batch' | 'best' | 'alt'
  final String? type;
  final String? sourceId;
}

/// The question asked of every enabled source.
class TorrentQuery {
  const TorrentQuery({
    required this.anilistId,
    required this.titles,
    this.episode,
    this.episodeCount,
    this.resolution = '',
    this.exclusions = const [],
    this.anidbAid,
    this.anidbEid,
    this.tvdbAid,
    this.tvdbEid,
    this.imdbId,
    this.tmdbId,
    this.idMal,
    this.season,
    this.absoluteEpisode,
  });

  final int anilistId;
  final List<String> titles;
  final int? episode;
  final int? episodeCount;

  /// '2160' | '1080' | '720' | '540' | '480' | ''
  final String resolution;
  final List<String> exclusions;
  final int? anidbAid;
  final int? anidbEid;
  final int? tvdbAid;
  final int? tvdbEid;
  final String? imdbId;
  final int? tmdbId;
  final int? idMal;
  final int? season;
  final int? absoluteEpisode;

  TorrentQuery copyWith({
    int? anidbAid,
    int? anidbEid,
    int? tvdbAid,
    int? tvdbEid,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? absoluteEpisode,
  }) => TorrentQuery(
    anilistId: anilistId,
    titles: titles,
    episode: episode,
    episodeCount: episodeCount,
    resolution: resolution,
    exclusions: exclusions,
    anidbAid: anidbAid ?? this.anidbAid,
    anidbEid: anidbEid ?? this.anidbEid,
    tvdbAid: tvdbAid ?? this.tvdbAid,
    tvdbEid: tvdbEid ?? this.tvdbEid,
    imdbId: imdbId ?? this.imdbId,
    tmdbId: tmdbId ?? this.tmdbId,
    idMal: idMal,
    season: season ?? this.season,
    absoluteEpisode: absoluteEpisode ?? this.absoluteEpisode,
  );
}

/// The universal playable-file shape, produced by both the torrent engine and
/// debrid resolution.
class PlayerFile {
  const PlayerFile({
    required this.name,
    required this.url,
    this.infoHash,
    this.fileHash,
    this.torrentName,
    this.mimeType,
    this.size,
    this.path,
  });

  final String name;

  /// Loopback gateway URL (torrent lane) or direct CDN link (debrid lane).
  /// Treated as a bearer credential: never logged, never shown.
  final String url;
  final String? infoHash;
  final String? fileHash;
  final String? torrentName;
  final String? mimeType;
  final int? size;
  final String? path;
}
