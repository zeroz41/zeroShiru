import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/sources/best_source_search.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/models/source_extension.dart';
import 'package:zero/domain/models/torrent.dart';
import 'package:zero/domain/ports/ports.dart';

void main() {
  test(
    'next-episode search uses mapped numbering and rejects a wrong pack',
    () async {
      const wantedHash = '8888888888888888888888888888888888888888';
      const wrongHash = '9999999999999999999999999999999999999999';
      final resolver = _Sources(const [
        TorrentResult(
          title: 'Clean Player Show complete batch',
          link: 'magnet:?xt=urn:btih:$wantedHash',
          hash: wantedHash,
          type: 'batch',
          seeders: 100,
        ),
        TorrentResult(
          title: 'Clean Player Show 20 1080p',
          link: 'magnet:?xt=urn:btih:$wantedHash',
          hash: wantedHash,
          mappedEpisode: 20,
          seeders: 10,
        ),
        TorrentResult(
          title: 'Show complete batch',
          link: 'magnet:?xt=urn:btih:$wrongHash',
          hash: wrongHash,
          type: 'batch',
          seeders: 100,
        ),
      ]);
      final result = await searchBestEpisodeSources(
        resolver: resolver,
        debrid: const _Debrid({
          wantedHash: DebridAvailabilityDetail(
            Availability.cached,
            files: [DebridCachedFile(path: 'Show - 20.mkv')],
          ),
          wrongHash: DebridAvailabilityDetail(
            Availability.cached,
            files: [DebridCachedFile(path: 'Show - 19.mkv')],
          ),
        }),
        apiKey: 'secret',
        media: const Media(
          id: 1,
          title: MediaTitle(userPreferred: 'Show'),
          episodes: 12,
        ),
        episode: 8,
        preferences: const Settings(rssQuality: '1080'),
      );

      expect(resolver.queries.single.episode, 8);
      expect(result.releases, hasLength(1));
      expect(result.releases.single.magnet, contains(wantedHash));
      expect(result.releases.single.releaseEpisode, 20);
    },
  );
}

class _Sources implements SourceResolver {
  _Sources(this.results);

  final List<TorrentResult> results;
  final queries = <TorrentQuery>[];

  static const extension = SourceExtension(
    id: 'test',
    name: 'Test',
    version: '1',
    origin: 'test',
    supported: true,
    enabled: true,
  );

  @override
  Stream<SourceSearchBatch> search(TorrentQuery query, {bool movie = false}) {
    queries.add(query);
    return Stream.value(SourceSearchBatch(source: extension, results: results));
  }

  @override
  Future<SourceCatalog> catalog() async => const SourceCatalog();

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

class _Debrid implements DebridClient {
  const _Debrid(this.details);

  final Map<String, DebridAvailabilityDetail> details;

  @override
  DebridService get service => DebridService.torbox;

  @override
  bool get checkAddsMagnets => false;

  @override
  Future<Map<String, DebridAvailabilityDetail>> inspectAvailability(
    String apiKey,
    List<String> hashes,
  ) async => details;

  @override
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  ) async => {
    for (final entry in details.entries) entry.key: entry.value.availability,
  };

  @override
  Future<DebridAccount> validate(String apiKey) async =>
      const DebridAccount(username: 'test');

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) => throw UnimplementedError();

  @override
  Future<void> forgetResolved(String apiKey, String hash) async {}
}
