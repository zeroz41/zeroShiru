/// The internal provider interface and the per-provider configuration record.
/// Port of the `ProviderConfig`/`DebridProvider` half of crates/debrid/src/lib.rs.
/// Every constant here was measured against real provider behaviour — port
/// verbatim, never "tidy".
library;

import '../../../domain/models/availability.dart';
import '../client.dart';
import '../errors.dart';

/// How the API key travels: an Authorization header or a query parameter.
enum AuthScheme { bearer, query }

/// How request bodies are encoded, overridable per request.
enum BodyEncoding { form, json, multipart }

/// How the service can be asked about a release it has not seen. `batch`
/// answers many hashes per request, `probe` adds the magnet and reads the
/// status back, `none` leaves badges to the account listing.
enum AvailabilityCheck { batch, probe, none }

/// Time limits in milliseconds. All but [requestMs] are poll budgets that
/// stretch with the measured link latency; the hard request ceiling does not.
class Timeouts {
  const Timeouts({
    this.requestMs = 30000,
    this.selectMs = 12000,
    this.readyMs = 5000,
    this.pollMs = 1000,
    this.probeMs = 10000,
    this.resolveMs = 60000,
  });

  /// Hard ceiling on one round trip, deliberately does not stretch.
  final int requestMs;

  /// Waiting for the service to accept a magnet and expose its file list.
  final int selectMs;

  /// Waiting for a cached torrent to report ready; slower is a fresh download.
  final int readyMs;

  /// Gap between status polls.
  final int pollMs;

  /// Tighter than select: a probe that drags on spends requests playback needs.
  final int probeMs;

  /// The whole of one resolve, end to end.
  final int resolveMs;
}

/// A provider's static configuration.
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.title,
    required this.auth,
    required this.authParam,
    required this.encoding,
    this.timeouts = const Timeouts(),
    required this.nominalLatencyMs,
    required this.maxFiles,
    required this.availabilityCheck,
    required this.checkAddsMagnets,
    required this.maxBatch,
    required this.maxProbes,
    required this.maxConcurrent,
    required this.minTimeMs,
    this.reservoir,
  });

  /// Unique lowercase identifier, e.g. "realdebrid".
  final String id;

  /// Human readable service name.
  final String title;

  final AuthScheme auth;

  /// Query parameter name used when [auth] is [AuthScheme.query].
  final String authParam;

  final BodyEncoding encoding;
  final Timeouts timeouts;

  /// Round trip time the limits are written for, milliseconds.
  final int nominalLatencyMs;

  /// Most files one resolve turns into stream links.
  final int maxFiles;

  final AvailabilityCheck availabilityCheck;

  /// Whether asking about a release puts a magnet on the account rather than
  /// reading a cache index. AllDebrid's batch check uploads magnets too.
  final bool checkAddsMagnets;

  /// Hashes per batch request.
  final int maxBatch;

  /// Most probes one results list may cost, since each is several requests.
  final int maxProbes;

  /// Max concurrent requests / min gap between starts, for the rate limiter.
  final int maxConcurrent;
  final int minTimeMs;

  /// The allowance a service publishes, as `(requests, windowMs)`.
  final (int, int)? reservoir;

  /// How far down a results list this service looks. Checks that own a magnet
  /// per answer are capped like probes, whatever mode carries them.
  int get maxAsk =>
      availabilityCheck == AvailabilityCheck.probe || checkAddsMagnets
      ? maxProbes
      : 0x7fffffffffffffff;
}

/// One resolved file, before the domain PlayerFile mapping.
class DebridFileInfo {
  const DebridFileInfo({
    required this.name,
    required this.path,
    required this.size,
    required this.url,
    this.type,
  });

  final String name;

  /// Rooted, like the torrent client's.
  final String path;
  final int size;

  /// Direct stream link; HTTPS only survives [secureFiles].
  final String url;
  final String? type;
}

/// A resolve's outcome: files in torrent order plus the file the service
/// itself picked for the requested episode, if any.
class ResolvedFiles {
  const ResolvedFiles({
    required this.hash,
    required this.name,
    required this.files,
    this.targetPath,
  });

  final String hash;
  final String name;
  final List<DebridFileInfo> files;
  final String? targetPath;
}

class AccountInfo {
  const AccountInfo({required this.username, this.expires});

  final String username;
  final String? expires;
}

/// Chooses the file playback wants out of a pack's (id, path, size) list.
/// `null` means "no opinion, window from the front"; a thrown [DebridFailure]
/// (kind rejected) refuses the release outright.
typedef PickFile = int? Function(List<(int, String, int)> candidates);
typedef FileFilter = bool Function(String path);

/// Options for a resolve call.
class ResolveOptions {
  const ResolveOptions({this.fileFilter, this.pickFile, this.maxFiles});

  /// Keeps only files playback can use (video/subtitle/font names).
  final FileFilter? fileFilter;

  /// Picks the file playback wants out of a pack's file list.
  final PickFile? pickFile;

  final int? maxFiles;
}

/// What a provider must implement. Everything stateful (rate limiting,
/// availability memory, listing cache) lives in the shared client/manager
/// layers, so providers stay thin HTTP mappings.
abstract class DebridProvider {
  ProviderConfig get config;

  /// The shared per-account client, for the manager layer's memory & budgets.
  DebridApiClient get client;

  /// Verifies the API key and that the account can stream torrents.
  Future<AccountInfo> validate({CancelToken? cancel});

  /// The account's torrent listing: hash -> availability, the free badges.
  Future<Map<String, Availability>> listAvailability({CancelToken? cancel});

  /// Asks about many releases at once, for APIs with a cache endpoint.
  Future<Map<String, Availability>> checkAvailabilityBatch(
    List<String> hashes, {
    CancelToken? cancel,
  });

  /// What the service can do with one release, for APIs with no cache
  /// endpoint. Must leave the account exactly as it found it.
  Future<Availability> probeAvailability(String hash, {CancelToken? cancel});

  /// Resolves a magnet to direct stream URLs. URLs must be HTTPS.
  Future<ResolvedFiles> resolve(
    String magnet,
    ResolveOptions opts, {
    CancelToken? cancel,
  });

  /// Retries removals this client owes the account. The manager calls it
  /// before a check adds anything new.
  Future<void> retryCleanup() async {}

  /// Whether an error means the service wants fewer requests rather than that
  /// this release is a problem — a sweep stops on one. A `429` always counts;
  /// providers whose APIs say it in their own codes override this.
  bool throttled(DebridFailure error) => error.throttled;
}

/// Drops any link that is not HTTPS. Debrid links are account bound, so a
/// cleartext one would put the user's traffic and their link on the wire in
/// the clear.
List<DebridFileInfo> secureFiles(List<DebridFileInfo> files, String title) {
  final secure = files
      .where(
        (file) =>
            file.url.length >= 8 &&
            file.url.substring(0, 8).toLowerCase() == 'https://',
      )
      .toList();
  if (secure.isEmpty) {
    throw DebridFailure.service('$title returned no secure stream links');
  }
  return secure;
}
