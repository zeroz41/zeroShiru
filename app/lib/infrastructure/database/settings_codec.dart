/// Settings <-> JSON, plus copyWith. The Settings model in domain/ is an
/// immutable const schema, so the mutation and serialization helpers live
/// here in infrastructure.
///
/// Standing contract: API keys are never ordinary settings entries. That is
/// structural — [SettingsJson.toJson] simply has no `debridApiKeys` field, so
/// nothing that serializes Settings can leak a key into the kv table. Keys
/// live in the CredentialStore (OS keyring) and are joined back in memory by
/// the application layer via [SettingsJson.copyWith].
library;

import '../../domain/models/debrid_route.dart';
import '../../domain/models/settings.dart';
import '../../domain/ports/debrid_client.dart';

const Object _unset = Object();

extension SettingsJson on Settings {
  /// Everything persistable. Deliberately absent: `debridApiKeys`.
  Map<String, dynamic> toJson() => {
    'titleLanguage': titleLanguage,
    'cardSize': cardSize,
    'adultContent': adultContent,
    'preferDubs': preferDubs,
    'volume': volume,
    'playerAutoplay': playerAutoplay,
    'playerPauseOnLostFocus': playerPauseOnLostFocus,
    'playerAutocomplete': playerAutocomplete,
    'playerAutocompleteThreshold': playerAutocompleteThreshold,
    'playerSeekStep': playerSeekStep,
    'playerChapterSkip': playerChapterSkip,
    'enableExternalPlayer': enableExternalPlayer,
    'externalPlayerPath': externalPlayerPath,
    'audioLanguage': audioLanguage,
    'subtitleLanguage': subtitleLanguage,
    'rssQuality': rssQuality,
    'rssAutoplay': rssAutoplay,
    'torrentSort': torrentSort,
    'torrentAutoScrape': torrentAutoScrape,
    'debridService': debridService?.name,
    'debridMode': debridMode.name,
    'debridCachedOnly': debridCachedOnly,
    'debridCacheCheck': debridCacheCheck,
    'torrentSpeedBytes': torrentSpeedBytes,
    'torrentPersist': torrentPersist,
    'torrentStreamedDownload': torrentStreamedDownload,
    'maxConnections': maxConnections,
    'seedingLimit': seedingLimit,
    'torrentPath': torrentPath,
  };

  /// Field-wise copy. `debridService` distinguishes "leave alone" (omitted)
  /// from "clear" (explicit null) via a sentinel.
  Settings copyWith({
    String? titleLanguage,
    String? cardSize,
    String? adultContent,
    bool? preferDubs,
    double? volume,
    bool? playerAutoplay,
    bool? playerPauseOnLostFocus,
    bool? playerAutocomplete,
    int? playerAutocompleteThreshold,
    int? playerSeekStep,
    String? playerChapterSkip,
    bool? enableExternalPlayer,
    String? externalPlayerPath,
    String? audioLanguage,
    String? subtitleLanguage,
    String? rssQuality,
    bool? rssAutoplay,
    String? torrentSort,
    bool? torrentAutoScrape,
    Object? debridService = _unset,
    Map<DebridService, String>? debridApiKeys,
    DebridMode? debridMode,
    bool? debridCachedOnly,
    bool? debridCacheCheck,
    int? torrentSpeedBytes,
    bool? torrentPersist,
    bool? torrentStreamedDownload,
    int? maxConnections,
    int? seedingLimit,
    String? torrentPath,
  }) {
    return Settings(
      titleLanguage: titleLanguage ?? this.titleLanguage,
      cardSize: cardSize ?? this.cardSize,
      adultContent: adultContent ?? this.adultContent,
      preferDubs: preferDubs ?? this.preferDubs,
      volume: volume ?? this.volume,
      playerAutoplay: playerAutoplay ?? this.playerAutoplay,
      playerPauseOnLostFocus:
          playerPauseOnLostFocus ?? this.playerPauseOnLostFocus,
      playerAutocomplete: playerAutocomplete ?? this.playerAutocomplete,
      playerAutocompleteThreshold:
          playerAutocompleteThreshold ?? this.playerAutocompleteThreshold,
      playerSeekStep: playerSeekStep ?? this.playerSeekStep,
      playerChapterSkip: playerChapterSkip ?? this.playerChapterSkip,
      enableExternalPlayer: enableExternalPlayer ?? this.enableExternalPlayer,
      externalPlayerPath: externalPlayerPath ?? this.externalPlayerPath,
      audioLanguage: audioLanguage ?? this.audioLanguage,
      subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
      rssQuality: rssQuality ?? this.rssQuality,
      rssAutoplay: rssAutoplay ?? this.rssAutoplay,
      torrentSort: torrentSort ?? this.torrentSort,
      torrentAutoScrape: torrentAutoScrape ?? this.torrentAutoScrape,
      debridService: identical(debridService, _unset)
          ? this.debridService
          : debridService as DebridService?,
      debridApiKeys: debridApiKeys ?? this.debridApiKeys,
      debridMode: debridMode ?? this.debridMode,
      debridCachedOnly: debridCachedOnly ?? this.debridCachedOnly,
      debridCacheCheck: debridCacheCheck ?? this.debridCacheCheck,
      torrentSpeedBytes: torrentSpeedBytes ?? this.torrentSpeedBytes,
      torrentPersist: torrentPersist ?? this.torrentPersist,
      torrentStreamedDownload:
          torrentStreamedDownload ?? this.torrentStreamedDownload,
      maxConnections: maxConnections ?? this.maxConnections,
      seedingLimit: seedingLimit ?? this.seedingLimit,
      torrentPath: torrentPath ?? this.torrentPath,
    );
  }
}

/// Tolerant decode: unknown fields ignored, missing or mistyped fields fall
/// back to the schema defaults, so an old persisted blob never breaks boot.
Settings settingsFromJson(Map<String, dynamic> json) {
  const defaults = Settings();
  return Settings(
    titleLanguage: _string(json['titleLanguage'], defaults.titleLanguage),
    cardSize: _string(json['cardSize'], defaults.cardSize),
    adultContent: _string(json['adultContent'], defaults.adultContent),
    preferDubs: _bool(json['preferDubs'], defaults.preferDubs),
    volume: _double(json['volume'], defaults.volume),
    playerAutoplay: _bool(json['playerAutoplay'], defaults.playerAutoplay),
    playerPauseOnLostFocus: _bool(
      json['playerPauseOnLostFocus'],
      defaults.playerPauseOnLostFocus,
    ),
    playerAutocomplete: _bool(
      json['playerAutocomplete'],
      defaults.playerAutocomplete,
    ),
    playerAutocompleteThreshold: _int(
      json['playerAutocompleteThreshold'],
      defaults.playerAutocompleteThreshold,
    ),
    playerSeekStep: _int(json['playerSeekStep'], defaults.playerSeekStep),
    playerChapterSkip: _string(
      json['playerChapterSkip'],
      defaults.playerChapterSkip,
    ),
    enableExternalPlayer: _bool(
      json['enableExternalPlayer'],
      defaults.enableExternalPlayer,
    ),
    externalPlayerPath: _string(
      json['externalPlayerPath'],
      defaults.externalPlayerPath,
    ),
    audioLanguage: _string(json['audioLanguage'], defaults.audioLanguage),
    subtitleLanguage: _string(
      json['subtitleLanguage'],
      defaults.subtitleLanguage,
    ),
    rssQuality: _string(json['rssQuality'], defaults.rssQuality),
    rssAutoplay: _bool(json['rssAutoplay'], defaults.rssAutoplay),
    torrentSort: _string(json['torrentSort'], defaults.torrentSort),
    torrentAutoScrape: _bool(
      json['torrentAutoScrape'],
      defaults.torrentAutoScrape,
    ),
    debridService: json['debridService'] is String
        ? DebridService.values.asNameMap()[json['debridService']]
        : null,
    debridMode:
        (json['debridMode'] is String
            ? DebridMode.values.asNameMap()[json['debridMode']]
            : null) ??
        defaults.debridMode,
    debridCachedOnly: _bool(
      json['debridCachedOnly'],
      defaults.debridCachedOnly,
    ),
    debridCacheCheck: _bool(
      json['debridCacheCheck'],
      defaults.debridCacheCheck,
    ),
    torrentSpeedBytes: _int(
      json['torrentSpeedBytes'],
      defaults.torrentSpeedBytes,
    ),
    torrentPersist: _bool(json['torrentPersist'], defaults.torrentPersist),
    torrentStreamedDownload: _bool(
      json['torrentStreamedDownload'],
      defaults.torrentStreamedDownload,
    ),
    maxConnections: _int(json['maxConnections'], defaults.maxConnections),
    seedingLimit: _int(json['seedingLimit'], defaults.seedingLimit),
    torrentPath: _string(json['torrentPath'], defaults.torrentPath),
  );
}

String _string(dynamic value, String fallback) =>
    value is String ? value : fallback;
bool _bool(dynamic value, bool fallback) => value is bool ? value : fallback;
int _int(dynamic value, int fallback) =>
    value is num ? value.toInt() : fallback;
double _double(dynamic value, double fallback) =>
    value is num ? value.toDouble() : fallback;
