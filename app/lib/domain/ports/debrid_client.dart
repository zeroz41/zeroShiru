import '../models/availability.dart';
import '../models/torrent.dart';

enum DebridService { alldebrid, premiumize, realdebrid, torbox }

/// Error vocabulary shared with the UI's outage notices. Mirrors the redo
/// branch's kind contract: auth | network | timeout | not-cached |
/// unavailable | rejected | service.
enum DebridErrorKind {
  auth,
  network,
  timeout,
  notCached,
  unavailable,
  rejected,
  service,
}

class DebridException implements Exception {
  const DebridException(this.kind, this.message);

  final DebridErrorKind kind;

  /// Redacted — must never contain signed URLs or API keys.
  final String message;

  @override
  String toString() => 'DebridException(${kind.name}): $message';
}

class DebridAccount {
  const DebridAccount({required this.username, this.expires});

  final String username;
  final DateTime? expires;
}

class ResolvedDebrid {
  const ResolvedDebrid({
    required this.hash,
    required this.name,
    required this.files,
    this.target,
  });

  final String hash;
  final String name;
  final List<PlayerFile> files;

  /// The file the service itself picked for the requested episode, if any.
  final PlayerFile? target;
}

/// One implementation per provider. API keys are passed per call and kept only
/// in memory by account-scoped clients; they are never persisted here, and a
/// key configured for one service must never reach another service's API.
abstract interface class DebridClient {
  DebridService get service;

  /// Whether this provider's availability check adds magnets server-side.
  bool get checkAddsMagnets;

  Future<DebridAccount> validate(String apiKey);

  /// Batch cached-availability check. Keys of the result are lowercase hashes.
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  );

  /// Resolve a magnet (and optional episode within a pack) to playable files
  /// with signed URLs.
  Future<ResolvedDebrid> resolve(String apiKey, String magnet, {int? episode});

  /// Invalidate a dead cached link so the next resolve reissues it.
  Future<void> forgetResolved(String apiKey, String hash);
}
