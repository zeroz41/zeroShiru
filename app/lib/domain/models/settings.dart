import '../ports/debrid_client.dart';
import 'debrid_route.dart';

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
}
