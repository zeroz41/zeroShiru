/// Domain-facing debrid clients and the one concrete-provider registry.
/// Provider instances remain warm per account so availability memory, pacing
/// and cleanup debt survive across calls; credentials are held only in memory.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/models/availability.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/debrid_client.dart';
import '../media/filename.dart';
import '../media/pick.dart';
import '../network/transport.dart';
import 'client.dart';
import 'errors.dart';
import 'hash.dart';
import 'manager.dart';
import 'providers/alldebrid.dart';
import 'providers/premiumize.dart';
import 'providers/provider.dart';
import 'providers/realdebrid.dart';
import 'providers/torbox.dart';

const int _providerSlots = 4;
const int _resolvedSlots = 64;
const Duration _resolvedTtl = Duration(minutes: 15);

/// The menu order is part of the settings/host contract.
const List<DebridService> debridServices = [
  DebridService.alldebrid,
  DebridService.premiumize,
  DebridService.realdebrid,
  DebridService.torbox,
];

DebridProvider createDebridProvider(
  DebridService service,
  String apiKey,
  HttpTransport transport,
  Clock clock,
) => switch (service) {
  DebridService.alldebrid => AllDebridProvider(apiKey, transport, clock),
  DebridService.premiumize => PremiumizeProvider(apiKey, transport, clock),
  DebridService.realdebrid => RealDebridProvider(apiKey, transport, clock),
  DebridService.torbox => TorBoxProvider(apiKey, transport, clock),
};

ProviderConfig debridProviderConfig(DebridService service) => switch (service) {
  DebridService.alldebrid => AllDebridProvider.providerConfig,
  DebridService.premiumize => PremiumizeProvider.providerConfig,
  DebridService.realdebrid => RealDebridProvider.providerConfig,
  DebridService.torbox => TorBoxProvider.providerConfig,
};

/// A [DebridClient] for one service. The API key remains a per-call domain
/// input, while an LRU of account-scoped providers preserves the service state
/// that makes retries and cache badges correct.
class ProviderDebridClient implements DebridClient {
  ProviderDebridClient(
    this.service,
    this._transport, [
    this._clock = const SystemClock(),
  ]);

  @override
  final DebridService service;

  final HttpTransport _transport;
  final Clock _clock;

  /// Least recently used first. The key is a one-way account fingerprint, not
  /// the credential; the provider alone owns the in-memory credential string.
  final LinkedHashMap<String, ManagedDebridProvider> _accounts =
      LinkedHashMap();
  final List<_ResolvedEntry> _resolved = [];

  @override
  bool get checkAddsMagnets => debridProviderConfig(service).checkAddsMagnets;

  @override
  Future<DebridAccount> validate(String apiKey) async {
    final info = await _managed(apiKey).provider.validate();
    return DebridAccount(
      username: info.username,
      expires: info.expires == null ? null : DateTime.tryParse(info.expires!),
    );
  }

  /// Combines the free account listing with the provider's cheapest active
  /// check. Hashes a service cannot answer remain absent.
  @override
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  ) async {
    final managed = _managed(apiKey);
    final normalized = DebridApiClient.normalizeHashes(
      hashes,
      managed.provider.config.maxAsk,
    );
    final answers = <String, Availability>{};
    final listed = await managed.listAvailability();
    for (final hash in normalized) {
      final state = listed[hash];
      if (state != null) answers[hash] = state;
    }
    final checked = await managed.checkAvailability(normalized);
    answers.addAll(checked);
    return answers;
  }

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) async {
    final hash = parseHash(magnet);
    if (hash == null) {
      throw const DebridFailure.rejected(
        'This source does not contain a valid BitTorrent info hash',
      );
    }
    final fingerprint = _accountFingerprint(apiKey);
    final cached = _readResolved(fingerprint, hash, episode);
    final managed = _managed(apiKey);
    if (cached != null) {
      managed.client.remember(hash, Availability.cached);
      return _toDomain(cached);
    }

    final maxFiles = managed.provider.config.maxFiles;
    final opts = ResolveOptions(
      fileFilter: isPlaybackPath,
      pickFile: episode == null
          ? null
          : (candidates) {
              try {
                return pickPack(
                  [
                    for (final (_, path, size) in candidates)
                      PackFile(path, size),
                  ],
                  episode.toDouble(),
                  maxFiles,
                );
              } on EpisodeNotInPack catch (error) {
                throw DebridFailure.rejected(error.message);
              }
            },
    );
    final resolved = await managed.resolve(magnet, opts);
    managed.client.remember(resolved.hash, Availability.cached);
    _rememberResolved(fingerprint, resolved);
    return _toDomain(resolved);
  }

  @override
  Future<void> forgetResolved(String apiKey, String hash) async {
    final normalized = parseHash(hash) ?? hash.toLowerCase();
    final fingerprint = _accountFingerprint(apiKey);
    _resolved.removeWhere(
      (entry) =>
          entry.account == fingerprint && entry.resolved.hash == normalized,
    );
  }

  ManagedDebridProvider _managed(String apiKey) {
    final account = _accountFingerprint(apiKey);
    final known = _accounts.remove(account);
    if (known != null) {
      _accounts[account] = known;
      return known;
    }
    final managed = ManagedDebridProvider(
      createDebridProvider(service, apiKey, _transport, _clock),
    );
    _accounts[account] = managed;
    while (_accounts.length > _providerSlots) {
      final oldest = _accounts.keys.first;
      final outgoing = _accounts.remove(oldest)!;
      if (outgoing.client.orphaned > 0) {
        // Cleanup belongs to the outgoing account. It is deliberately not
        // awaited on the next account's user action.
        unawaited(outgoing.provider.retryCleanup());
      }
    }
    return managed;
  }

  String _accountFingerprint(String apiKey) =>
      sha256.convert(utf8.encode('${service.name}\u0000$apiKey')).toString();

  ResolvedFiles? _readResolved(String account, String hash, int? episode) {
    final now = _clock.now();
    _resolved.removeWhere(
      (entry) => now.difference(entry.storedAt) >= _resolvedTtl,
    );
    final index = _resolved.indexWhere(
      (entry) => entry.account == account && entry.resolved.hash == hash,
    );
    if (index < 0) return null;

    // More than one window can exist for a long pack. Search every matching
    // window and move only the usable one to the front.
    for (var offset = index; offset < _resolved.length; offset++) {
      final entry = _resolved[offset];
      if (entry.account != account || entry.resolved.hash != hash) continue;
      final retargeted = _retarget(entry.resolved, episode);
      if (retargeted == null) continue;
      _resolved.removeAt(offset);
      _resolved.insert(0, entry);
      return retargeted;
    }
    return null;
  }

  void _rememberResolved(String account, ResolvedFiles resolved) {
    _resolved.removeWhere(
      (entry) =>
          entry.account == account &&
          entry.resolved.hash == resolved.hash &&
          entry.resolved.targetPath == resolved.targetPath,
    );
    _resolved.insert(
      0,
      _ResolvedEntry(
        account: account,
        resolved: resolved,
        storedAt: _clock.now(),
      ),
    );
    if (_resolved.length > _resolvedSlots) {
      _resolved.removeRange(_resolvedSlots, _resolved.length);
    }
  }
}

ResolvedFiles? _retarget(ResolvedFiles resolved, int? episode) {
  if (episode == null) return resolved;
  int? picked;
  try {
    picked = pickEpisodeFile(
      [for (final file in resolved.files) PackFile(file.path, file.size)],
      episode.toDouble(),
      parseNames,
    );
  } on EpisodeNotInPack {
    return null;
  }
  final target = picked == null
      ? resolved.targetPath
      : resolved.files[picked].path;
  return ResolvedFiles(
    hash: resolved.hash,
    name: resolved.name,
    files: resolved.files,
    targetPath: target,
  );
}

ResolvedDebrid _toDomain(ResolvedFiles resolved) {
  final files = [
    for (final file in resolved.files)
      PlayerFile(
        name: file.name,
        url: file.url,
        infoHash: resolved.hash,
        fileHash: watchKey(resolved.hash, file.name, file.size),
        torrentName: resolved.name,
        mimeType: file.type,
        size: file.size,
        path: file.path,
      ),
  ];
  PlayerFile? target;
  final targetPath = resolved.targetPath;
  if (targetPath != null) {
    for (final file in files) {
      if (file.path == targetPath) {
        target = file;
        break;
      }
    }
  }
  return ResolvedDebrid(
    hash: resolved.hash,
    name: resolved.name,
    files: files,
    target: target,
  );
}

class _ResolvedEntry {
  const _ResolvedEntry({
    required this.account,
    required this.resolved,
    required this.storedAt,
  });

  final String account;
  final ResolvedFiles resolved;
  final DateTime storedAt;
}
