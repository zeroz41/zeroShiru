import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/application/playback/request.dart';
import 'package:zero/application/settings/providers.dart';
import 'package:zero/application/sources/providers.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/models/source_extension.dart';
import 'package:zero/domain/models/torrent.dart';
import 'package:zero/domain/ports/ports.dart';
import 'package:zero/features/library/media_details.dart';

void main() {
  testWidgets('episode details stay primary and sources open on request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const media = Media(
      id: 7,
      title: MediaTitle(userPreferred: 'Modern Details Show'),
      format: MediaFormat.tv,
      status: MediaStatus.finished,
      episodes: 12,
      duration: 24,
      averageScore: 88,
      genres: ['Adventure', 'Fantasy'],
      description: 'A real synopsis that remains readable beside the list.',
      listEntry: ListEntry(status: ListStatus.current, progress: 3),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(debridService: DebridService.torbox),
            ),
          ),
          credentialStoreProvider.overrideWithValue(
            const _Credentials('torbox-key'),
          ),
          sourceResolverProvider.overrideWithValue(const _Sources()),
          episodeRepositoryProvider.overrideWithValue(
            _Episodes([
              const EpisodeInfo(
                number: 2,
                title: 'A Different Chapter',
                summary: 'The second episode has its own story.',
                durationMinutes: 25,
              ),
              EpisodeInfo(
                number: 4,
                title: 'The Fourth Episode',
                summary: 'Episode four metadata belongs in the left panel.',
                durationMinutes: 26,
                airDate: DateTime(2026, 7, 4),
              ),
            ]),
          ),
          debridClientsProvider.overrideWithValue({
            DebridService.torbox: const _Debrid(),
          }),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const MediaDetails(media: media),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Modern Details Show'), findsOneWidget);
    expect(find.text('The Fourth Episode'), findsOneWidget);
    expect(
      find.text('Episode four metadata belongs in the left panel.'),
      findsWidgets,
    );
    expect(find.text('About this episode'), findsOneWidget);
    expect(find.text('4 of 12'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-results')), findsNothing);
    expect(find.byKey(const ValueKey('release-magnet')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await tester.pumpAndSettle();

    expect(find.text('A Different Chapter'), findsOneWidget);
    expect(find.text('The second episode has its own story.'), findsWidgets);
    expect(find.text('2 of 12'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-results')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('episode-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('choose-source')));
    await tester.pumpAndSettle();

    expect(find.text('Choose a source'), findsOneWidget);
    expect(find.text('Test cached release 04 1080p'), findsOneWidget);
    expect(find.text('Cached'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('cached-source-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-sort')), findsOneWidget);
    expect(find.byKey(const ValueKey('release-magnet')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('source-sort')));
    await tester.pumpAndSettle();
    expect(find.text('Highest quality'), findsOneWidget);
    await tester.tap(find.text('Highest quality'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('manual-release-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('release-magnet')), findsOneWidget);
    expect(find.textContaining('1 playable'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-source-results')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-results')), findsNothing);
    expect(find.byKey(const ValueKey('episode-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('release order follows audio and remembered Learning language', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const media = Media(
      id: 8,
      title: MediaTitle(userPreferred: 'Language Priority Show'),
      episodes: 1,
    );
    const preferredTitle = 'English dub with German subtitles';
    const otherTitle = 'Japanese audio with English subtitles';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(
                debridService: DebridService.torbox,
                audioLanguage: 'eng',
                subtitleLanguage: 'es',
                learningTranslationLanguage: 'de',
                playerSubtitleMode: 'learning',
              ),
            ),
          ),
          credentialStoreProvider.overrideWithValue(
            const _Credentials('torbox-key'),
          ),
          sourceResolverProvider.overrideWithValue(
            const _Sources([
              TorrentResult(
                title: otherTitle,
                link: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
                hash: '1111111111111111111111111111111111111111',
                seeders: 100,
                audioLanguages: ['jpn'],
                subtitleLanguages: ['eng'],
              ),
              TorrentResult(
                title: preferredTitle,
                link: 'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
                hash: '2222222222222222222222222222222222222222',
                seeders: 1,
                audioLanguages: ['eng'],
                subtitleLanguages: ['de'],
              ),
            ]),
          ),
          debridClientsProvider.overrideWithValue({
            DebridService.torbox: const _Debrid(),
          }),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const MediaDetails(media: media),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('choose-source')));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text(preferredTitle)).dy,
      lessThan(tester.getTopLeft(find.text(otherTitle)).dy),
    );
  });

  testWidgets('preferred quality ranks first without hiding other qualities', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const media = Media(
      id: 10,
      title: MediaTitle(userPreferred: 'Quality Priority Show'),
      episodes: 1,
    );
    const preferredTitle = 'Quality Priority Show 01 720p';
    const higherTitle = 'Quality Priority Show 01 2160p';
    const otherTitle = 'Quality Priority Show 01 1080p';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(
                debridService: DebridService.torbox,
                rssQuality: '720',
              ),
            ),
          ),
          credentialStoreProvider.overrideWithValue(
            const _Credentials('torbox-key'),
          ),
          sourceResolverProvider.overrideWithValue(
            const _Sources([
              TorrentResult(
                title: higherTitle,
                link: 'magnet:?xt=urn:btih:7777777777777777777777777777777777777777',
                hash: '7777777777777777777777777777777777777777',
                seeders: 100,
              ),
              TorrentResult(
                title: preferredTitle,
                link: 'magnet:?xt=urn:btih:8888888888888888888888888888888888888888',
                hash: '8888888888888888888888888888888888888888',
                seeders: 1,
              ),
              TorrentResult(
                title: otherTitle,
                link: 'magnet:?xt=urn:btih:9999999999999999999999999999999999999999',
                hash: '9999999999999999999999999999999999999999',
                seeders: 50,
              ),
            ]),
          ),
          debridClientsProvider.overrideWithValue({
            DebridService.torbox: const _Debrid(),
          }),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const MediaDetails(media: media),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('choose-source')));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 playable'), findsOneWidget);
    expect(find.text(higherTitle), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(preferredTitle)).dy,
      lessThan(tester.getTopLeft(find.text(higherTitle)).dy),
    );
  });

  testWidgets('row and hero play resolve the same best-ranked source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const preferredHash = '2222222222222222222222222222222222222222';
    const otherHash = '1111111111111111111111111111111111111111';
    const media = Media(
      id: 12,
      title: MediaTitle(userPreferred: 'One Best Source'),
      episodes: 2,
      duration: 24,
    );
    final launches = <PlaybackLaunch>[];
    final queries = <TorrentQuery>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(
                debridService: DebridService.torbox,
                rssQuality: '1080',
                audioLanguage: 'jpn',
                subtitleLanguage: 'eng',
              ),
            ),
          ),
          credentialStoreProvider.overrideWithValue(
            const _Credentials('torbox-key'),
          ),
          sourceResolverProvider.overrideWithValue(
            _Sources.recordingResults(queries, const [
              TorrentResult(
                title: 'One Best Source 01-02 720p JA EN',
                link: 'magnet:?xt=urn:btih:$otherHash',
                hash: otherHash,
                seeders: 100,
                type: 'batch',
                audioLanguages: ['jpn'],
                subtitleLanguages: ['eng'],
              ),
              TorrentResult(
                title: 'One Best Source 01-02 1080p JA EN',
                link: 'magnet:?xt=urn:btih:$preferredHash',
                hash: preferredHash,
                seeders: 5,
                type: 'batch',
                audioLanguages: ['jpn'],
                subtitleLanguages: ['eng'],
              ),
            ]),
          ),
          debridClientsProvider.overrideWithValue({
            DebridService.torbox: const _Debrid({
              otherHash: [
                DebridCachedFile(path: 'Show - 01.mkv', size: 1000),
                DebridCachedFile(path: 'Show - 02.mkv', size: 1000),
              ],
              preferredHash: [
                DebridCachedFile(path: 'Show - 01.mkv', size: 1000),
                DebridCachedFile(path: 'Show - 02.mkv', size: 1000),
              ],
            }),
          }),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: _DetailsLauncher(media: media, onLaunch: launches.add),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-test-details')));
    await tester.pumpAndSettle();
    expect(queries.map((query) => query.episode), [1]);

    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await tester.pumpAndSettle();
    expect(queries.map((query) => query.episode), [1, 2]);

    final searchesBeforePlay = queries.length;
    await tester.tap(find.byKey(const ValueKey('episode-play-2')));
    await tester.pumpAndSettle();

    expect(queries, hasLength(searchesBeforePlay));
    expect(launches, hasLength(1));
    expect(launches.single.episode, 2);
    expect(launches.single.magnet, contains(preferredHash));
    expect(find.byKey(const ValueKey('source-results')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('open-test-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('watch-now')));
    await tester.pumpAndSettle();

    expect(launches, hasLength(2));
    expect(launches.last.episode, 1);
    expect(launches.last.magnet, contains(preferredHash));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing preferred quality is used by the next search', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const media = Media(
      id: 11,
      title: MediaTitle(userPreferred: 'Quality Refresh Show'),
      episodes: 1,
    );
    final queries = <TorrentQuery>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(
                debridService: DebridService.torbox,
                rssQuality: '1080',
              ),
            ),
          ),
          credentialStoreProvider.overrideWithValue(
            const _Credentials('torbox-key'),
          ),
          sourceResolverProvider.overrideWithValue(_Sources.recording(queries)),
          debridClientsProvider.overrideWithValue({
            DebridService.torbox: const _Debrid({
              '0123456789abcdef0123456789abcdef01234567': [
                DebridCachedFile(path: 'Show - 01.mkv', size: 1000),
              ],
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa': [
                DebridCachedFile(path: 'Show - 01.mkv', size: 1000),
              ],
            }),
          }),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const MediaDetails(media: media),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('choose-source')));
    await tester.pumpAndSettle();
    // Opening the picker consumes the selection-time prefetch instead of
    // issuing a duplicate source request.
    expect(queries, hasLength(1));
    expect(queries.last.resolution, '1080');
    expect(
      tester.getTopLeft(find.text('Quality Refresh Show 01 1080p')).dy,
      lessThan(tester.getTopLeft(find.text('Quality Refresh Show 01 720p')).dy),
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MediaDetails)),
    );
    await container
        .read(settingsControllerProvider.notifier)
        .persist((current) => current.copyWith(rssQuality: '720'));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();

    expect(container.read(settingsControllerProvider).value?.rssQuality, '720');
    expect(queries, hasLength(2));
    expect(queries.last.resolution, '720');
    expect(
      tester.getTopLeft(find.text('Quality Refresh Show 01 720p')).dy,
      lessThan(
        tester.getTopLeft(find.text('Quality Refresh Show 01 1080p')).dy,
      ),
    );
  });

  testWidgets(
    'TorBox picker hides invalid identities and cached batches missing the episode',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const goodHash = '3333333333333333333333333333333333333333';
      const wrongHash = '4444444444444444444444444444444444444444';
      const media = Media(
        id: 9,
        title: MediaTitle(userPreferred: 'Picker Safety Show'),
        episodes: 12,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              _SettingsRepository(
                const Settings(debridService: DebridService.torbox),
              ),
            ),
            credentialStoreProvider.overrideWithValue(
              const _Credentials('torbox-key'),
            ),
            sourceResolverProvider.overrideWithValue(
              const _Sources([
                TorrentResult(
                  title: 'Missing hash release 04',
                  link: 'https://tracker.test/download/123.torrent',
                ),
                TorrentResult(
                  title: 'Contradictory hash release 04',
                  link: 'magnet:?xt=urn:btih:6666666666666666666666666666666666666666',
                  hash: '5555555555555555555555555555555555555555',
                ),
                TorrentResult(
                  title: 'Wrong cached batch 01-12',
                  link: 'magnet:?xt=urn:btih:$wrongHash',
                  hash: wrongHash,
                  type: 'batch',
                ),
                TorrentResult(
                  title: 'Correct complete batch',
                  link: 'magnet:?xt=urn:btih:$goodHash',
                  hash: goodHash,
                  type: 'batch',
                ),
              ]),
            ),
            debridClientsProvider.overrideWithValue({
              DebridService.torbox: const _Debrid({
                wrongHash: [
                  DebridCachedFile(path: 'Show - 40.mkv', size: 1000),
                  DebridCachedFile(path: 'Show - 41.mkv', size: 1000),
                ],
                goodHash: [
                  DebridCachedFile(path: 'Show - 03.mkv', size: 1000),
                  DebridCachedFile(path: 'Show - 04.mkv', size: 1000),
                  DebridCachedFile(path: 'Show - 05.mkv', size: 1000),
                ],
              }),
            }),
          ],
          child: MaterialApp(
            theme: buildZeroTheme(),
            home: const MediaDetails(media: media, initialEpisode: 4),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('choose-source')));
      await tester.pumpAndSettle();

      expect(find.text('Correct complete batch'), findsOneWidget);
      expect(find.text('Missing hash release 04'), findsNothing);
      expect(find.text('Contradictory hash release 04'), findsNothing);
      expect(find.text('Wrong cached batch 01-12'), findsNothing);
      expect(find.textContaining('1 playable'), findsOneWidget);
    },
  );
}

class _Sources implements SourceResolver {
  const _Sources([
    this.results = const [
      TorrentResult(
        title: 'Test cached release 04 1080p',
        link: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        hash: '0123456789abcdef0123456789abcdef01234567',
        seeders: 42,
        size: 800000000,
      ),
    ],
  ]) : queries = null;

  const _Sources.recording(this.queries)
    : results = const [
        TorrentResult(
          title: 'Quality Refresh Show 01 1080p',
          link: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          hash: '0123456789abcdef0123456789abcdef01234567',
          seeders: 42,
          size: 800000000,
        ),
        TorrentResult(
          title: 'Quality Refresh Show 01 720p',
          link: 'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          hash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          seeders: 41,
          size: 700000000,
        ),
      ];

  const _Sources.recordingResults(this.queries, this.results);

  final List<TorrentResult> results;
  final List<TorrentQuery>? queries;

  static const extension = SourceExtension(
    id: 'test',
    name: 'Test source',
    version: '1',
    origin: 'test',
    supported: true,
    enabled: true,
  );

  @override
  Future<SourceCatalog> catalog() async =>
      const SourceCatalog(extensions: [extension]);

  @override
  Stream<SourceSearchBatch> search(TorrentQuery query, {bool movie = false}) {
    queries?.add(query);
    return Stream.value(SourceSearchBatch(source: extension, results: results));
  }

  @override
  Future<SourceCatalog> install(String source) => catalog();

  @override
  Future<SourceCatalog> remove(String source) => catalog();

  @override
  Future<SourceCatalog> setEnabled(String id, bool enabled) => catalog();

  @override
  Future<SourceCatalog> updateSettings(
    String id,
    Map<String, Object?> settings,
  ) => catalog();

  @override
  Future<bool> validate(String id) async => true;
}

class _DetailsLauncher extends StatelessWidget {
  const _DetailsLauncher({required this.media, required this.onLaunch});

  final Media media;
  final ValueChanged<PlaybackLaunch> onLaunch;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const ValueKey('open-test-details'),
          onPressed: () async {
            final launch = await Navigator.of(context).push<PlaybackLaunch>(
              MaterialPageRoute(builder: (_) => MediaDetails(media: media)),
            );
            if (launch != null) onLaunch(launch);
          },
          child: const Text('Open details'),
        ),
      ),
    );
  }
}

class _Episodes implements EpisodeRepository {
  const _Episodes(this.items);

  final List<EpisodeInfo> items;

  @override
  Future<List<EpisodeInfo>> episodes(Media media) async => items;
}

class _Debrid implements DebridClient {
  const _Debrid([this.filesByHash]);

  final Map<String, List<DebridCachedFile>>? filesByHash;

  @override
  DebridService get service => DebridService.torbox;

  @override
  bool get checkAddsMagnets => false;

  @override
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  ) async => {for (final hash in hashes) hash: Availability.cached};

  @override
  Future<Map<String, DebridAvailabilityDetail>> inspectAvailability(
    String apiKey,
    List<String> hashes,
  ) async => {
    for (final hash in hashes)
      hash: DebridAvailabilityDetail(
        Availability.cached,
        files:
            filesByHash?[hash] ??
            [
              DebridCachedFile(
                path: hash.startsWith('012345')
                    ? 'Show - 04.mkv'
                    : 'Show - 01.mkv',
                size: 1000,
              ),
            ],
      ),
  };

  @override
  Future<void> forgetResolved(String apiKey, String hash) async {}

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) => throw UnimplementedError();

  @override
  Future<DebridAccount> validate(String apiKey) => throw UnimplementedError();
}

class _SettingsRepository implements SettingsRepository {
  _SettingsRepository(this.settings);

  Settings settings;
  final controller = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => controller.stream;

  @override
  Settings readSettings() => settings;

  @override
  Future<void> writeSettings(Settings settings) async {
    this.settings = settings;
  }

  @override
  T read<T>(String key, T fallback) => fallback;

  @override
  Future<void> write<T>(String key, T value) async {}
}

class _Credentials implements CredentialStore {
  const _Credentials(this.value);

  final String value;

  @override
  Future<String?> read(String key) async =>
      key == debridCredentialKey(DebridService.torbox) ? value : null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
