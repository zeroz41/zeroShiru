import '../../../domain/models/availability.dart';
import '../../network/transport.dart';
import '../client.dart';
import '../errors.dart';
import '../hash.dart';
import '../window.dart';
import 'json.dart';
import 'provider.dart';

const _v4 = 'https://api.alldebrid.com/v4';
const _v41 = 'https://api.alldebrid.com/v4.1';
const _readyStatus = 4.0;

const _messages = <String, String>{
  'AUTH_BAD_APIKEY': 'Invalid AllDebrid API key',
  'AUTH_MISSING_APIKEY': 'AllDebrid requires an API key for this request',
  'AUTH_BLOCKED': 'AllDebrid has blocked this API key',
  'AUTH_USER_BANNED': 'This AllDebrid account is banned',
  'MUST_BE_PREMIUM': 'AllDebrid premium is required for this',
  'MAGNET_MUST_BE_PREMIUM': 'AllDebrid premium is required to stream torrents',
  'MAGNET_TOO_MANY_ACTIVE':
      'Too many active AllDebrid magnets, wait for one to finish',
  'MAGNET_TOO_LARGE': 'This release is larger than the AllDebrid plan allows',
  'MAGNET_INVALID_URI': 'AllDebrid would not accept this magnet',
  'MAGNET_NO_SERVER': 'No AllDebrid server is available right now',
  'NO_SERVER': 'No AllDebrid server is available right now',
  'LINK_TOO_MANY_DOWNLOADS':
      'Too many active AllDebrid downloads, wait for one to finish',
  'LINK_HOST_UNAVAILABLE': 'AllDebrid cannot serve this file right now',
  'LINK_DOWN': 'AllDebrid reports this file as dead',
  'FREE_TRIAL_LIMIT_REACHED': 'This AllDebrid trial has reached its limit',
};

const _authCodes = {
  'AUTH_BAD_APIKEY',
  'AUTH_MISSING_APIKEY',
  'AUTH_BLOCKED',
  'AUTH_USER_BANNED',
  'MUST_BE_PREMIUM',
  'MAGNET_MUST_BE_PREMIUM',
};
const _throttleCodes = {
  'MAGNET_TOO_MANY_ACTIVE',
  'LINK_TOO_MANY_DOWNLOADS',
  'MAGNET_NO_SERVER',
  'NO_SERVER',
};
const _deadCodes = {
  'MAGNET_INVALID_URI',
  'MAGNET_INVALID_FILE',
  'MAGNET_TOO_LARGE',
};

class _AllDebridDialect extends Dialect {
  const _AllDebridDialect();

  @override
  Object? unwrap(Object? json) {
    final envelope = jsonMap(json);
    if (!envelope.containsKey('status')) return json;
    if (envelope['status'] != 'success') throw mapError(200, json);
    return envelope['data'];
  }

  @override
  DebridFailure mapError(int status, Object? json) {
    final error = field(json, 'error');
    final code = jsonString(field(error, 'code'));
    final message =
        _messages[code] ??
        safeServiceMessage(
          jsonString(field(error, 'message')),
          'Request failed with status $status',
        );
    final auth =
        (code != null && _authCodes.contains(code)) ||
        ((status == 401 || status == 403) && code == null);
    return auth
        ? DebridFailure.auth(message, status: status, code: code)
        : DebridFailure.service(message, status: status, code: code);
  }
}

class _TreeFile {
  const _TreeFile({required this.path, required this.size, required this.link});

  final String path;
  final int size;
  final String link;
}

class AllDebridProvider implements DebridProvider {
  AllDebridProvider(String apiKey, HttpTransport transport, Clock clock)
    : client = DebridApiClient(providerConfig, apiKey, transport, clock);

  static const providerConfig = ProviderConfig(
    id: 'alldebrid',
    title: 'AllDebrid',
    auth: AuthScheme.bearer,
    authParam: 'apikey',
    encoding: BodyEncoding.form,
    nominalLatencyMs: 300,
    maxFiles: 60,
    availabilityCheck: AvailabilityCheck.batch,
    checkAddsMagnets: true,
    maxBatch: 10,
    maxProbes: 10,
    maxConcurrent: 3,
    minTimeMs: 250,
  );

  static const _dialect = _AllDebridDialect();

  @override
  final DebridApiClient client;

  @override
  ProviderConfig get config => providerConfig;

  @override
  bool throttled(DebridFailure error) =>
      error.throttled ||
      (error.code != null && _throttleCodes.contains(error.code));

  Future<Object?> _request(
    String url, [
    RequestOpts opts = const RequestOpts(),
    CancelToken? cancel,
  ]) => client.request(_dialect, url, opts, cancel: cancel);

  Future<List<Object?>> _upload(
    List<String> magnets, {
    CancelToken? cancel,
  }) async {
    final data = await _request(
      '$_v4/magnet/upload',
      RequestOpts(method: HttpMethod.post, body: [('magnets[]', magnets)]),
      cancel,
    );
    client.forgetListing();
    return jsonList(field(data, 'magnets'));
  }

  Future<List<Object?>> _magnets({String? id, CancelToken? cancel}) async {
    final data = await _request(
      '$_v41/magnet/status',
      RequestOpts(
        method: HttpMethod.post,
        body: id == null ? const [] : [('id', id)],
      ),
      cancel,
    );
    final magnets = field(data, 'magnets');
    return magnets is List
        ? jsonList(magnets)
        : (magnets is Map ? [magnets] : []);
  }

  Future<List<Object?>> _files(Object? magnet, {CancelToken? cancel}) async {
    final inline = jsonList(field(magnet, 'files'));
    if (inline.isNotEmpty) return inline;
    final id = scalarText(field(magnet, 'id')) ?? '';
    final data = await _request(
      '$_v4/magnet/files',
      RequestOpts(
        method: HttpMethod.post,
        body: [
          ('id[]', [id]),
        ],
      ),
      cancel,
    );
    final entries = jsonList(field(data, 'magnets'));
    return entries.isEmpty ? const [] : jsonList(field(entries.first, 'files'));
  }

  Future<Set<String>> _accountIds({CancelToken? cancel}) async {
    final listing = await client.listing(
      true,
      () async => _magnets(cancel: cancel),
    );
    return {
      for (final entry in jsonList(listing)) ?scalarText(field(entry, 'id')),
    };
  }

  Future<DebridFileInfo?> _unlock(_TreeFile file, {CancelToken? cancel}) async {
    final data = await _request(
      '$_v4/link/unlock?link=${Uri.encodeQueryComponent(file.link)}',
      const RequestOpts(),
      cancel,
    );
    final link = nonEmptyString(field(data, 'link'));
    if (link == null) return null;
    final size = jsonInt(field(data, 'filesize')) ?? 0;
    return DebridFileInfo(
      name: basename(file.path),
      path: file.path,
      size: size > 0 ? size : file.size,
      url: link,
    );
  }

  Future<List<DebridFileInfo>> _unlockLinks(
    List<_TreeFile> wanted, {
    CancelToken? cancel,
  }) => mapFiles(wanted, (file) => _unlock(file, cancel: cancel));

  static (String, RequestOpts) _deleteRequest(String id) => (
    '$_v4/magnet/delete',
    RequestOpts(method: HttpMethod.post, body: [('id', id)]),
  );

  Future<void> _delete(String id) async {
    final (url, opts) = _deleteRequest(id);
    await client.release(_dialect, url, opts);
  }

  @override
  Future<AccountInfo> validate({CancelToken? cancel}) async {
    final data = await _request('$_v4/user', const RequestOpts(), cancel);
    final user = field(data, 'user');
    if (user is! Map) {
      throw const DebridFailure.auth(
        'AllDebrid did not recognise this API key',
      );
    }
    if (!jsonTruthy(field(user, 'isPremium')) &&
        !jsonTruthy(field(user, 'isTrial'))) {
      throw const DebridFailure.auth(
        'AllDebrid premium is required to stream torrents',
      );
    }
    return AccountInfo(
      username:
          nonEmptyString(field(user, 'username')) ??
          nonEmptyString(field(user, 'email')) ??
          'AllDebrid user',
      expires: isoFromUnixSeconds(field(user, 'premiumUntil')),
    );
  }

  @override
  Future<Map<String, Availability>> listAvailability({
    CancelToken? cancel,
  }) async => const {};

  @override
  Future<Map<String, Availability>> checkAvailabilityBatch(
    List<String> hashes, {
    CancelToken? cancel,
  }) async {
    final existing = await _accountIds(cancel: cancel);
    final uploaded = await _upload(hashes, cancel: cancel);
    final answers = <String, Availability>{};
    final ours = <String>[];
    final guard = OrphanGuard(client);
    try {
      for (final entry in uploaded) {
        final id = scalarText(field(entry, 'id'));
        if (id != null && !existing.contains(id)) {
          final (url, opts) = _deleteRequest(id);
          guard.arm(url, opts);
          ours.add(id);
        }
        final hash = parseHash(
          jsonString(field(entry, 'hash')) ??
              jsonString(field(entry, 'magnet')) ??
              '',
        );
        if (hash == null) continue;
        final error = field(entry, 'error');
        if (error is Map) {
          final code = jsonString(field(error, 'code'));
          if (code != null && _deadCodes.contains(code)) {
            answers[hash] = Availability.unavailable;
          }
          continue;
        }
        answers[hash] = jsonTruthy(field(entry, 'ready'))
            ? Availability.cached
            : Availability.available;
      }
      for (final id in ours) {
        await raced(_delete(id), cancel);
      }
      guard.disarm();
      return answers;
    } on CancelledException {
      guard.settle();
      rethrow;
    } catch (_) {
      for (final id in ours) {
        await _delete(id);
      }
      guard.disarm();
      rethrow;
    }
  }

  @override
  Future<Availability> probeAvailability(String hash, {CancelToken? cancel}) =>
      Future.error(
        const DebridFailure.service(
          'AllDebrid answers availability in batches, not probes',
        ),
      );

  @override
  Future<ResolvedFiles> resolve(
    String magnet,
    ResolveOptions opts, {
    CancelToken? cancel,
  }) async {
    final hash = parseHash(magnet) ?? '';
    final magnetUri = toMagnet(magnet);
    if (magnetUri == null) {
      throw const DebridFailure.service(
        'AllDebrid needs a magnet link or info hash to resolve',
      );
    }
    final existing = await _accountIds(cancel: cancel);
    final entries = await _upload([magnetUri], cancel: cancel);
    final uploaded = entries.isEmpty ? null : entries.first;
    final error = field(uploaded, 'error');
    if (error is Map) throw _uploadError(error);
    final id = scalarText(field(uploaded, 'id'));
    if (id == null) {
      throw const DebridFailure.service(
        'AllDebrid did not report the magnet back after adding it',
      );
    }
    final added = !existing.contains(id);
    final guard = OrphanGuard(client);
    if (added) {
      final (url, deleteOpts) = _deleteRequest(id);
      guard.arm(url, deleteOpts);
    }
    try {
      final resolved = await _resolveReady(
        uploaded,
        id,
        hash,
        opts,
        cancel: cancel,
      );
      guard.disarm();
      return resolved;
    } on CancelledException {
      guard.settle();
      rethrow;
    } catch (_) {
      guard.disarm();
      if (added) await _delete(id);
      rethrow;
    }
  }

  Future<ResolvedFiles> _resolveReady(
    Object? uploaded,
    String id,
    String hash,
    ResolveOptions opts, {
    CancelToken? cancel,
  }) async {
    if (!jsonTruthy(field(uploaded, 'ready'))) {
      throw const DebridFailure.notCached();
    }
    final status = await _magnets(id: id, cancel: cancel);
    if (status.isEmpty) {
      throw const DebridFailure.service(
        'AllDebrid did not report the magnet back after adding it',
      );
    }
    final magnet = status.first;
    switch (_magnetAvailability(magnet)) {
      case Availability.cached:
        break;
      case Availability.unavailable:
        final detail = nonEmptyString(field(magnet, 'status')) ?? 'failed';
        throw DebridFailure.unavailable(
          'AllDebrid could not process this torrent ($detail)',
        );
      case Availability.available || Availability.unknown:
        throw const DebridFailure.notCached();
    }

    final wanted = <_TreeFile>[];
    _flattenFiles(await _files(magnet, cancel: cancel), '', wanted);
    if (opts.fileFilter != null) {
      wanted.removeWhere((file) => !opts.fileFilter!(file.path));
    }
    if (wanted.isEmpty) {
      throw const DebridFailure.service('No playable files in this torrent');
    }
    final target = opts.pickFile == null
        ? _largestTreeFile(wanted)
        : opts.pickFile!([
            for (var index = 0; index < wanted.length; index++)
              (index, wanted[index].path, wanted[index].size),
          ]);
    final maxFiles = opts.maxFiles ?? config.maxFiles;
    final targetPath = target == null || target >= wanted.length
        ? null
        : wanted[target].path;
    final files = await _unlockLinks(
      windowFiles(wanted, target, maxFiles),
      cancel: cancel,
    );
    if (files.isEmpty) {
      throw const DebridFailure.service(
        'AllDebrid returned no links for this torrent',
      );
    }
    return ResolvedFiles(
      hash: hash,
      name: jsonString(field(magnet, 'filename')) ?? '',
      files: secureFiles(files, config.title),
      targetPath: targetPath,
    );
  }

  @override
  Future<void> retryCleanup() => client.retryCleanup(_dialect);
}

DebridFailure _uploadError(Object? error) {
  final code = jsonString(field(error, 'code'));
  final message =
      _messages[code] ??
      safeServiceMessage(
        jsonString(field(error, 'message')),
        'AllDebrid would not accept this magnet',
      );
  return code != null && _deadCodes.contains(code)
      ? DebridFailure.unavailable(message)
      : DebridFailure.service(message, code: code);
}

Availability _magnetAvailability(Object? magnet) {
  final code = jsonDouble(field(magnet, 'statusCode'));
  if (code == null) return Availability.unknown;
  if (code == _readyStatus) return Availability.cached;
  return code < _readyStatus
      ? Availability.available
      : Availability.unavailable;
}

void _flattenFiles(
  List<Object?> entries,
  String prefix,
  List<_TreeFile> output,
) {
  for (final entry in entries) {
    final name = jsonString(field(entry, 'n')) ?? '';
    final path = '$prefix/$name';
    final children = field(entry, 'e');
    if (children is List) {
      _flattenFiles(jsonList(children), path, output);
      continue;
    }
    final link = nonEmptyString(field(entry, 'l'));
    if (link != null) {
      output.add(
        _TreeFile(
          path: path,
          size: jsonInt(field(entry, 's')) ?? 0,
          link: link,
        ),
      );
    }
  }
}

int _largestTreeFile(List<_TreeFile> files) {
  var best = 0;
  for (var index = 1; index < files.length; index++) {
    if (files[index].size > files[best].size) best = index;
  }
  return best;
}
