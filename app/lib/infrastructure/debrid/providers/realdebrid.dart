import '../../../domain/models/availability.dart';
import '../../../domain/ports/debrid_client.dart';
import '../../network/transport.dart';
import '../client.dart';
import '../errors.dart';
import '../hash.dart';
import '../window.dart';
import 'json.dart';
import 'provider.dart';

const _api = 'https://api.real-debrid.com/rest/1.0';
const _listLimit = 1000;
const _probeConversionReads = 2;

const _errorMessages = <int, String>{
  8: 'Invalid Real-Debrid API key',
  9: 'Real-Debrid denied the request, check the account permissions',
  21: 'Too many active Real-Debrid downloads, wait for one to finish',
  23: 'This Real-Debrid account has exhausted its traffic',
  34: 'Real-Debrid is rate limiting this account, try again shortly',
  35: 'Real-Debrid will not serve this file, pick a different release',
  36: 'Real-Debrid fair usage limit reached',
};

class _RealDebridDialect extends Dialect {
  const _RealDebridDialect();

  @override
  DebridFailure mapError(int status, Object? json) {
    final numericCode = jsonInt(field(json, 'error_code'));
    final code = numericCode?.toString();
    final message =
        _errorMessages[numericCode] ??
        safeServiceMessage(
          jsonString(field(json, 'error')),
          'Request failed with status $status',
        );
    final auth =
        numericCode == 8 ||
        numericCode == 9 ||
        ((status == 401 || status == 403) && numericCode == null);
    return auth
        ? DebridFailure.auth(message, status: status, code: code)
        : DebridFailure.service(message, status: status, code: code);
  }
}

class _TorrentFile {
  const _TorrentFile({
    required this.id,
    required this.path,
    required this.bytes,
    required this.selected,
  });

  final int id;
  final String path;
  final int bytes;
  final bool selected;
}

class _TorrentInfo {
  const _TorrentInfo({
    required this.id,
    required this.hash,
    required this.filename,
    required this.status,
    required this.files,
    required this.links,
  });

  final String id;
  final String hash;
  final String filename;
  final String status;
  final List<_TorrentFile> files;
  final List<String> links;
}

class _Wanted {
  const _Wanted({required this.id, required this.path, required this.size});

  final int id;
  final String path;
  final int size;
}

class _Candidate {
  const _Candidate({required this.link, this.path, required this.size});

  final String link;
  final String? path;
  final int size;
}

class RealDebridProvider implements DebridProvider {
  RealDebridProvider(String apiKey, HttpTransport transport, Clock clock)
    : client = DebridApiClient(providerConfig, apiKey, transport, clock);

  static const providerConfig = ProviderConfig(
    id: 'realdebrid',
    title: 'Real-Debrid',
    auth: AuthScheme.bearer,
    authParam: 'apikey',
    encoding: BodyEncoding.form,
    nominalLatencyMs: 300,
    maxFiles: 60,
    availabilityCheck: AvailabilityCheck.probe,
    checkAddsMagnets: true,
    maxBatch: 100,
    maxProbes: 10,
    maxConcurrent: 4,
    minTimeMs: 150,
    reservoir: (200, 60000),
  );

  static const _dialect = _RealDebridDialect();

  @override
  final DebridApiClient client;

  @override
  ProviderConfig get config => providerConfig;

  @override
  bool throttled(DebridFailure error) =>
      error.throttled || error.code == '21' || error.code == '34';

  Future<Object?> _get(String url, {CancelToken? cancel}) =>
      client.request(_dialect, url, const RequestOpts(), cancel: cancel);

  Future<Object?> _post(
    String url,
    List<(String, Object?)> body, {
    CancelToken? cancel,
  }) => client.request(
    _dialect,
    url,
    RequestOpts(method: HttpMethod.post, body: body),
    cancel: cancel,
  );

  static (String, RequestOpts) _deleteRequest(String id) => (
    '$_api/torrents/delete/$id',
    const RequestOpts(method: HttpMethod.delete),
  );

  Future<void> _release(String id) async {
    final (url, opts) = _deleteRequest(id);
    await client.release(_dialect, url, opts);
  }

  Future<Object?> _fetchListing({CancelToken? cancel}) => client.listing(
    false,
    () => _get('$_api/torrents?limit=$_listLimit', cancel: cancel),
  );

  Future<_TorrentInfo?> _existingTorrent(
    String? hash, {
    CancelToken? cancel,
  }) async {
    if (hash == null) return null;
    final listing = await _fetchListing(cancel: cancel);
    String? id;
    for (final torrent in jsonList(listing)) {
      if ((jsonString(field(torrent, 'hash')) ?? '').toLowerCase() == hash) {
        id = jsonString(field(torrent, 'id'));
        break;
      }
    }
    if (id == null) return null;
    try {
      return _parseInfo(await _get('$_api/torrents/info/$id', cancel: cancel));
    } on DebridFailure catch (error) {
      if (error.status == 404) {
        client.forgetListing();
        return null;
      }
      rethrow;
    }
  }

  Future<void> _selectFiles(
    String id,
    List<int> ids, {
    CancelToken? cancel,
  }) async {
    final files = ids.isEmpty ? 'all' : ids.join(',');
    await _post('$_api/torrents/selectFiles/$id', [
      ('files', files),
    ], cancel: cancel);
  }

  Future<String> _addAndSelect(
    String magnet, {
    FileFilter? fileFilter,
    int? fileId,
    int? reads,
    CancelToken? cancel,
  }) async {
    final added = await _post('$_api/torrents/addMagnet', [
      ('magnet', magnet),
    ], cancel: cancel);
    final id = nonEmptyString(field(added, 'id'));
    if (id == null) {
      throw const DebridFailure.service('Real-Debrid returned no torrent id');
    }
    client.forgetListing();
    final guard = OrphanGuard(client);
    final (deleteUrl, deleteOpts) = _deleteRequest(id);
    guard.arm(deleteUrl, deleteOpts);
    try {
      final info = await _awaitStatus(
        id,
        'waiting_files_selection',
        client.budget(config.timeouts.selectMs),
        reads: reads,
        cancel: cancel,
      );
      if (info.status == 'waiting_files_selection') {
        final ids = fileId == null
            ? [
                for (final file in info.files)
                  if (fileFilter == null || fileFilter(file.path)) file.id,
              ]
            : [fileId];
        await _selectFiles(id, ids, cancel: cancel);
      }
      guard.disarm();
      return id;
    } on CancelledException {
      guard.settle();
      rethrow;
    } catch (_) {
      guard.disarm();
      await _release(id);
      rethrow;
    }
  }

  Future<_TorrentInfo> _awaitStatus(
    String id,
    String wanted,
    int timeoutMs, {
    int? reads,
    CancelToken? cancel,
  }) async {
    final started = client.clock.nowMs;
    var read = 0;
    while (true) {
      read += 1;
      final info = _parseInfo(
        await _get('$_api/torrents/info/$id', cancel: cancel),
      );
      if (info.status == wanted ||
          (wanted == 'waiting_files_selection' &&
              info.status == 'downloaded')) {
        return info;
      }
      final settled = _unstreamable(info.status);
      if (settled != null) throw settled;
      if ((reads != null && read >= reads) ||
          client.clock.nowMs - started > timeoutMs) {
        throw DebridFailure.timeout(
          'Timed out waiting for Real-Debrid (${info.status})',
        );
      }
      await raced(client.clock.sleepMs(config.timeouts.pollMs), cancel);
    }
  }

  Future<List<DebridFileInfo>> _unrestrictLinks(
    _TorrentInfo info,
    FileFilter filter,
    int maxFiles,
    _Wanted? target, {
    CancelToken? cancel,
  }) async {
    if (info.links.isEmpty) {
      throw const DebridFailure.service(
        'Real-Debrid returned no links for this torrent',
      );
    }
    final selected = [
      for (final file in info.files)
        if (file.selected) file,
    ];
    final aligned = info.links.length == selected.length;
    final candidates = <_Candidate>[];
    if (aligned) {
      for (var index = 0; index < selected.length; index++) {
        final file = selected[index];
        if (filter(file.path)) {
          candidates.add(
            _Candidate(
              link: info.links[index],
              path: file.path,
              size: file.bytes,
            ),
          );
        }
      }
    } else {
      candidates.addAll([
        for (final link in info.links) _Candidate(link: link, size: 0),
      ]);
    }
    int? targetIndex;
    if (target != null) {
      final found = candidates.indexWhere(
        (candidate) => candidate.path == target.path,
      );
      if (found >= 0) targetIndex = found;
    }
    return mapFiles(windowFiles(candidates, targetIndex, maxFiles), (
      candidate,
    ) async {
      final unrestricted = await _post('$_api/unrestrict/link', [
        ('link', candidate.link),
      ], cancel: cancel);
      final name = candidate.path == null
          ? nonEmptyString(field(unrestricted, 'filename'))
          : basename(candidate.path!);
      if (name == null || name.isEmpty) return null;
      if (candidate.path == null && !filter(name)) return null;
      if (_isArchive(name) &&
          !selected.any((file) => file.path.endsWith(name))) {
        return null;
      }
      final unrestrictedSize = jsonInt(field(unrestricted, 'filesize')) ?? 0;
      return DebridFileInfo(
        name: name,
        path: candidate.path ?? '/$name',
        size: unrestrictedSize > 0 ? unrestrictedSize : candidate.size,
        url: jsonString(field(unrestricted, 'download')) ?? '',
        type: jsonString(field(unrestricted, 'mimeType')),
      );
    });
  }

  @override
  Future<AccountInfo> validate({CancelToken? cancel}) async {
    final user = await _get('$_api/user', cancel: cancel);
    if (jsonString(field(user, 'type')) != 'premium') {
      throw const DebridFailure.auth(
        'Real-Debrid premium is required to stream torrents',
      );
    }
    return AccountInfo(
      username: jsonString(field(user, 'username')) ?? '',
      expires: jsonString(field(user, 'expiration')),
    );
  }

  @override
  Future<Map<String, Availability>> listAvailability({
    CancelToken? cancel,
  }) async {
    final known = <String, Availability>{};
    for (final torrent in jsonList(await _fetchListing(cancel: cancel))) {
      final status = jsonString(field(torrent, 'status'));
      final state = status == null ? null : _statusAvailability(status);
      final hash = nonEmptyString(field(torrent, 'hash'))?.toLowerCase();
      if (state != null && hash != null) known[hash] = state;
    }
    return known;
  }

  @override
  Future<Map<String, Availability>> checkAvailabilityBatch(
    List<String> hashes, {
    CancelToken? cancel,
  }) => Future.error(
    const DebridFailure.service(
      'Real-Debrid has no cache endpoint; availability is probed per hash',
    ),
  );

  @override
  Future<Availability> probeAvailability(
    String hash, {
    CancelToken? cancel,
  }) async {
    final magnet = toMagnet(hash);
    if (magnet == null) {
      throw const DebridFailure.service('Not a usable info hash');
    }
    final id = await _addAndSelect(
      magnet,
      fileFilter: (_) => true,
      reads: _probeConversionReads,
      cancel: cancel,
    );
    final guard = OrphanGuard(client);
    final (url, opts) = _deleteRequest(id);
    guard.arm(url, opts);
    try {
      final result = await _awaitStatus(
        id,
        'downloaded',
        client.budget(config.timeouts.probeMs),
        cancel: cancel,
      );
      await raced(_release(id), cancel);
      guard.disarm();
      return result.status == 'downloaded'
          ? Availability.cached
          : Availability.unknown;
    } on CancelledException {
      guard.settle();
      rethrow;
    } catch (_) {
      await _release(id);
      guard.disarm();
      rethrow;
    }
  }

  @override
  Future<ResolvedFiles> resolve(
    String magnet,
    ResolveOptions opts, {
    CancelToken? cancel,
  }) async {
    final hash = parseHash(magnet);
    final magnetUri = toMagnet(magnet);
    if (magnetUri == null) {
      throw const DebridFailure.service('Not a usable info hash');
    }
    bool filter(String path) => opts.fileFilter?.call(path) ?? true;
    final maxFiles = opts.maxFiles ?? config.maxFiles;
    String? added;
    final guard = OrphanGuard(client);
    try {
      final existing = await _existingTorrent(hash, cancel: cancel);
      String id;
      _TorrentInfo? info;
      if (existing?.status == 'waiting_files_selection') {
        await _selectFiles(existing!.id, [
          for (final file in existing.files)
            if (filter(file.path)) file.id,
        ], cancel: cancel);
        id = existing.id;
      } else if (existing != null && existing.status != 'downloaded') {
        throw _unstreamable(existing.status) ?? const DebridFailure.notCached();
      } else if (existing != null) {
        id = existing.id;
        info = existing;
      } else {
        id = await _addAndSelect(magnetUri, fileFilter: filter, cancel: cancel);
        added = id;
        final (url, deleteOpts) = _deleteRequest(id);
        guard.arm(url, deleteOpts);
      }
      info ??= await _awaitStatus(
        id,
        'downloaded',
        client.budget(config.timeouts.readyMs),
        cancel: cancel,
      );

      final wanted = [
        for (final file in info.files)
          if (filter(file.path))
            _Wanted(id: file.id, path: file.path, size: file.bytes),
      ];
      _Wanted? target;
      if (wanted.isNotEmpty) {
        if (opts.pickFile != null) {
          final index = opts.pickFile!([
            for (final file in wanted) (file.id, file.path, file.size),
          ]);
          if (index != null && index < wanted.length) target = wanted[index];
        } else {
          target = wanted.reduce(
            (best, file) => file.size > best.size ? file : best,
          );
        }
      }

      var files = await _unrestrictLinks(
        info,
        filter,
        maxFiles,
        target,
        cancel: cancel,
      );
      if (target != null &&
          !files.any((file) => file.name == basename(target!.path))) {
        final retryId = await _addAndSelect(
          magnetUri,
          fileId: target.id,
          cancel: cancel,
        );
        if (added != null) await _release(id);
        id = retryId;
        added = retryId;
        final (url, deleteOpts) = _deleteRequest(retryId);
        guard.arm(url, deleteOpts);
        info = await _awaitStatus(
          retryId,
          'downloaded',
          client.budget(config.timeouts.readyMs),
          cancel: cancel,
        );
        files = await _unrestrictLinks(info, filter, 1, null, cancel: cancel);
        if (files.isEmpty) {
          throw const DebridFailure.service(
            'Real-Debrid only serves this torrent as an archive',
          );
        }
      }
      if (files.isEmpty) {
        throw const DebridFailure.service('No playable files in this torrent');
      }
      final resolved = ResolvedFiles(
        hash: info.hash,
        name: info.filename,
        files: secureFiles(files, config.title),
        targetPath: target?.path,
      );
      guard.disarm();
      return resolved;
    } on CancelledException {
      guard.settle();
      rethrow;
    } on DebridFailure catch (error) {
      guard.disarm();
      if (added != null) await _release(added);
      if (error.kind == DebridErrorKind.timeout) {
        throw const DebridFailure.notCached();
      }
      rethrow;
    } catch (_) {
      guard.disarm();
      if (added != null) await _release(added);
      rethrow;
    }
  }

  @override
  Future<void> retryCleanup() => client.retryCleanup(_dialect);
}

Availability? _statusAvailability(String status) => switch (status) {
  'downloaded' => Availability.cached,
  'queued' ||
  'downloading' ||
  'uploading' ||
  'compressing' => Availability.available,
  'magnet_error' || 'error' || 'virus' || 'dead' => Availability.unavailable,
  _ => null,
};

DebridFailure? _unstreamable(String status) =>
    switch (_statusAvailability(status)) {
      Availability.unavailable => DebridFailure.unavailable(
        'Real-Debrid could not process this torrent ($status)',
      ),
      Availability.available => const DebridFailure.notCached(),
      _ => null,
    };

_TorrentInfo _parseInfo(Object? value) => _TorrentInfo(
  id: jsonString(field(value, 'id')) ?? '',
  hash: (jsonString(field(value, 'hash')) ?? '').toLowerCase(),
  filename: jsonString(field(value, 'filename')) ?? '',
  status: jsonString(field(value, 'status')) ?? '',
  files: [
    for (final file in jsonList(field(value, 'files')))
      _TorrentFile(
        id: jsonInt(field(file, 'id')) ?? 0,
        path: jsonString(field(file, 'path')) ?? '',
        bytes: jsonInt(field(file, 'bytes')) ?? 0,
        selected: jsonTruthy(field(file, 'selected')),
      ),
  ],
  links: [
    for (final link in jsonList(field(value, 'links')))
      if (link is String) link,
  ],
);

bool _isArchive(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.rar') ||
      lower.endsWith('.zip') ||
      lower.endsWith('.7z');
}
