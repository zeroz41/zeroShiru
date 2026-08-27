import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/models/source_extension.dart';
import 'package:zero/domain/models/torrent.dart';
import 'package:zero/domain/ports/ports.dart';
import 'package:zero/domain/ports/http_transport.dart';
import 'package:zero/infrastructure/sources/native_source_resolver.dart';

void main() {
  test('installs recursive gh catalogs and persists supported state', () async {
    final settings = _Settings();
    final resolver = NativeSourceResolver(
      transport: _Transport(),
      settings: settings,
    );

    final catalog = await resolver.install('gh:owner/repo');

    expect(catalog.roots, ['gh:owner/repo']);
    expect(catalog.extensions.map((item) => item.id), ['mystery', 'nyaa']);
    expect(
      catalog.extensions.singleWhere((item) => item.id == 'nyaa').enabled,
      isTrue,
    );
    expect(
      catalog.extensions.singleWhere((item) => item.id == 'mystery').supported,
      isFalse,
    );
    expect(
      catalog.extensions.singleWhere((item) => item.id == 'mystery').enabled,
      isFalse,
    );

    final reopened = NativeSourceResolver(
      transport: _Transport(),
      settings: settings,
    );
    expect((await reopened.catalog()).enabledCount, 1);
  });

  test('native Nyaa adapter returns a direct parseable magnet', () async {
    final transport = _Transport();
    final resolver = NativeSourceResolver(
      transport: transport,
      settings: _Settings(),
    );
    await resolver.install('gh:owner/repo');

    final batches = await resolver
        .search(
          const TorrentQuery(
            anilistId: 1,
            titles: ['Example Show'],
            episode: 4,
            episodeCount: 12,
            resolution: '1080',
          ),
        )
        .toList();

    final results = batches
        .singleWhere((batch) => batch.source.id == 'nyaa')
        .results;
    final result = results.singleWhere(
      (item) => item.title == '[Group] Example Show - 04 [1080p]',
    );
    expect(result.title, '[Group] Example Show - 04 [1080p]');
    expect(result.hash, '0123456789abcdef0123456789abcdef01234567');
    expect(result.link, contains('xt=urn:btih:0123456789abcdef'));
    expect(result.link, contains('tr=http%3A%2F%2Fnyaa.tracker.wf'));
    expect(result.seeders, 31);
    expect(result.size, 1536 * 1024 * 1024);
    expect(
      results.map((item) => item.title),
      contains('[Group] Example Show - 04 [720p]'),
    );
    final nyaaQueries = transport.requests
        .where((request) => request.url.host == 'nyaa.si')
        .map((request) => request.url.queryParameters['q'] ?? '');
    expect(nyaaQueries, isNotEmpty);
    expect(nyaaQueries, everyElement(isNot(contains('-(2160|720|540|480)'))));
  });

  test(
    'AnimeTosho preferred quality does not exclude other qualities',
    () async {
      final transport = _AnimeToshoTransport();
      final resolver = NativeSourceResolver(
        transport: transport,
        settings: _Settings(),
      );
      await resolver.install('gh:owner/animetosho');

      final batches = await resolver
          .search(
            const TorrentQuery(
              anilistId: 1,
              titles: ['Example Show'],
              episode: 4,
              episodeCount: 12,
              resolution: '2160',
            ),
          )
          .toList();

      final results = batches.single.results;
      expect(
        results.map((item) => item.title),
        containsAll([
          '[Group] Example Show - 04 [1080p]',
          '[Group] Example Show - 04 [720p]',
        ]),
      );
      final episodeRequest = transport.requests.singleWhere(
        (request) =>
            request.url.host.startsWith('feed.animetosho.') &&
            request.url.queryParameters.containsKey('eid'),
      );
      expect(episodeRequest.url.queryParameters, isNot(contains('q')));
      expect(episodeRequest.url.queryParameters, isNot(contains('qx')));
    },
  );

  test('Nyaa results stream before episode mapping finishes', () async {
    final transport = _SlowMappingTransport();
    final resolver = NativeSourceResolver(
      transport: transport,
      settings: _Settings(),
    );
    await resolver.install('gh:owner/repo');
    final first = Completer<SourceSearchBatch>();
    final done = Completer<void>();

    resolver
        .search(
          const TorrentQuery(
            anilistId: 1,
            titles: ['Example Show'],
            episode: 4,
            episodeCount: 12,
          ),
        )
        .listen((batch) {
          if (!first.isCompleted) first.complete(batch);
        }, onDone: done.complete);

    final batch = await first.future.timeout(const Duration(seconds: 1));
    expect(transport.mapping.isCompleted, isFalse);
    expect(batch.source.id, 'nyaa');
    expect(batch.results, isNotEmpty);

    transport.finishMapping();
    await done.future.timeout(const Duration(seconds: 1));
  });

  test(
    'a transport that ignores request timeouts cannot hold search open',
    () async {
      final transport = _HangingNyaaTransport();
      final resolver = NativeSourceResolver(
        transport: transport,
        settings: _Settings(),
        sourceTimeout: const Duration(milliseconds: 25),
        searchTimeout: const Duration(milliseconds: 100),
        mappingTimeout: const Duration(milliseconds: 10),
      );
      await resolver.install('gh:owner/repo');

      final batches = await resolver
          .search(
            const TorrentQuery(
              anilistId: 1,
              titles: ['Example Show'],
              episode: 4,
              episodeCount: 12,
            ),
          )
          .toList()
          .timeout(const Duration(seconds: 1));

      expect(batches, hasLength(1));
      expect(batches.single.source.id, 'nyaa');
      expect(batches.single.error, contains('Timed out'));
    },
  );
}

class _Transport implements HttpTransport {
  final requests = <HttpRequest>[];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.url.host == 'raw.githubusercontent.com') {
      if (path.endsWith('/main/index.json')) {
        return _json([
          {'main': 'gh:owner/repo/catalog'},
        ]);
      }
      if (path.endsWith('/main/catalog/index.json')) {
        return _json([
          {
            'id': 'nyaa',
            'name': 'Nyaa',
            'version': '1.0.0',
            'speed': 'slow',
            'accuracy': 'medium',
          },
          {'id': 'mystery', 'name': 'Legacy script', 'version': '1.0.0'},
        ]);
      }
    }
    if (request.url.host == 'nyaa.si') {
      return _text('''
        <rss><channel>
          <item>
            <title><![CDATA[[Group] Example Show - 04 [1080p]]]></title>
            <nyaa:infoHash>0123456789ABCDEF0123456789ABCDEF01234567</nyaa:infoHash>
            <nyaa:seeders>31</nyaa:seeders>
            <nyaa:leechers>2</nyaa:leechers>
            <nyaa:downloads>85</nyaa:downloads>
            <nyaa:size>1.5 GiB</nyaa:size>
            <nyaa:trusted>Yes</nyaa:trusted>
          </item>
          <item>
            <title><![CDATA[[Group] Example Show - 04 [720p]]]></title>
            <nyaa:infoHash>BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB</nyaa:infoHash>
            <nyaa:seeders>18</nyaa:seeders>
            <nyaa:leechers>1</nyaa:leechers>
            <nyaa:downloads>42</nyaa:downloads>
            <nyaa:size>700 MiB</nyaa:size>
          </item>
          <item>
            <title><![CDATA[[Group] Example Show - 40-52 [Batch]]]></title>
            <nyaa:infoHash>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA</nyaa:infoHash>
          </item>
          <item>
            <title><![CDATA[[Group] Example Show - 04 broken URL]]></title>
            <enclosure url="https://nyaa.si/download/invalid.torrent" />
          </item>
        </channel></rss>
      ''');
    }
    return _text('not found', status: 404);
  }

  HttpResponse _json(Object value) => _text(jsonEncode(value));

  HttpResponse _text(String value, {int status = 200}) => HttpResponse(
    status,
    const {'content-type': 'application/json'},
    Uint8List.fromList(utf8.encode(value)),
  );
}

class _AnimeToshoTransport implements HttpTransport {
  final requests = <HttpRequest>[];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    if (request.url.host == 'raw.githubusercontent.com') {
      return _json([
        {'id': 'animetosho-new', 'name': 'AnimeTosho', 'version': '1.0.0'},
      ]);
    }
    if (request.url.host == 'api.ani.zip') {
      return _json({
        'mappings': {'anidb_id': 123},
        'episodes': {
          '4': {'anidbEid': 456},
        },
      });
    }
    if (request.url.host.startsWith('feed.animetosho.')) {
      if (!request.url.queryParameters.containsKey('eid')) return _json([]);
      return _json([
        {
          'title': '[Group] Example Show - 04 [1080p]',
          'magnet_uri':
              'magnet:?xt=urn:btih:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
          'info_hash': 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
          'seeders': 20,
          'num_files': 1,
          'anidb_eid': 456,
        },
        {
          'title': '[Group] Example Show - 04 [720p]',
          'magnet_uri':
              'magnet:?xt=urn:btih:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
          'info_hash': 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
          'seeders': 10,
          'num_files': 1,
          'anidb_eid': 456,
        },
      ]);
    }
    return _text('not found', status: 404);
  }

  HttpResponse _json(Object value) => _text(jsonEncode(value));

  HttpResponse _text(String value, {int status = 200}) => HttpResponse(
    status,
    const {'content-type': 'application/json'},
    Uint8List.fromList(utf8.encode(value)),
  );
}

class _SlowMappingTransport extends _Transport {
  final mapping = Completer<HttpResponse>();

  void finishMapping() {
    mapping.complete(
      _json({'mappings': <String, Object?>{}, 'episodes': <String, Object?>{}}),
    );
  }

  @override
  Future<HttpResponse> send(HttpRequest request) {
    if (request.url.host == 'api.ani.zip') {
      requests.add(request);
      return mapping.future;
    }
    return super.send(request);
  }
}

class _HangingNyaaTransport extends _Transport {
  @override
  Future<HttpResponse> send(HttpRequest request) {
    if (request.url.host == 'nyaa.si' || request.url.host == 'api.ani.zip') {
      requests.add(request);
      return Completer<HttpResponse>().future;
    }
    return super.send(request);
  }
}

class _Settings implements SettingsRepository {
  final values = <String, Object?>{};
  final controller = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => controller.stream;

  @override
  T read<T>(String key, T fallback) {
    final value = values[key];
    return value is T ? value : fallback;
  }

  @override
  Settings readSettings() => const Settings();

  @override
  Future<void> write<T>(String key, T value) async {
    values[key] = value;
  }

  @override
  Future<void> writeSettings(Settings settings) async {}
}
