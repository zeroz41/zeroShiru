import 'dart:async';

import '../../../domain/models/availability.dart';
import '../../../domain/ports/debrid_client.dart';
import '../../network/transport.dart';
import '../client.dart';
import '../errors.dart';
import '../hash.dart';
import '../window.dart';
import 'json.dart';
import 'provider.dart';

const _api = 'https://api.torbox.app/v1/api';
const _accountTimeoutMs = 10000;
// The selected episode is requested first. Give already-finishing neighbors a
// tiny window for playlist continuity without holding playback for seconds.
const _optionalLinkGraceMs = 150;
const _listLimit = 1000;
const _seedNever = 3;

const _messages = <String, String>{
  'BAD_TOKEN': 'Invalid TorBox API key',
  'AUTH_ERROR': 'TorBox rejected the API key',
  'NO_AUTH': 'TorBox requires an API key for this request',
  'PLAN_RESTRICTED_FEATURE':
      'This TorBox plan does not include the feature zeroShiru needs',
  'ACTIVE_LIMIT': 'Too many active TorBox downloads, wait for one to finish',
  'MONTHLY_LIMIT': 'This TorBox account has reached its monthly limit',
  'COOLDOWN_LIMIT': 'TorBox is cooling this account down, try again shortly',
  'DOWNLOAD_TOO_LARGE': 'This release is larger than the TorBox plan allows',
  'DOWNLOAD_SERVER_ERROR':
      'TorBox could not reach its download server, try again shortly',
  'NO_SERVERS_AVAILABLE_ERROR':
      'No TorBox download servers are available right now',
};

const _authCodes = {
  'BAD_TOKEN',
  'AUTH_ERROR',
  'NO_AUTH',
  'PLAN_RESTRICTED_FEATURE',
};

class _TorBoxDialect extends Dialect {
  const _TorBoxDialect();

  @override
  Object? unwrap(Object? json) {
    final envelope = jsonMap(json);
    if (!envelope.containsKey('success')) return json;
    if (envelope['success'] != true) throw mapError(200, json);
    return envelope['data'];
  }

  @override
  DebridFailure mapError(int status, Object? json) {
    final code = jsonString(field(json, 'error'));
    final message =
        _messages[code] ??
        safeServiceMessage(
          jsonString(field(json, 'detail')),
          code ?? 'Request failed with status $status',
        );
    final auth =
        (code != null && _authCodes.contains(code)) ||
        ((status == 401 || status == 403) && code == null);
    return auth
        ? DebridFailure.auth(message, status: status, code: code)
        : DebridFailure.service(message, status: status, code: code);
  }
}

class _WantedFile {
  const _WantedFile({
    required this.id,
    required this.path,
    required this.size,
    this.mime,
  });

  final int id;
  final String path;
  final int size;
  final String? mime;
}

class TorBoxProvider implements DebridProvider {
  TorBoxProvider(String apiKey, HttpTransport transport, Clock clock)
    : client = DebridApiClient(providerConfig, apiKey, transport, clock);

  static const providerConfig = ProviderConfig(
    id: 'torbox',
    title: 'TorBox',
    auth: AuthScheme.bearer,
    authParam: 'token',
    encoding: BodyEncoding.form,
    nominalLatencyMs: 300,
    maxFiles: 12,
    availabilityCheck: AvailabilityCheck.batch,
    checkAddsMagnets: false,
    maxBatch: 75,
    maxProbes: 10,
    maxConcurrent: 3,
    minTimeMs: 200,
    reservoir: (300, 60000),
  );

  static const _dialect = _TorBoxDialect();

  @override
  final DebridApiClient client;

  @override
  ProviderConfig get config => providerConfig;

  @override
  bool throttled(DebridFailure error) => error.throttled;

  Future<Object?> _request(
    String url, [
    RequestOpts opts = const RequestOpts(),
    CancelToken? cancel,
  ]) => client.request(_dialect, url, opts, cancel: cancel);

  Future<List<Object?>> _accountTorrents({
    Object? id,
    bool fresh = false,
    CancelToken? cancel,
  }) async {
    final query = <String>['limit=$_listLimit'];
    if (id != null) query.add('id=${Uri.encodeQueryComponent(_valueText(id))}');
    if (fresh) query.add('bypass_cache=true');
    final data = await _request(
      '$_api/torrents/mylist?${query.join('&')}',
      const RequestOpts(timeoutMs: _accountTimeoutMs),
      cancel,
    );
    if (data == null) return const [];
    return data is List ? jsonList(data) : [data];
  }

  Future<List<Object?>> _listing({CancelToken? cancel}) async {
    final value = await client.listing(
      false,
      () async => _accountTorrents(cancel: cancel),
    );
    return jsonList(value);
  }

  Future<Object?> _existingTorrent(String hash, {CancelToken? cancel}) async {
    for (final torrent in await _listing(cancel: cancel)) {
      if (_torrentHash(torrent) == hash) return torrent;
    }
    return null;
  }

  Future<(Object?, bool)> _add(
    String magnet,
    String hash, {
    CancelToken? cancel,
  }) async {
    Object? created;
    try {
      created = await _request(
        '$_api/torrents/createtorrent',
        RequestOpts(
          method: HttpMethod.post,
          encoding: BodyEncoding.multipart,
          body: [
            ('magnet', magnet),
            ('seed', _seedNever),
            ('allow_zip', false),
          ],
        ),
        cancel,
      );
    } on DebridFailure catch (error) {
      if (error.code != 'DUPLICATE_ITEM') rethrow;
    }
    final id = field(created, 'torrent_id');
    final owns = id != null;
    try {
      final torrent = await _awaitTorrent(id: id, hash: hash, cancel: cancel);
      client.amendListing(
        torrent,
        (ours, theirs) =>
            _torrentHash(ours) != null &&
            _torrentHash(ours) == _torrentHash(theirs),
      );
      return (torrent, owns);
    } catch (_) {
      if (owns) {
        await _delete(id);
        client.forgetListing();
      }
      rethrow;
    }
  }

  Future<Object?> _awaitTorrent({
    Object? id,
    required String hash,
    CancelToken? cancel,
  }) async {
    final started = client.clock.nowMs;
    Object? last;
    while (true) {
      final entries = await _accountTorrents(
        id: id,
        fresh: true,
        cancel: cancel,
      );
      if (id == null) {
        last = null;
        for (final entry in entries) {
          if (_torrentHash(entry) == hash) {
            last = entry;
            break;
          }
        }
      } else {
        last = entries.isEmpty ? null : entries.first;
      }
      if (last != null &&
          _torrentAvailability(last) != Availability.available) {
        return last;
      }
      if (client.clock.nowMs - started >
          client.budget(config.timeouts.readyMs)) {
        if (last == null) {
          throw const DebridFailure.service(
            'TorBox did not report the torrent back after adding it',
          );
        }
        return last;
      }
      await raced(client.clock.sleepMs(config.timeouts.pollMs), cancel);
    }
  }

  Future<DebridFileInfo?> _requestLink(
    Object? torrentId,
    _WantedFile file, {
    CancelToken? cancel,
  }) async {
    final url =
        '$_api/torrents/requestdl?'
        'torrent_id=${Uri.encodeQueryComponent(_valueText(torrentId))}&'
        'file_id=${file.id}&redirect=false';
    final data = await _request(
      url,
      const RequestOpts(auth: AuthScheme.query, authParam: 'token'),
      cancel,
    );
    final link = nonEmptyString(data);
    return link == null
        ? null
        : DebridFileInfo(
            name: basename(file.path),
            path: file.path,
            size: file.size,
            url: link,
            type: file.mime,
          );
  }

  Future<List<DebridFileInfo>> _requestLinks(
    Object? torrentId,
    List<_WantedFile> wanted,
    String? targetPath, {
    CancelToken? cancel,
  }) async {
    var targetIndex = 0;
    if (targetPath != null) {
      final found = wanted.indexWhere((file) => file.path == targetPath);
      if (found >= 0) targetIndex = found;
    }
    final targetFuture = _requestLink(
      torrentId,
      wanted[targetIndex],
      cancel: cancel,
    );
    final neighborCancel = CancelToken();
    final stopCancelWatch = Completer<void>();
    final cancelWatch = cancel
        ?.race(stopCancelWatch.future)
        .then<void>((_) {}, onError: (Object _) => neighborCancel.cancel());
    final neighbors = <DebridFileInfo>[];
    DebridFailure? fatal;
    final work = <Future<void>>[];
    for (var index = 0; index < wanted.length; index++) {
      if (index == targetIndex) continue;
      final file = wanted[index];
      work.add(() async {
        try {
          final linked = await _requestLink(
            torrentId,
            file,
            cancel: neighborCancel,
          );
          if (linked != null) neighbors.add(linked);
        } on DebridFailure catch (error) {
          if (error.kind == DebridErrorKind.auth) fatal ??= error;
        } on CancelledException {
          // The selected link already won or the whole play moved on.
        }
      }());
    }
    final allNeighbors = Future.wait(work);
    DebridFileInfo? target;
    try {
      target = await targetFuture;
      var neighborsDone = false;
      final completed = allNeighbors.then((_) => neighborsDone = true);
      await Future.any([
        completed,
        raced(client.clock.sleepMs(_optionalLinkGraceMs), cancel),
      ]);
      if (!neighborsDone) neighborCancel.cancel();
    } finally {
      neighborCancel.cancel();
      if (!stopCancelWatch.isCompleted) stopCancelWatch.complete();
      await cancelWatch;
      await allNeighbors;
    }
    if (target == null) {
      throw const DebridFailure.service(
        'TorBox returned no link for the selected file',
      );
    }
    if (fatal != null) throw fatal!;

    final files = [target, ...neighbors];
    final order = {
      for (var index = 0; index < wanted.length; index++)
        wanted[index].path: index,
    };
    files.sort(
      (a, b) => (order[a.path] ?? wanted.length).compareTo(
        order[b.path] ?? wanted.length,
      ),
    );
    return files;
  }

  static (String, RequestOpts) _deleteRequest(Object? id) => (
    '$_api/torrents/controltorrent',
    RequestOpts(
      method: HttpMethod.post,
      encoding: BodyEncoding.json,
      body: [('torrent_id', id), ('operation', 'delete')],
    ),
  );

  Future<void> _delete(Object? id) async {
    final (url, opts) = _deleteRequest(id);
    await client.release(_dialect, url, opts);
  }

  @override
  Future<AccountInfo> validate({CancelToken? cancel}) async {
    Object? user;
    try {
      user = await _request(
        '$_api/user/me?settings=false',
        const RequestOpts(timeoutMs: _accountTimeoutMs),
        cancel,
      );
    } on DebridFailure catch (error) {
      if (error.kind != DebridErrorKind.timeout &&
          error.kind != DebridErrorKind.service) {
        rethrow;
      }
      try {
        await _listing(cancel: cancel);
        return const AccountInfo(username: 'TorBox user');
      } catch (_) {
        throw error;
      }
    }
    if (user == null) {
      throw const DebridFailure.auth('TorBox did not recognise this API key');
    }
    return AccountInfo(
      username:
          nonEmptyString(field(user, 'email')) ??
          nonEmptyString(field(user, 'customer')) ??
          'TorBox user',
      expires: jsonString(field(user, 'premium_expires_at')),
    );
  }

  @override
  Future<Map<String, Availability>> listAvailability({
    CancelToken? cancel,
  }) async {
    final known = <String, Availability>{};
    for (final torrent in await _listing(cancel: cancel)) {
      final hash = _torrentHash(torrent);
      if (hash == null) continue;
      known[hash] = _torrentAvailability(torrent);
      final name = jsonString(field(torrent, 'name'));
      if (name != null) client.rememberRelease(hash, name);
    }
    return known;
  }

  @override
  Future<Map<String, Availability>> checkAvailabilityBatch(
    List<String> hashes, {
    CancelToken? cancel,
  }) async {
    final query = [for (final hash in hashes) 'hash=$hash'].join('&');
    final data = await _request(
      '$_api/torrents/checkcached?$query&format=list',
      const RequestOpts(),
      cancel,
    );
    final entries = <Object?>[];
    if (data is List) {
      entries.addAll(data);
    } else if (data is Map) {
      for (final raw in data.entries) {
        final entry = Map<String, Object?>.from(jsonMap(raw.value));
        entry.putIfAbsent('hash', () => '${raw.key}');
        entries.add(entry);
      }
    }
    final answers = {for (final hash in hashes) hash: Availability.available};
    for (final entry in entries) {
      final hash = (jsonString(field(entry, 'hash')) ?? '').toLowerCase();
      if (!answers.containsKey(hash)) continue;
      answers[hash] = Availability.cached;
      final name = jsonString(field(entry, 'name'));
      if (name != null) client.rememberRelease(hash, name);
    }
    return answers;
  }

  /// TorBox can return cached member names as part of the same inexpensive
  /// cache lookup. The picker uses them to prove a batch contains the episode
  /// before it can be selected.
  Future<Map<String, DebridAvailabilityDetail>> inspectAvailabilityBatch(
    List<String> hashes, {
    CancelToken? cancel,
  }) async {
    final query = [for (final hash in hashes) 'hash=$hash'].join('&');
    final data = await _request(
      '$_api/torrents/checkcached?$query&format=list&list_files=true',
      const RequestOpts(),
      cancel,
    );
    final entries = _cacheEntries(data);
    final answers = {
      for (final hash in hashes)
        hash: const DebridAvailabilityDetail(Availability.available),
    };
    for (final entry in entries) {
      final hash = (jsonString(field(entry, 'hash')) ?? '').toLowerCase();
      if (!answers.containsKey(hash)) continue;
      answers[hash] = DebridAvailabilityDetail(
        Availability.cached,
        files: _cachedFiles(entry),
      );
      final name = jsonString(field(entry, 'name'));
      if (name != null) client.rememberRelease(hash, name);
    }
    return answers;
  }

  @override
  Future<Availability> probeAvailability(String hash, {CancelToken? cancel}) =>
      Future.error(
        const DebridFailure.service(
          'TorBox answers availability in batches, probing is not needed',
        ),
      );

  @override
  Future<ResolvedFiles> resolve(
    String magnet,
    ResolveOptions opts, {
    CancelToken? cancel,
  }) async {
    final hash = parseHash(magnet);
    final magnetUri = toMagnet(magnet);
    if (hash == null || magnetUri == null) {
      throw const DebridFailure.service(
        'TorBox needs a magnet link or info hash to resolve',
      );
    }
    Object? torrent = await _existingTorrent(hash, cancel: cancel);
    var added = false;
    final guard = OrphanGuard(client);
    try {
      if (torrent == null) {
        if (client.recall(hash) != Availability.cached) {
          final checked = await checkAvailabilityBatch([hash], cancel: cancel);
          if (checked[hash] != Availability.cached) {
            throw const DebridFailure.notCached();
          }
        }
        final created = await _add(magnetUri, hash, cancel: cancel);
        torrent = created.$1;
        added = created.$2;
        final id = field(torrent, 'id');
        if (added && id != null) {
          final (url, deleteOpts) = _deleteRequest(id);
          guard.arm(url, deleteOpts);
        }
      }
      final availability = _torrentAvailability(torrent);
      if (availability == Availability.unavailable) {
        final state =
            nonEmptyString(field(torrent, 'download_state')) ?? 'failed';
        throw DebridFailure.unavailable(
          'TorBox could not process this torrent ($state)',
        );
      }
      if (availability != Availability.cached) {
        throw const DebridFailure.notCached();
      }

      final wanted = <_WantedFile>[
        for (final file in jsonList(field(torrent, 'files')))
          if (opts.fileFilter == null || opts.fileFilter!(_filePath(file)))
            _WantedFile(
              id: jsonInt(field(file, 'id')) ?? 0,
              path: _filePath(file),
              size: jsonInt(field(file, 'size')) ?? 0,
              mime: jsonString(field(file, 'mimetype')),
            ),
      ];
      if (wanted.isEmpty) {
        throw const DebridFailure.service('No playable files in this torrent');
      }
      final target = opts.pickFile == null
          ? _largestWanted(wanted)
          : opts.pickFile!([
              for (final file in wanted) (file.id, file.path, file.size),
            ]);
      final targetPath = target == null || target >= wanted.length
          ? null
          : wanted[target].path;
      final windowed = windowFiles(
        wanted,
        target,
        opts.maxFiles ?? config.maxFiles,
      );
      final files = await _requestLinks(
        field(torrent, 'id'),
        windowed,
        targetPath,
        cancel: cancel,
      );
      if (files.isEmpty) {
        throw const DebridFailure.service(
          'TorBox returned no links for this torrent',
        );
      }
      final resolved = ResolvedFiles(
        hash: _torrentHash(torrent) ?? hash,
        name: jsonString(field(torrent, 'name')) ?? '',
        files: secureFiles(files, config.title),
        targetPath: targetPath,
      );
      guard.disarm();
      return resolved;
    } on CancelledException {
      guard.settle();
      rethrow;
    } catch (_) {
      guard.disarm();
      if (added) await _delete(field(torrent, 'id'));
      rethrow;
    }
  }

  @override
  Future<void> retryCleanup() => client.retryCleanup(_dialect);
}

Availability _torrentAvailability(Object? torrent) {
  final finished =
      jsonTruthy(field(torrent, 'download_finished')) &&
      jsonDouble(field(torrent, 'progress')) == 1;
  if (jsonTruthy(field(torrent, 'download_present')) || finished) {
    return Availability.cached;
  }
  final state = (jsonString(field(torrent, 'download_state')) ?? '')
      .toLowerCase();
  if (const ['stalled', 'error', 'failed', 'missing'].any(state.contains)) {
    return Availability.unavailable;
  }
  return Availability.available;
}

String _filePath(Object? file) => rootedPath(
  nonEmptyString(field(file, 'name')) ??
      nonEmptyString(field(file, 'short_name')) ??
      '',
);

String? _torrentHash(Object? torrent) =>
    nonEmptyString(field(torrent, 'hash'))?.toLowerCase();

String _valueText(Object? value) => switch (value) {
  String text => text,
  num number => number.toString(),
  _ => '$value',
};

int _largestWanted(List<_WantedFile> files) {
  var best = 0;
  for (var index = 1; index < files.length; index++) {
    if (files[index].size > files[best].size) best = index;
  }
  return best;
}

List<Object?> _cacheEntries(Object? data) {
  if (data is List) return jsonList(data);
  if (data is! Map) return const [];
  return [
    for (final raw in data.entries)
      (() {
        final entry = Map<String, Object?>.from(jsonMap(raw.value));
        entry.putIfAbsent('hash', () => '${raw.key}');
        return entry;
      })(),
  ];
}

List<DebridCachedFile>? _cachedFiles(Object? entry) {
  final raw = field(entry, 'files');
  if (raw == null) return null;
  if (raw is! List) return const [];
  return [
    for (final file in raw)
      if (file is String && file.trim().isNotEmpty)
        DebridCachedFile(path: file.trim())
      else if (file is Map &&
          (nonEmptyString(field(file, 'name')) ??
                  nonEmptyString(field(file, 'path'))) !=
              null)
        DebridCachedFile(
          path:
              nonEmptyString(field(file, 'name')) ??
              nonEmptyString(field(file, 'path'))!,
          size:
              jsonInt(field(file, 'size')) ??
              jsonInt(field(file, 'length')) ??
              0,
        ),
  ];
}
