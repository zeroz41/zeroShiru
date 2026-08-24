import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/settings.dart';
import 'package:zeroshiru/domain/models/torrent.dart';
import 'package:zeroshiru/domain/ports/ports.dart';
import 'package:zeroshiru/infrastructure/network/transport.dart';
import 'package:zeroshiru/infrastructure/sources/native_source_resolver.dart';

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
    final resolver = NativeSourceResolver(
      transport: _Transport(),
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

    final result = batches
        .singleWhere((batch) => batch.source.id == 'nyaa')
        .results
        .single;
    expect(result.title, '[Group] Example Show - 04 [1080p]');
    expect(result.hash, '0123456789abcdef0123456789abcdef01234567');
    expect(result.link, contains('xt=urn:btih:0123456789abcdef'));
    expect(result.link, contains('tr=http%3A%2F%2Fnyaa.tracker.wf'));
    expect(result.seeders, 31);
    expect(result.size, 1536 * 1024 * 1024);
  });
}

class _Transport implements HttpTransport {
  @override
  Future<HttpResponse> send(HttpRequest request) async {
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
        <rss><channel><item>
          <title><![CDATA[[Group] Example Show - 04 [1080p]]]></title>
          <nyaa:infoHash>0123456789ABCDEF0123456789ABCDEF01234567</nyaa:infoHash>
          <nyaa:seeders>31</nyaa:seeders>
          <nyaa:leechers>2</nyaa:leechers>
          <nyaa:downloads>85</nyaa:downloads>
          <nyaa:size>1.5 GiB</nyaa:size>
          <nyaa:trusted>Yes</nyaa:trusted>
        </item></channel></rss>
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
