/// Settings <-> JSON. Immutable updates live on the domain model; persistence
/// and tolerant decoding stay here in infrastructure.
///
/// Standing contract: API keys are never ordinary settings entries. That is
/// structural — [SettingsJson.toJson] simply has no `debridApiKeys` field, so
/// nothing that serializes Settings can leak a key into the kv table. Keys
/// live in the CredentialStore (OS keyring) and are joined back in memory by
/// the application layer via [Settings.copyWith].
library;

import '../../domain/models/debrid_route.dart';
import '../../domain/models/settings.dart';
import '../../domain/ports/debrid_client.dart';

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
    'learningTranslationLanguage': learningTranslationLanguage,
    'learningAutoSelectTracks': learningAutoSelectTracks,
    'learningAutoFetchJapaneseSubtitles': learningAutoFetchJapaneseSubtitles,
    'learningShowJapanese': learningShowJapanese,
    'learningShowFurigana': learningShowFurigana,
    'learningShowRomaji': learningShowRomaji,
    'learningShowTranslation': learningShowTranslation,
    'learningPauseOnLookup': learningPauseOnLookup,
    'learningSubtitleScale': learningSubtitleScale,
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
    learningTranslationLanguage: _choiceString(
      json['learningTranslationLanguage'],
      defaults.learningTranslationLanguage,
      const {
        'eng',
        'es',
        'pt',
        'de',
        'fr',
        'it',
        'ko',
        'zh',
        'ru',
        'ar',
        'hi',
        'id',
        'pl',
        'th',
        'tr',
        'uk',
        'vi',
      },
    ),
    learningAutoSelectTracks: _bool(
      json['learningAutoSelectTracks'],
      defaults.learningAutoSelectTracks,
    ),
    learningAutoFetchJapaneseSubtitles: _bool(
      json['learningAutoFetchJapaneseSubtitles'],
      defaults.learningAutoFetchJapaneseSubtitles,
    ),
    learningShowJapanese: _bool(
      json['learningShowJapanese'],
      defaults.learningShowJapanese,
    ),
    learningShowFurigana: _bool(
      json['learningShowFurigana'],
      defaults.learningShowFurigana,
    ),
    learningShowRomaji: _bool(
      json['learningShowRomaji'],
      defaults.learningShowRomaji,
    ),
    learningShowTranslation: _bool(
      json['learningShowTranslation'],
      defaults.learningShowTranslation,
    ),
    learningPauseOnLookup: _bool(
      json['learningPauseOnLookup'],
      defaults.learningPauseOnLookup,
    ),
    learningSubtitleScale: _choiceDouble(
      json['learningSubtitleScale'],
      defaults.learningSubtitleScale,
      const [0.85, 1.0, 1.2, 1.4],
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
String _choiceString(dynamic value, String fallback, Set<String> choices) =>
    value is String && choices.contains(value) ? value : fallback;
bool _bool(dynamic value, bool fallback) => value is bool ? value : fallback;
int _int(dynamic value, int fallback) =>
    value is num ? value.toInt() : fallback;
double _double(dynamic value, double fallback) =>
    value is num ? value.toDouble() : fallback;
double _choiceDouble(dynamic value, double fallback, List<double> choices) {
  if (value is! num) return fallback;
  final decoded = value.toDouble();
  return choices.contains(decoded) ? decoded : fallback;
}
