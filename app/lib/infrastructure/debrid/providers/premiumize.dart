import '../../../domain/models/availability.dart';
import '../../network/transport.dart';
import '../client.dart';
import '../errors.dart';
import '../hash.dart';
import '../window.dart';
import 'json.dart';
import 'provider.dart';

const _api = 'https://www.premiumize.me/api';

const _knownMessages = <String, String>{
  'authentication_failed': 'Invalid Premiumize API key',
  'permission_denied': 'Premiumize denied the request, check the account',
  'account_limit_reached':
      'This Premiumize account has used up its fair use points or active jobs',
  'service_limit_reached':
      'This Premiumize account has reached its limit for this source',
  'rate_limit_reached':
      'Premiumize is rate limiting this account, try again shortly',
  'service_down': 'Premiumize cannot reach this source right now',
  'service_unsupported': 'Premiumize cannot process this kind of source',
  'link_generation_failed':
      'Premiumize could not generate a stream link, try again shortly',
};

const _authCodes = {'authentication_failed', 'permission_denied'};
const _throttleCodes = {
  'rate_limit_reached',
  'account_limit_reached',
  'service_limit_reached',
};
const _deadCodes = {'service_unsupported', 'permanent_error'};

class _PremiumizeDialect extends Dialect {
  const _PremiumizeDialect();

  @override
  Object? unwrap(Object? json) {
    if (field(json, 'status') == 'error') throw mapError(200, json);
    return json;
  }

  @override
  DebridFailure mapError(int status, Object? json) {
    final code = jsonString(field(json, 'code'));
    final message =
        _knownMessages[code] ??
        safeServiceMessage(
          jsonString(field(json, 'message')),
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

class PremiumizeProvider implements DebridProvider {
  PremiumizeProvider(String apiKey, HttpTransport transport, Clock clock)
    : client = DebridApiClient(providerConfig, apiKey, transport, clock);

  static const providerConfig = ProviderConfig(
    id: 'premiumize',
    title: 'Premiumize',
    auth: AuthScheme.bearer,
    authParam: 'apikey',
    encoding: BodyEncoding.form,
    nominalLatencyMs: 300,
    maxFiles: 60,
    availabilityCheck: AvailabilityCheck.batch,
    checkAddsMagnets: false,
    maxBatch: 100,
    maxProbes: 10,
    maxConcurrent: 3,
    minTimeMs: 250,
  );

  static const _dialect = _PremiumizeDialect();

  @override
  final DebridApiClient client;

  @override
  ProviderConfig get config => providerConfig;

  @override
  bool throttled(DebridFailure error) {
    final code = _errorCode(error);
    return error.throttled || (code != null && _throttleCodes.contains(code));
  }

  Future<List<Object?>> _directDl(String magnet, {CancelToken? cancel}) async {
    Object? transfer;
    try {
      transfer = await client.request(
        _dialect,
        '$_api/transfer/directdl',
        RequestOpts(method: HttpMethod.post, body: [('src', magnet)]),
        cancel: cancel,
      );
    } on DebridFailure catch (error) {
      final code = _errorCode(error);
      if (code != null && _deadCodes.contains(code)) {
        throw DebridFailure.unavailable(error.message);
      }
      if (code == 'not_found') throw const DebridFailure.notCached();
      rethrow;
    }
    final content = [
      for (final entry in jsonList(field(transfer, 'content')))
        if (nonEmptyString(field(entry, 'link')) != null) entry,
    ];
    if (content.isEmpty) throw const DebridFailure.notCached();
    return content;
  }

  @override
  Future<AccountInfo> validate({CancelToken? cancel}) async {
    final account = await client.request(
      _dialect,
      '$_api/account/info',
      const RequestOpts(),
      cancel: cancel,
    );
    final customer = switch (field(account, 'customer_id')) {
      String value when value.isNotEmpty => value,
      num value when value != 0 => value.toString(),
      _ => null,
    };
    if (customer == null) {
      throw const DebridFailure.auth(
        'Premiumize did not recognise this API key',
      );
    }
    return AccountInfo(
      username: 'Premiumize $customer',
      expires: isoFromUnixSeconds(field(account, 'premium_until')),
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
    final items = [for (final hash in hashes) toMagnet(hash) ?? ''];
    final checked = await client.request(
      _dialect,
      '$_api/cache/check',
      RequestOpts(method: HttpMethod.post, body: [('items[]', items)]),
      cancel: cancel,
    );
    final response = jsonList(field(checked, 'response'));
    return {
      for (var index = 0; index < hashes.length; index++)
        hashes[index]: index < response.length && jsonTruthy(response[index])
            ? Availability.cached
            : Availability.available,
    };
  }

  @override
  Future<Availability> probeAvailability(String hash, {CancelToken? cancel}) =>
      Future.error(
        const DebridFailure.service(
          'Premiumize answers availability in batches via /cache/check',
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
        'Premiumize needs a magnet link or info hash to resolve',
      );
    }
    final content = await _directDl(magnetUri, cancel: cancel);
    final wanted = <DebridFileInfo>[
      for (final entry in content)
        if (opts.fileFilter == null || opts.fileFilter!(_entryPath(entry)))
          DebridFileInfo(
            name: basename(_entryPath(entry)),
            path: _entryPath(entry),
            size: jsonInt(field(entry, 'size')) ?? 0,
            url: nonEmptyString(field(entry, 'link')) ?? '',
          ),
    ];
    if (wanted.isEmpty) {
      throw const DebridFailure.service('No playable files in this torrent');
    }
    final target = opts.pickFile == null
        ? _largestIndex(wanted)
        : opts.pickFile!([
            for (var index = 0; index < wanted.length; index++)
              (index, wanted[index].path, wanted[index].size),
          ]);
    final maxFiles = opts.maxFiles ?? config.maxFiles;
    final targetPath = target == null || target >= wanted.length
        ? null
        : wanted[target].path;
    final files = secureFiles(
      windowFiles(wanted, target, maxFiles),
      config.title,
    );
    return ResolvedFiles(
      hash: hash,
      name: _torrentName(files),
      files: files,
      targetPath: targetPath,
    );
  }

  @override
  Future<void> retryCleanup() async {}
}

String? _errorCode(DebridFailure error) => error.code;

String _entryPath(Object? entry) =>
    rootedPath(jsonString(field(entry, 'path')) ?? '');

int _largestIndex(List<DebridFileInfo> files) {
  var best = 0;
  for (var index = 1; index < files.length; index++) {
    if (files[index].size > files[best].size) best = index;
  }
  return best;
}

String _torrentName(List<DebridFileInfo> files) {
  final first = files.first;
  final parts = first.path.split('/');
  final folder = parts.length > 1 ? parts[1] : '';
  final prefix = '/$folder/';
  return folder.isNotEmpty &&
          files.every((file) => file.path.startsWith(prefix))
      ? folder
      : first.name;
}
