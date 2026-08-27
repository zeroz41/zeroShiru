import 'dart:async';
import 'dart:convert';

import '../../application/playback/coverage.dart';
import '../../domain/models/source_extension.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/ports.dart';
import '../../domain/media/info_hash.dart';
import '../../domain/media/filename.dart';
import '../../domain/ports/http_transport.dart';

/// Installs the old Zero declarative JSON catalogs, then dispatches known
/// extension IDs to native Dart adapters. Manifest JavaScript is intentionally
/// ignored: extension data is compatible, extension code is not executed.
class NativeSourceResolver implements SourceResolver {
  NativeSourceResolver({
    required HttpTransport transport,
    required this.settings,
    this.log = const NoopAppLog(),
    this.sourceTimeout = const Duration(seconds: 6),
    this.searchTimeout = const Duration(seconds: 8),
    this.mappingTimeout = const Duration(milliseconds: 2500),
  }) : _http = _SourceHttp(transport) {
    _adapters = {
      'nyaa': _NyaaAdapter(_http, adult: false),
      'sukebei': _NyaaAdapter(_http, adult: true),
      'seadex': _SeaDexAdapter(_http),
      'animetosho': _AnimeToshoAdapter(_http, archive: true),
      'animetosho-new': _AnimeToshoAdapter(_http, archive: false),
      'nekobt': _NekoBtAdapter(_http),
      'tsukihime': _TsukiAdapter(_http),
    };
  }

  static const _storageKey = 'source_extensions_v1';

  final _SourceHttp _http;
  final SettingsRepository settings;
  final AppLog log;

  /// One adapter may make several requests, but it never owns the picker
  /// indefinitely. The stream-wide deadline is a second line of defence for
  /// broken adapters and test transports which ignore [HttpRequest.timeout].
  final Duration sourceTimeout;
  final Duration searchTimeout;
  final Duration mappingTimeout;
  late final Map<String, _NativeAdapter> _adapters;
  final Map<String, (DateTime, TorrentQuery)> _mappingCache = {};
  SourceCatalog? _catalog;

  @override
  Future<SourceCatalog> catalog() async {
    final existing = _catalog;
    if (existing != null) return existing;
    final raw = settings.read<Map<String, dynamic>>(_storageKey, const {});
    final roots = _stringList(raw['roots']);
    final extensions = <SourceExtension>[];
    final saved = raw['extensions'];
    if (saved is List) {
      for (final item in saved) {
        if (item is Map) {
          final parsed = _extensionFromStored(item);
          if (parsed != null) extensions.add(parsed);
        }
      }
    }
    return _catalog = SourceCatalog(roots: roots, extensions: extensions);
  }

  @override
  Future<SourceCatalog> install(String source) async {
    final root = source.trim();
    if (root.isEmpty) throw const FormatException('Enter an extension source.');
    final current = await catalog();
    final fetched = <String, SourceExtension>{};
    await _readManifest(root, root, fetched, <String>{});
    if (fetched.isEmpty) {
      throw const FormatException('The source did not contain any extensions.');
    }
    final previous = {for (final item in current.extensions) item.id: item};
    final installed = <SourceExtension>[];
    for (final item in fetched.values) {
      final old = previous[item.id];
      installed.add(
        SourceExtension(
          id: item.id,
          name: item.name,
          version: item.version,
          origin: root,
          supported: item.supported,
          enabled:
              old?.enabled ??
              (item.supported && !item.deprecated && !item.nsfw),
          description: item.description,
          speed: item.speed,
          accuracy: item.accuracy,
          deprecated: item.deprecated,
          nsfw: item.nsfw,
          fields: item.fields,
          settings: old?.settings ?? item.settings,
        ),
      );
    }
    final next = SourceCatalog(
      roots: {...current.roots, root}.toList(growable: false),
      extensions: [
        for (final item in current.extensions)
          if (item.origin != root && !fetched.containsKey(item.id)) item,
        ...installed,
      ]..sort((a, b) => a.name.compareTo(b.name)),
    );
    return _save(next);
  }

  @override
  Future<SourceCatalog> remove(String source) async {
    final current = await catalog();
    return _save(
      SourceCatalog(
        roots: current.roots.where((item) => item != source).toList(),
        extensions: current.extensions
            .where((item) => item.origin != source)
            .toList(),
      ),
    );
  }

  @override
  Future<SourceCatalog> setEnabled(String id, bool enabled) async {
    final current = await catalog();
    final item = current.extensions.where((item) => item.id == id).firstOrNull;
    if (item == null) throw StateError('Extension is no longer installed.');
    if (enabled && !item.supported) {
      throw UnsupportedError(
        '${item.name} has no native adapter in this build.',
      );
    }
    return _save(
      SourceCatalog(
        roots: current.roots,
        extensions: [
          for (final entry in current.extensions)
            entry.id == id ? entry.copyWith(enabled: enabled) : entry,
        ],
      ),
    );
  }

  @override
  Future<SourceCatalog> updateSettings(
    String id,
    Map<String, Object?> values,
  ) async {
    final current = await catalog();
    return _save(
      SourceCatalog(
        roots: current.roots,
        extensions: [
          for (final entry in current.extensions)
            entry.id == id ? entry.copyWith(settings: values) : entry,
        ],
      ),
    );
  }

  @override
  Future<bool> validate(String id) async {
    final adapter = _adapters[id];
    return adapter != null && await adapter.validate();
  }

  @override
  Stream<SourceSearchBatch> search(TorrentQuery query, {bool movie = false}) {
    final controller = StreamController<SourceSearchBatch>();
    var stopped = false;
    var completed = false;
    final started = Stopwatch()..start();
    Timer? deadline;

    void emit(SourceSearchBatch batch) {
      if (!stopped && !controller.isClosed) controller.add(batch);
    }

    Future<void> finish() async {
      if (completed) return;
      completed = true;
      stopped = true;
      deadline?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller.onCancel = () {
      stopped = true;
      deadline?.cancel();
    };
    deadline = Timer(searchTimeout, () {
      log.log(
        'warn',
        'sources',
        'Search deadline reached for media ${query.anilistId} episode '
            '${query.episode ?? 0} after ${started.elapsedMilliseconds}ms',
      );
      unawaited(finish());
    });
    log.log(
      'info',
      'sources',
      'Search started for media ${query.anilistId} episode '
          '${query.episode ?? 0}',
    );
    unawaited(() async {
      try {
        final current = await catalog();
        if (stopped) return;
        final enabled = current.extensions
            .where((item) => item.enabled && item.supported)
            .toList(growable: false);
        if (enabled.isEmpty) {
          log.log('warn', 'sources', 'Search has no enabled source adapters');
          await finish();
          return;
        }
        // Resolve AniZip once, but do not make title- and AniList-based sources
        // wait for it. Their local-numbered results can reach the picker now;
        // adapters which benefit from absolute numbering send a mapped follow-up.
        final mapped = _mappedQuery(query);
        var remaining = enabled.length;
        for (final extension in enabled) {
          unawaited(() async {
            final sourceStarted = Stopwatch()..start();
            var acceptingResults = true;
            try {
              final adapter = _adapters[extension.id]!;
              Future<void> searchAndEmit(TorrentQuery effective) async {
                final results = await adapter.search(
                  effective,
                  movie: movie,
                  settings: extension.settings,
                );
                // Future.timeout cannot cancel arbitrary adapter code. Ignore a
                // late answer once this adapter's lane has already retired.
                if (!acceptingResults || stopped) return;
                final batch = _safeBatch(
                  extension,
                  results,
                  requested: query,
                  effective: effective,
                );
                emit(batch);
                log.log(
                  'info',
                  'sources',
                  '${extension.id} returned ${batch.results.length} valid '
                      'release(s) in ${sourceStarted.elapsedMilliseconds}ms',
                );
              }

              await (() async {
                if (adapter.requiresMapping) {
                  await searchAndEmit(await mapped);
                } else {
                  await searchAndEmit(query);
                  if (adapter.searchesMappedEpisodes) {
                    final effective = await mapped;
                    if (effective.absoluteEpisode != null &&
                        effective.absoluteEpisode != query.episode) {
                      await searchAndEmit(effective);
                    }
                  }
                }
              }()).timeout(
                sourceTimeout,
                onTimeout: () => throw const _SourceSearchTimeout(),
              );
            } catch (error) {
              final message = error is _SourceSearchTimeout
                  ? 'Timed out after ${sourceTimeout.inSeconds}s.'
                  : _safeError(error);
              emit(SourceSearchBatch(source: extension, error: message));
              log.log(
                error is _SourceSearchTimeout ? 'warn' : 'error',
                'sources',
                '${extension.id} failed after '
                    '${sourceStarted.elapsedMilliseconds}ms: $message',
              );
            } finally {
              acceptingResults = false;
              remaining--;
              if (remaining == 0) {
                log.log(
                  'info',
                  'sources',
                  'Search finished in ${started.elapsedMilliseconds}ms',
                );
                await finish();
              }
            }
          }());
        }
      } catch (error) {
        log.log(
          'error',
          'sources',
          'Search setup failed: ${_safeError(error)}',
        );
        await finish();
      }
    }());
    return controller.stream;
  }

  SourceSearchBatch _safeBatch(
    SourceExtension extension,
    List<TorrentResult> results, {
    required TorrentQuery requested,
    required TorrentQuery effective,
  }) => SourceSearchBatch(
    source: extension,
    results: [
      for (final result in results)
        if (validatedTorrentMagnet(declaredHash: result.hash, link: result.link)
            case final magnet?)
          if (releaseHoldsEpisode(
            parseFilename(result.title),
            episode: requested.episode,
            absoluteEpisode: effective.absoluteEpisode,
            episodeCount: requested.episodeCount,
          ))
            TorrentResult(
              title: result.title,
              link: result.link,
              hash: parseHash(magnet),
              size: result.size,
              seeders: result.seeders,
              leechers: result.leechers,
              downloads: result.downloads,
              date: result.date,
              id: result.id,
              accuracy: result.accuracy,
              type: result.type,
              sourceId: extension.id,
              mappedEpisode: effective.absoluteEpisode,
              audioLanguages: result.audioLanguages,
              subtitleLanguages: result.subtitleLanguages,
            ),
    ],
  );

  Future<TorrentQuery> _mappedQuery(TorrentQuery query) async {
    final cacheKey = '${query.anilistId}:${query.episode ?? 0}';
    final cached = _mappingCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$1).inMinutes < 60) {
      return cached.$2;
    }
    try {
      final root = await _http
          .json(
            Uri.https('api.ani.zip', '/mappings', {
              'anilist_id': '${query.anilistId}',
            }),
            timeout: mappingTimeout,
          )
          .timeout(mappingTimeout);
      if (root is! Map) return query;
      final mappings = root['mappings'];
      final base = query.copyWith(
        anidbAid: _int(mappings is Map ? mappings['anidb_id'] : null),
        tvdbAid: _int(mappings is Map ? mappings['thetvdb_id'] : null),
        tmdbId: _int(mappings is Map ? mappings['themoviedb_id'] : null),
        imdbId: _text(mappings is Map ? mappings['imdb_id'] : null),
      );
      final mapped = _episodeMapping(base, query, episodes: root['episodes']);
      _mappingCache[cacheKey] = (DateTime.now(), mapped);
      return mapped;
    } catch (error) {
      // A mapping outage should cost one short attempt, not every adapter and
      // every click. Local episode numbering remains useful for most sources.
      _mappingCache[cacheKey] = (DateTime.now(), query);
      log.log(
        'warn',
        'sources',
        'Episode mapping unavailable for media ${query.anilistId}: '
            '${_safeError(error)}',
      );
      return query;
    }
  }

  TorrentQuery _episodeMapping(
    TorrentQuery base,
    TorrentQuery query, {
    Object? episodes,
  }) {
    Map? row;
    if (episodes is Map && query.episode != null) {
      final direct = episodes['${query.episode}'];
      if (direct is Map) row = direct;
      row ??= episodes.values.whereType<Map>().where((item) {
        return _int(item['episodeNumber']) == query.episode;
      }).firstOrNull;
    }
    return base.copyWith(
      anidbEid: _int(row?['anidbEid'] ?? row?['anidb_eid']),
      tvdbEid: _int(row?['tvdbId'] ?? row?['tvdb_id']),
      season: _int(row?['seasonNumber'] ?? row?['season']),
      absoluteEpisode: _int(row?['absoluteEpisodeNumber'] ?? row?['absolute']),
    );
  }

  Future<void> _readManifest(
    String source,
    String root,
    Map<String, SourceExtension> output,
    Set<String> visited,
  ) async {
    final normalized = source.trim();
    if (!visited.add(normalized)) return;
    final raw = await _manifestJson(normalized);
    if (raw is! List) {
      throw const FormatException('Extension index must be a list.');
    }
    for (final item in raw) {
      if (item is! Map) continue;
      final id = _text(item['id']);
      final nested = _text(item['main']);
      if (id == null && nested != null) {
        await _readManifest(
          _resolveNested(normalized, nested),
          root,
          output,
          visited,
        );
        continue;
      }
      if (id == null) continue;
      final extension = _extensionFromManifest(item, root);
      if (extension != null) output[id] = extension;
    }
  }

  Future<Object?> _manifestJson(String source) async {
    final candidates = <Uri>[];
    if (source.startsWith('gh:')) {
      final parts = source.substring(3).split('/');
      if (parts.length < 2) {
        throw const FormatException(
          'GitHub source must be gh:owner/repository.',
        );
      }
      final path = parts.length > 2 ? '${parts.sublist(2).join('/')}/' : '';
      candidates.add(
        Uri.https(
          'raw.githubusercontent.com',
          '/${parts[0]}/${parts[1]}/main/${path}index.json',
        ),
      );
      candidates.add(
        Uri.https(
          'raw.githubusercontent.com',
          '/${parts[0]}/${parts[1]}/master/${path}index.json',
        ),
      );
    } else {
      final uri = Uri.tryParse(source);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw const FormatException(
          'Use gh:owner/repository or an HTTPS index URL.',
        );
      }
      candidates.add(
        uri.path.endsWith('.json')
            ? uri
            : uri.replace(
                path: '${uri.path.replaceFirst(RegExp(r'/$'), '')}/index.json',
              ),
      );
    }
    Object? lastError;
    for (final uri in candidates) {
      try {
        return await _http.json(uri, timeout: const Duration(seconds: 12));
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError(
      'Could not load extension index: ${_safeError(lastError)}',
    );
  }

  String _resolveNested(String parent, String child) {
    if (child.startsWith('gh:') || child.startsWith('http')) return child;
    if (parent.startsWith('gh:')) {
      final slash = parent.lastIndexOf('/');
      return slash <= 2
          ? '$parent/$child'
          : '${parent.substring(0, slash)}/$child';
    }
    return Uri.parse(parent).resolve(child).toString();
  }

  SourceExtension? _extensionFromManifest(Map item, String origin) {
    final id = _text(item['id']);
    final name = _text(item['name']);
    final version = _text(item['version']);
    if (id == null || name == null || version == null) return null;
    final fields = _fields(item['settings']);
    return SourceExtension(
      id: id,
      name: name,
      version: version,
      origin: origin,
      supported: _adapters.containsKey(id),
      enabled: false,
      description: _text(item['description']),
      speed: _text(item['speed']),
      accuracy: _text(item['accuracy']),
      deprecated: item['deprecated'] == true,
      nsfw: item['nsfw'] == true,
      fields: fields,
      settings: {
        for (final field in fields)
          field.key: field.type == ExtensionSettingType.multiselect
              ? <String>[]
              : null,
      },
    );
  }

  SourceExtension? _extensionFromStored(Map item) {
    final manifest = _extensionFromManifest(item, _text(item['origin']) ?? '');
    if (manifest == null) return null;
    final values = item['values'];
    return SourceExtension(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      origin: manifest.origin,
      supported: _adapters.containsKey(manifest.id),
      enabled: item['enabled'] == true,
      description: manifest.description,
      speed: manifest.speed,
      accuracy: manifest.accuracy,
      deprecated: manifest.deprecated,
      nsfw: manifest.nsfw,
      fields: manifest.fields,
      settings: values is Map
          ? {
              for (final entry in values.entries)
                entry.key.toString(): entry.value,
            }
          : const {},
    );
  }

  List<ExtensionSettingField> _fields(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map && _text(item['key']) != null)
          ExtensionSettingField(
            key: _text(item['key'])!,
            label: _text(item['label']) ?? _text(item['key'])!,
            description: _text(item['description']),
            type: switch (_text(item['type'])) {
              'multiselect' => ExtensionSettingType.multiselect,
              'toggle' || 'boolean' => ExtensionSettingType.toggle,
              'text' => ExtensionSettingType.text,
              _ => ExtensionSettingType.select,
            },
            options: [
              for (final option
                  in (item['options'] is List
                      ? item['options'] as List
                      : const []))
                if (option is Map && _text(option['value']) != null)
                  ExtensionOption(
                    label: _text(option['label']) ?? _text(option['value'])!,
                    value: _text(option['value'])!,
                  ),
            ],
          ),
    ];
  }

  Future<SourceCatalog> _save(SourceCatalog next) async {
    _catalog = next;
    await settings.write(_storageKey, {
      'roots': next.roots,
      'extensions': [for (final item in next.extensions) _stored(item)],
    });
    return next;
  }

  Map<String, Object?> _stored(SourceExtension item) => {
    'id': item.id,
    'name': item.name,
    'version': item.version,
    'origin': item.origin,
    'enabled': item.enabled,
    'description': item.description,
    'speed': item.speed,
    'accuracy': item.accuracy,
    'deprecated': item.deprecated,
    'nsfw': item.nsfw,
    'settings': [
      for (final field in item.fields)
        {
          'key': field.key,
          'label': field.label,
          'type': field.type.name,
          'description': field.description,
          'options': [
            for (final option in field.options)
              {'label': option.label, 'value': option.value},
          ],
        },
    ],
    'values': item.settings,
  };
}

abstract class _NativeAdapter {
  bool get requiresMapping => false;
  bool get searchesMappedEpisodes => false;

  Future<List<TorrentResult>> search(
    TorrentQuery query, {
    required bool movie,
    required Map<String, Object?> settings,
  });

  Future<bool> validate();
}

class _NyaaAdapter extends _NativeAdapter {
  _NyaaAdapter(this.http, {required this.adult});

  final _SourceHttp http;
  final bool adult;

  @override
  bool get searchesMappedEpisodes => true;

  String get host => adult ? 'sukebei.nyaa.si' : 'nyaa.si';
  String get tracker => adult
      ? 'http://sukebei.tracker.wf:8888/announce'
      : 'http://nyaa.tracker.wf:7777/announce';

  @override
  Future<List<TorrentResult>> search(
    TorrentQuery query, {
    required bool movie,
    required Map<String, Object?> settings,
  }) async {
    if (movie) return const [];
    final tasks = <Future<List<TorrentResult>>>[
      _query(query, batch: false),
      if ((query.episodeCount ?? 0) > 1) _query(query, batch: true),
    ];
    final groups = await Future.wait(tasks);
    return _dedupe(groups.expand((item) => item));
  }

  Future<List<TorrentResult>> _query(
    TorrentQuery query, {
    required bool batch,
  }) async {
    final titles = query.titles
        .where((item) => item.trim().isNotEmpty)
        .take(8)
        .toList();
    if (titles.isEmpty) return const [];
    final terms = StringBuffer('(${titles.join(')|(')})');
    if ((query.episodeCount ?? 0) > 1) {
      final patterns = batch
          ? _batchPatterns(query.episodeCount!)
          : _episodePatterns(query.episode ?? 1);
      terms.write(patterns.join('|'));
    }
    if (query.exclusions.isNotEmpty) {
      terms.write('-(${query.exclusions.join('|')})');
    }
    final uri = Uri.https(host, '/', {
      'page': 'rss',
      'c': adult ? '1_1' : '1_0',
      'f': '0',
      's': 'seeders',
      'o': 'desc',
      'q': terms.toString(),
    });
    final xml = await http.text(uri);
    final results = <TorrentResult>[];
    for (final match in RegExp(
      r'<item>([\s\S]*?)</item>',
      caseSensitive: false,
    ).allMatches(xml)) {
      final item = match.group(1)!;
      final title = _xmlTag(item, 'title') ?? '?';
      final hash = _xmlTag(item, 'nyaa:infoHash');
      final infoHash = hash?.toLowerCase();
      final enclosure = RegExp(
        r'<enclosure[^>]*?url="([^"]*?)"',
        caseSensitive: false,
      ).firstMatch(item)?.group(1);
      final link = infoHash == null
          ? enclosure ?? _xmlTag(item, 'link') ?? ''
          : 'magnet:?xt=urn:btih:$infoHash&dn=${Uri.encodeQueryComponent(title)}'
                '&tr=${Uri.encodeQueryComponent(tracker)}';
      if (link.isEmpty) continue;
      final trusted = _xmlTag(item, 'nyaa:trusted') == 'Yes';
      final remake = _xmlTag(item, 'nyaa:remake') == 'Yes';
      results.add(
        TorrentResult(
          title: title,
          link: link,
          hash: infoHash,
          seeders: _int(_xmlTag(item, 'nyaa:seeders')) ?? 0,
          leechers: _int(_xmlTag(item, 'nyaa:leechers')) ?? 0,
          downloads: _int(_xmlTag(item, 'nyaa:downloads')) ?? 0,
          size: _size(_xmlTag(item, 'nyaa:size')),
          accuracy: trusted || remake ? 'medium' : 'low',
          type: batch ? 'batch' : null,
          date: DateTime.tryParse(_xmlTag(item, 'pubDate') ?? '')?.toLocal(),
        ),
      );
    }
    return results;
  }

  @override
  Future<bool> validate() async {
    try {
      await http.get(Uri.https(host, '/', {'page': 'rss'}));
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _SeaDexAdapter extends _NativeAdapter {
  _SeaDexAdapter(this.http);

  final _SourceHttp http;

  @override
  Future<List<TorrentResult>> search(
    TorrentQuery query, {
    required bool movie,
    required Map<String, Object?> settings,
  }) async {
    final root = await http.json(
      Uri.https('releases.moe', '/api/collections/entries/records', {
        'page': '1',
        'perPage': '1',
        'filter': 'alID="${query.anilistId}"',
        'skipTotal': '1',
        'expand': 'trs',
      }),
    );
    if (root is! Map || root['items'] is! List) return const [];
    final items = root['items'] as List;
    if (items.isEmpty || items.first is! Map) return const [];
    final expand = (items.first as Map)['expand'];
    if (expand is! Map || expand['trs'] is! List) return const [];
    final results = <TorrentResult>[];
    for (final raw in expand['trs'] as List) {
      if (raw is! Map) continue;
      final hash = _text(raw['infoHash']);
      final files = raw['files'];
      if (hash == null || hash == '<redacted>' || files is! List) continue;
      if ((query.episodeCount ?? 0) > 1 && files.length == 1 && !movie) {
        continue;
      }
      final names = [
        for (final file in files)
          if (file is Map && _text(file['name']) != null) _text(file['name'])!,
      ];
      final size = files.fold<int>(
        0,
        (total, file) => total + (file is Map ? _int(file['length']) ?? 0 : 0),
      );
      final group = _text(raw['releaseGroup']) ?? 'SeaDex';
      final dual = raw['dualAudio'] == true;
      results.add(
        TorrentResult(
          title: names.length == 1
              ? names.first
              : '[$group] ${query.titles.first}${dual ? ' Dual Audio' : ''}',
          link: hash,
          hash: hash.toLowerCase(),
          size: size,
          seeders: 0,
          leechers: 0,
          downloads: 0,
          type: raw['isBest'] == true ? 'best' : 'alt',
          accuracy: 'high',
          date: DateTime.tryParse(_text(raw['created']) ?? '')?.toLocal(),
        ),
      );
    }
    return results;
  }

  @override
  Future<bool> validate() async {
    try {
      await http.get(
        Uri.https('releases.moe', '/api/collections/entries/records', {
          'page': '1',
          'perPage': '1',
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _AnimeToshoAdapter extends _NativeAdapter {
  _AnimeToshoAdapter(this.http, {required this.archive});

  final _SourceHttp http;
  final bool archive;

  @override
  bool get requiresMapping => true;

  List<String> get hosts => archive
      ? const ['feed.animetosho.org']
      : const ['feed.animetosho.xyz', 'feed.animetosho.net'];

  @override
  Future<List<TorrentResult>> search(
    TorrentQuery query, {
    required bool movie,
    required Map<String, Object?> settings,
  }) async {
    final calls = <Future<List<TorrentResult>>>[];
    if (movie) {
      if (query.anidbAid != null) {
        calls.add(_query(query, {'aid': '${query.anidbAid}'}, batch: false));
      }
    } else {
      if (query.anidbEid != null) {
        calls.add(_query(query, {'eid': '${query.anidbEid}'}, batch: false));
      }
      if (query.anidbAid != null && (query.episodeCount ?? 0) > 1) {
        calls.add(
          _query(query, {
            'order': 'size-d',
            'aid': '${query.anidbAid}',
          }, batch: true),
        );
      }
    }
    if (calls.isEmpty) return const [];
    return _dedupe((await Future.wait(calls)).expand((item) => item));
  }

  Future<List<TorrentResult>> _query(
    TorrentQuery query,
    Map<String, String> parameters, {
    required bool batch,
  }) async {
    final q = _toshoFilter(query);
    final full = {...parameters, ...q};
    Object? root;
    Object? lastError;
    for (final host in hosts) {
      try {
        root = await http.json(Uri.https(host, '/json', full));
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (root == null && lastError != null) throw lastError;
    if (root is! List) return const [];
    final results = <TorrentResult>[];
    for (final item in root) {
      if (item is! Map) continue;
      if (batch && (_int(item['num_files']) ?? 0) <= 1) continue;
      final link = _text(item['magnet_uri']);
      final hash = _text(item['info_hash']);
      if (link == null || hash == null) continue;
      var seeders = _int(item['seeders']) ?? 0;
      var leechers = _int(item['leechers']) ?? 0;
      if (seeders >= 30000) seeders = 0;
      if (leechers >= 30000) leechers = 0;
      results.add(
        TorrentResult(
          title: _text(item['title']) ?? _text(item['torrent_name']) ?? '?',
          link: link,
          hash: hash.toLowerCase(),
          seeders: seeders,
          leechers: leechers,
          downloads: _int(item['torrent_downloaded_count']) ?? 0,
          size: _int(item['total_size']),
          accuracy:
              !batch && (item['anidb_fid'] != null || item['anidb_eid'] != null)
              ? 'high'
              : 'medium',
          type: batch ? 'batch' : null,
          date: _epoch(item['timestamp']),
        ),
      );
    }
    return results;
  }

  Map<String, String> _toshoFilter(TorrentQuery query) {
    if (query.exclusions.isEmpty) return const {};
    return {
      'qx': '1',
      'q': '!(${query.exclusions.map((item) => '"$item"').join('|')})',
    };
  }

  @override
  Future<bool> validate() async {
    for (final host in hosts) {
      try {
        await http.get(Uri.https(host, '/json'));
        return true;
      } catch (_) {}
    }
    return false;
  }
}

class _TsukiAdapter extends _NativeAdapter {
  _TsukiAdapter(this.http);

  final _SourceHttp http;
  final Map<String, String> _ids = {};
  static const host = 'api.tsukihime.org';

  @override
  bool get searchesMappedEpisodes => true;

  @override
  Future<List<TorrentResult>> search(
    TorrentQuery query, {
    required bool movie,
    required Map<String, Object?> settings,
  }) async {
    final id = await _resolve(query);
    if (id == null) return const [];
    if (movie) return _query(query, id, movie: true);
    final calls = <Future<List<TorrentResult>>>[
      if (query.episode != null) _query(query, id, episode: query.episode),
      if ((query.episodeCount ?? 0) > 1) _query(query, id, batch: true),
    ];
    if (calls.isEmpty) return const [];
    return _dedupe((await Future.wait(calls)).expand((item) => item));
  }

  Future<String?> _resolve(TorrentQuery query) async {
    final candidates = <(String, int?)>[
      ('anilist', query.anilistId),
      ('anidb', query.anidbAid),
      ('mal', query.idMal),
    ];
    for (final candidate in candidates) {
      final value = candidate.$2;
      if (value == null) continue;
      final key = '${candidate.$1}:$value';
      if (_ids[key] case final cached?) return cached;
      try {
        final root = await _retryJson(
          Uri.https(host, '/v1/animes/${candidate.$1}/$value'),
        );
        if (root is Map && root['id'] != null) {
          final id = '${root['id']}';
          _ids[key] = id;
          return id;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<List<TorrentResult>> _query(
    TorrentQuery query,
    String id, {
    int? episode,
    bool batch = false,
    bool movie = false,
  }) async {
    final path = episode == null
        ? '/v1/animes/$id'
        : '/v1/animes/$id/episodes/$episode';
    final root = await _retryJson(Uri.https(host, path, {'limit': '100'}));
    if (root is! Map || root['results'] is! List) return const [];
    final results = <TorrentResult>[];
    for (final item in root['results'] as List) {
      if (item is! Map) continue;
      final count = _int(item['filecount']) ?? 0;
      if (batch && count <= 1) continue;
      if (movie && count > 1) continue;
      var title = _text(item['name']) ?? '?';
      final audio = _stringList(item['audiolangs']);
      if (audio.length > 1 && !title.toLowerCase().contains('dual')) {
        title = '$title Dual Audio';
      }
      if (!_titleAllowed(title, query)) continue;
      final hash = _text(item['btih']);
      if (hash == null) continue;
      results.add(
        TorrentResult(
          title: title,
          link:
              'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeQueryComponent(title)}',
          hash: hash.toLowerCase(),
          size: _int(item['totalsize']),
          seeders: 0,
          leechers: 0,
          downloads: 0,
          accuracy: batch ? 'medium' : 'low',
          type: batch || (count != 1 && title.toLowerCase().contains('batch'))
              ? 'batch'
              : null,
          date: _epoch(item['source_date']),
          audioLanguages: audio,
        ),
      );
    }
    return results;
  }

  Future<Object?> _retryJson(Uri uri) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await http.json(uri);
      } catch (error) {
        last = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
    }
    throw last ?? StateError('TsukiHime request failed.');
  }

  @override
  Future<bool> validate() async {
    try {
      await _retryJson(Uri.https(host, '/v1/stats'));
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _NekoBtAdapter extends _NativeAdapter {
  _NekoBtAdapter(this.http);

  final _SourceHttp http;
  static const host = 'nekobt.to';
  final Map<String, String> _mediaIds = {};

  @override
  bool get requiresMapping => true;

  @override
  Future<List<TorrentResult>> search(
    TorrentQuery query, {
    required bool movie,
    required Map<String, Object?> settings,
  }) async {
    final mediaId = await _resolveMedia(query);
    if (mediaId == null) return const [];
    String? episodeId;
    if (!movie && query.episode != null) {
      episodeId = await _resolveEpisode(mediaId, query);
      if (episodeId == null && (query.episodeCount ?? 0) > 1) return const [];
    }
    final parameters = <String, String>{
      'media_id': mediaId,
      'sort_by': 'seeders',
      'limit': '100',
      'episode_ids': ?episodeId,
    };
    final subtitles = _stringList(settings['subtitleLanguage']);
    final audio = _stringList(settings['audioLanguage']);
    if (subtitles.isNotEmpty) {
      parameters['sub_lang'] = subtitles.join(',');
      parameters['fansub_lang'] = subtitles.join(',');
    }
    if (audio.isNotEmpty) {
      parameters['audio_lang'] = audio.join(',');
    }
    final root = await http.json(
      Uri.https(host, '/api/v1/torrents/search', parameters),
    );
    final rows = _nestedResults(root);
    final results = <TorrentResult>[];
    for (final item in rows) {
      var title = _text(item['title']) ?? _text(item['auto_title']) ?? '?';
      title = title.replaceAll(RegExp(r'\s*\{Tags:[^}]*\}'), '');
      final languages = (_text(item['audio_lang']) ?? '')
          .split(',')
          .where((value) => value.isNotEmpty)
          .toList();
      if (languages.length > 1 && !title.toLowerCase().contains('dual')) {
        title = '$title Dual Audio';
      }
      if (!_titleAllowed(title, query)) continue;
      final magnet = _text(item['magnet']);
      final hash = _text(item['infohash']);
      if (magnet == null || hash == null) continue;
      final episodeIds = item['media_episode_ids'] is List
          ? item['media_episode_ids'] as List
          : const [];
      final batch = item['batch'] == true;
      if (movie && episodeIds.isNotEmpty) continue;
      results.add(
        TorrentResult(
          title: title,
          link: magnet,
          hash: hash.toLowerCase(),
          seeders: _int(item['seeders']) ?? 0,
          leechers: _int(item['leechers']) ?? 0,
          downloads: _int(item['completed']) ?? 0,
          size: _int(item['filesize']),
          accuracy: query.tvdbEid != null && episodeIds.length == 1
              ? 'high'
              : batch
              ? 'medium'
              : 'low',
          type: batch && episodeIds.length > 1 ? 'batch' : null,
          date: _epoch(item['uploaded_at']),
          audioLanguages: languages,
          subtitleLanguages: {
            ...(_text(item['sub_lang']) ?? '').split(','),
            ...(_text(item['fsub_lang']) ?? '').split(','),
          }.where((value) => value.trim().isNotEmpty).toList(),
        ),
      );
    }
    return results;
  }

  Future<String?> _resolveMedia(TorrentQuery query) async {
    final identity = '${query.tvdbAid}:${query.tmdbId}:${query.imdbId}';
    if (_mediaIds[identity] case final cached?) return cached;
    final titles = query.titles.take(3).toList(growable: false);
    final searches = [
      for (final title in titles)
        http.json(
          Uri.https(host, '/api/v1/media/search', {
            'query': title,
            'limit': '50',
          }),
        ),
    ];
    final responses = await Future.wait(
      searches.map((future) => future.catchError((_) => null)),
    );
    Map? similar;
    for (final response in responses) {
      for (final item in _nestedResults(response)) {
        final exact =
            (query.tvdbAid != null && _int(item['tvdbId']) == query.tvdbAid) ||
            (query.tmdbId != null && _int(item['tmdbId']) == query.tmdbId) ||
            (query.imdbId != null && _text(item['imdbId']) == query.imdbId);
        if (exact && item['id'] != null) {
          return _mediaIds[identity] = '${item['id']}';
        }
        if (similar == null && item['similarity'] == 1 && item['id'] != null) {
          similar = item;
        }
      }
    }
    return similar == null ? null : '${similar['id']}';
  }

  Future<String?> _resolveEpisode(String mediaId, TorrentQuery query) async {
    final root = await http.json(Uri.https(host, '/api/v1/media/$mediaId'));
    if (root is! Map || root['data'] is! Map) return null;
    final episodes = (root['data'] as Map)['episodes'];
    if (episodes is! List) return null;
    for (final item in episodes) {
      if (item is! Map) continue;
      final tvdb =
          query.tvdbEid != null && _int(item['tvdbId']) == query.tvdbEid;
      final mapped =
          query.season != null &&
          query.absoluteEpisode != null &&
          _int(item['season']) == query.season &&
          (_int(item['absolute']) == query.absoluteEpisode ||
              (item['absolute'] == null &&
                  _int(item['episode']) == query.absoluteEpisode));
      if ((tvdb || mapped) && item['id'] != null) return '${item['id']}';
    }
    return null;
  }

  @override
  Future<bool> validate() async {
    try {
      await http.get(Uri.https(host, '/api/v1/stats'));
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _SourceHttp {
  const _SourceHttp(this.transport);

  final HttpTransport transport;

  Future<HttpResponse> get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 9),
  }) async {
    final response = await transport.send(
      HttpRequest(
        HttpMethod.get,
        uri,
        timeout: timeout,
        headers: const {
          'accept': 'application/json, application/rss+xml, text/xml;q=0.9',
          'user-agent': 'Zero/0.1',
        },
      ),
    );
    if (!response.ok) {
      throw StateError('Source request failed (${response.status}).');
    }
    return response;
  }

  Future<Object?> json(
    Uri uri, {
    Duration timeout = const Duration(seconds: 9),
  }) async =>
      jsonDecode(utf8.decode((await get(uri, timeout: timeout)).bodyBytes));

  Future<String> text(Uri uri) async => utf8.decode((await get(uri)).bodyBytes);
}

class _SourceSearchTimeout implements Exception {
  const _SourceSearchTimeout();
}

List<Map> _nestedResults(Object? root) {
  if (root is! Map) return const [];
  final data = root['data'];
  final results = data is Map ? data['results'] : null;
  return results is List ? results.whereType<Map>().toList() : const [];
}

List<TorrentResult> _dedupe(Iterable<TorrentResult> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (seen.add((value.hash ?? value.link).toLowerCase())) value,
  ];
}

bool _titleAllowed(String title, TorrentQuery query) {
  final lower = title.toLowerCase();
  return !query.exclusions.any((item) => lower.contains(item.toLowerCase()));
}

DateTime? _epoch(Object? value) {
  final seconds = _int(value);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
}

int? _size(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^([\d.]+)\s*(TiB|GiB|MiB|KiB|B)$').firstMatch(value);
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!);
  if (amount == null) return null;
  final multiplier = switch (match.group(2)) {
    'TiB' => 1024 * 1024 * 1024 * 1024,
    'GiB' => 1024 * 1024 * 1024,
    'MiB' => 1024 * 1024,
    'KiB' => 1024,
    _ => 1,
  };
  return (amount * multiplier).round();
}

String? _xmlTag(String xml, String tag) {
  final escaped = RegExp.escape(tag);
  final match = RegExp(
    '<$escaped>([\\s\\S]*?)</$escaped>',
    caseSensitive: false,
  ).firstMatch(xml);
  if (match == null) return null;
  return _decodeXml(match.group(1)!.trim());
}

String _decodeXml(String value) => value
    .replaceFirst(RegExp(r'^<!\[CDATA\['), '')
    .replaceFirst(RegExp(r'\]\]>$'), '')
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.parse(match.group(1)!)),
    )
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#39;', "'");

List<String> _episodePatterns(int episode) {
  final padded = episode.toString().padLeft(2, '0');
  return {
    '"EP$padded+"',
    '"EP$episode+"',
    '"E$padded+"',
    '"E$episode+"',
    '"E${padded}v"',
    '"E${episode}v"',
    '"EP${padded}v"',
    '"EP${episode}v"',
    '"+$padded+"',
    '"+${padded}v"',
    '"_EP${padded}_"',
    '"_EP${episode}_"',
    '"_E${padded}_"',
    '"_E${episode}_"',
    '"_${padded}_"',
  }.toList(growable: false);
}

List<String> _batchPatterns(int count) {
  final digits = count.toString().length.clamp(2, 20);
  final first = '1'.padLeft(digits, '0');
  final last = '$count'.padLeft(digits, '0');
  return {
    '"$first-$last"',
    '"1-$last"',
    '"$first-$count"',
    '"1-$count"',
    '"$first ~ $last"',
    '"1 ~ $last"',
    '"$first~$last"',
    '"1~$count"',
    '"Batch"',
    '"Complete"',
  }.toList(growable: false);
}

String? _text(Object? value) {
  if (value is! String) return value is num ? '$value' : null;
  final result = value.trim();
  return result.isEmpty ? null : result;
}

int? _int(Object? value) {
  if (value is num) return value.round();
  return value is String ? num.tryParse(value)?.round() : null;
}

List<String> _stringList(Object? value) => value is List
    ? value.map(_text).whereType<String>().toList(growable: false)
    : const [];

String _safeError(Object? error) {
  if (error == null) return 'Unknown source error.';
  final text = '$error';
  return text
      .replaceAll(RegExp(r'https?://\S+'), 'the source endpoint')
      .replaceAll(
        RegExp(
          r'(api[_-]?key|token|bearer)\s*[:=]\s*\S+',
          caseSensitive: false,
        ),
        '[credential redacted]',
      );
}
