import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/debrid_route.dart';
import 'package:zeroshiru/domain/models/settings.dart';
import 'package:zeroshiru/domain/ports/debrid_client.dart';
import 'package:zeroshiru/infrastructure/database/database.dart';
import 'package:zeroshiru/infrastructure/database/settings_codec.dart';
import 'package:zeroshiru/infrastructure/database/settings_repository_impl.dart';

void main() {
  late AppDatabase db;
  late SqliteSettingsRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = SqliteSettingsRepository(db);
  });

  tearDown(() {
    repo.dispose();
    db.close();
  });

  group('kv', () {
    test('a missing key answers the fallback', () {
      expect(repo.read('nope', 42), 42);
      expect(repo.read('nope', 'x'), 'x');
    });

    test('typed roundtrips', () async {
      await repo.write('b', true);
      await repo.write('i', 7);
      await repo.write('d', 0.5);
      await repo.write('s', 'hello');
      await repo.write('l', [1, 2, 3]);
      await repo.write('m', {'x': 1});
      expect(repo.read('b', false), isTrue);
      expect(repo.read('i', 0), 7);
      expect(repo.read('d', 0.0), 0.5);
      expect(repo.read('s', ''), 'hello');
      expect(repo.read('l', <dynamic>[]), [1, 2, 3]);
      expect(repo.read('m', <String, dynamic>{}), {'x': 1});
    });

    test('a whole double survives JSON as a double', () async {
      await repo.write('volume', 1.0);
      expect(repo.read('volume', 0.5), 1.0);
    });

    test('a mistyped value answers the fallback', () async {
      await repo.write('key', 'not a number');
      expect(repo.read('key', 3), 3);
    });

    test('overwriting emits on the change stream', () async {
      final events = <void>[];
      final sub = repo.changes.listen(events.add);
      await repo.write('a', 1);
      await repo.write('a', 2);
      await pumpEventQueue();
      expect(events.length, 2);
      expect(repo.read('a', 0), 2);
      await sub.cancel();
    });

    test('credential-shaped keys are refused (standing contract)', () {
      for (final key in [
        'torboxApiKey',
        'api_key',
        'debrid-api-key',
        'alToken',
        'client_secret',
        'password',
      ]) {
        expect(() => repo.write(key, 'x'), throwsArgumentError, reason: key);
      }
    });
  });

  group('Settings codec', () {
    test('roundtrips every persisted field', () {
      const settings = Settings(
        titleLanguage: 'english',
        cardSize: 'large',
        adultContent: 'hentai',
        preferDubs: true,
        volume: 0.25,
        playerAutoplay: false,
        playerPauseOnLostFocus: false,
        playerAutocomplete: false,
        playerAutocompleteThreshold: 70,
        playerSeekStep: 5,
        playerChapterSkip: 'always',
        enableExternalPlayer: true,
        externalPlayerPath: '/usr/bin/mpv',
        audioLanguage: 'eng',
        subtitleLanguage: 'spa',
        learningTranslationLanguage: 'de',
        learningAutoSelectTracks: false,
        learningShowJapanese: false,
        learningShowFurigana: false,
        learningShowRomaji: true,
        learningShowTranslation: false,
        learningPauseOnLookup: true,
        learningSubtitleScale: 1.2,
        rssQuality: '720',
        rssAutoplay: false,
        torrentSort: 'size',
        torrentAutoScrape: false,
        debridService: DebridService.torbox,
        debridMode: DebridMode.only,
        debridCachedOnly: true,
        debridCacheCheck: false,
        torrentSpeedBytes: 1024,
        torrentPersist: true,
        torrentStreamedDownload: false,
        maxConnections: 10,
        seedingLimit: 1,
        torrentPath: '/tmp/torrents',
      );
      final back = settingsFromJson(settings.toJson());
      expect(back.toJson(), settings.toJson());
      expect(back.debridService, DebridService.torbox);
      expect(back.debridMode, DebridMode.only);
      expect(back.volume, 0.25);
    });

    test('API keys never serialize (standing contract)', () {
      const settings = Settings(
        debridService: DebridService.realdebrid,
        debridApiKeys: {DebridService.realdebrid: 'SECRET'},
      );
      final json = settings.toJson();
      expect(json.containsKey('debridApiKeys'), isFalse);
      expect(json.toString().contains('SECRET'), isFalse);
    });

    test('an empty or legacy blob decodes to the schema defaults', () {
      final settings = settingsFromJson(const {});
      expect(settings.titleLanguage, 'romaji');
      expect(settings.volume, 1.0);
      expect(settings.playerAutocompleteThreshold, 85);
      expect(settings.learningTranslationLanguage, 'eng');
      expect(settings.learningShowFurigana, isTrue);
      expect(settings.learningShowRomaji, isFalse);
      expect(settings.debridService, isNull);
      expect(settings.debridMode, DebridMode.prefer);
      expect(settings.torrentSpeedBytes, 5 * 1024 * 1024);
    });

    test('unknown fields and mistyped values are tolerated', () {
      final settings = settingsFromJson(const {
        'someFutureField': true,
        'volume': 'loud',
        'debridService': 'notaservice',
        'maxConnections': 25.0,
        'learningTranslationLanguage': 'klingon',
        'learningSubtitleScale': 99,
      });
      expect(settings.volume, 1.0);
      expect(settings.debridService, isNull);
      expect(settings.maxConnections, 25);
      expect(settings.learningTranslationLanguage, 'eng');
      expect(settings.learningSubtitleScale, 1.0);
    });

    test('copyWith can clear debridService with an explicit null', () {
      const settings = Settings(debridService: DebridService.alldebrid);
      expect(
        settings.copyWith(volume: 0.1).debridService,
        DebridService.alldebrid,
      );
      expect(settings.copyWith(debridService: null).debridService, isNull);
      expect(
        settings.copyWith(debridService: DebridService.torbox).debridService,
        DebridService.torbox,
      );
    });

    test('readSettings/writeSettings persist through the kv table', () async {
      const settings = Settings(cardSize: 'large', debridMode: DebridMode.off);
      await repo.writeSettings(settings);
      final back = repo.readSettings();
      expect(back.cardSize, 'large');
      expect(back.debridMode, DebridMode.off);
      expect(back.titleLanguage, 'romaji');
    });

    test(
      'readSettings joined with keyring keys keeps activeDebridKey working',
      () {
        const settings = Settings(debridService: DebridService.premiumize);
        final joined = settings.copyWith(
          debridApiKeys: const {DebridService.premiumize: 'from-keyring'},
        );
        expect(joined.activeDebridKey, 'from-keyring');
      },
    );
  });
}
