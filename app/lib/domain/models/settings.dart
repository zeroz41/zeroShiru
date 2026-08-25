import '../ports/debrid_client.dart';
import 'debrid_route.dart';

const Object _unsetSetting = Object();

/// Typed application settings with the redo branch's defaults. Persisted as a
/// keyed map by SettingsRepository; this class is the schema.
class Settings {
  const Settings({
    // Interface
    this.titleLanguage = 'romaji',
    this.cardSize = 'small',
    this.adultContent = 'none',
    this.preferDubs = false,
    // Player
    this.volume = 1.0,
    this.playerAutoplay = true,
    this.playerPauseOnLostFocus = true,
    this.playerAutocomplete = true,
    this.playerAutocompleteThreshold = 85,
    this.playerSeekStep = 2,
    this.playerChapterSkip = 'embedded',
    this.enableExternalPlayer = false,
    this.externalPlayerPath = '',
    this.audioLanguage = 'jpn',
    this.subtitleLanguage = 'eng',
    // Language learning (only used by the explicit Learning subtitle mode)
    this.learningTranslationLanguage = 'eng',
    this.learningAutoSelectTracks = true,
    this.learningAutoFetchJapaneseSubtitles = true,
    this.learningShowJapanese = true,
    this.learningShowFurigana = true,
    this.learningShowRomaji = false,
    this.learningShowTranslation = true,
    this.learningPauseOnLookup = false,
    this.learningSubtitleScale = 1.0,
    // Sources
    this.rssQuality = '1080',
    this.rssAutoplay = true,
    this.torrentSort = 'seeders',
    this.torrentAutoScrape = true,
    // Debrid
    this.debridService,
    this.debridApiKeys = const {},
    this.debridMode = DebridMode.prefer,
    this.debridCachedOnly = false,
    this.debridCacheCheck = true,
    // Torrent client
    this.torrentSpeedBytes = 5 * 1024 * 1024,
    this.torrentPersist = false,
    this.torrentStreamedDownload = true,
    this.maxConnections = 50,
    this.seedingLimit = 5,
    this.torrentPath = '',
  });

  final String titleLanguage;
  final String cardSize;
  final String adultContent;
  final bool preferDubs;

  final double volume;
  final bool playerAutoplay;
  final bool playerPauseOnLostFocus;
  final bool playerAutocomplete;

  /// Percent of duration after which a watch counts (external player clamps
  /// the effective value to 70).
  final int playerAutocompleteThreshold;
  final int playerSeekStep;
  final String playerChapterSkip;
  final bool enableExternalPlayer;
  final String externalPlayerPath;
  final String audioLanguage;
  final String subtitleLanguage;

  /// Language-learning preferences never change standard subtitle rendering.
  /// They become active only after the user explicitly chooses Learning in
  /// the player's subtitle panel.
  final String learningTranslationLanguage;
  final bool learningAutoSelectTracks;
  final bool learningAutoFetchJapaneseSubtitles;
  final bool learningShowJapanese;
  final bool learningShowFurigana;
  final bool learningShowRomaji;
  final bool learningShowTranslation;
  final bool learningPauseOnLookup;
  final double learningSubtitleScale;

  final String rssQuality;
  final bool rssAutoplay;
  final String torrentSort;
  final bool torrentAutoScrape;

  final DebridService? debridService;

  /// One key per service: switching services never loses a key, and no key is
  /// ever sent to another service's API.
  final Map<DebridService, String> debridApiKeys;
  final DebridMode debridMode;
  final bool debridCachedOnly;
  final bool debridCacheCheck;

  final int torrentSpeedBytes;
  final bool torrentPersist;
  final bool torrentStreamedDownload;
  final int maxConnections;
  final int seedingLimit;
  final String torrentPath;

  bool get debridEnabled =>
      debridService != null && debridMode != DebridMode.off;

  String? get activeDebridKey =>
      debridService == null ? null : debridApiKeys[debridService];

  /// Field-wise immutable update. [debridService] distinguishes an omitted
  /// value from an explicit `null`, which disables the selected service.
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
    String? learningTranslationLanguage,
    bool? learningAutoSelectTracks,
    bool? learningAutoFetchJapaneseSubtitles,
    bool? learningShowJapanese,
    bool? learningShowFurigana,
    bool? learningShowRomaji,
    bool? learningShowTranslation,
    bool? learningPauseOnLookup,
    double? learningSubtitleScale,
    String? rssQuality,
    bool? rssAutoplay,
    String? torrentSort,
    bool? torrentAutoScrape,
    Object? debridService = _unsetSetting,
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
      learningTranslationLanguage:
          learningTranslationLanguage ?? this.learningTranslationLanguage,
      learningAutoSelectTracks:
          learningAutoSelectTracks ?? this.learningAutoSelectTracks,
      learningAutoFetchJapaneseSubtitles:
          learningAutoFetchJapaneseSubtitles ??
          this.learningAutoFetchJapaneseSubtitles,
      learningShowJapanese: learningShowJapanese ?? this.learningShowJapanese,
      learningShowFurigana: learningShowFurigana ?? this.learningShowFurigana,
      learningShowRomaji: learningShowRomaji ?? this.learningShowRomaji,
      learningShowTranslation:
          learningShowTranslation ?? this.learningShowTranslation,
      learningPauseOnLookup:
          learningPauseOnLookup ?? this.learningPauseOnLookup,
      learningSubtitleScale:
          learningSubtitleScale ?? this.learningSubtitleScale,
      rssQuality: rssQuality ?? this.rssQuality,
      rssAutoplay: rssAutoplay ?? this.rssAutoplay,
      torrentSort: torrentSort ?? this.torrentSort,
      torrentAutoScrape: torrentAutoScrape ?? this.torrentAutoScrape,
      debridService: identical(debridService, _unsetSetting)
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
