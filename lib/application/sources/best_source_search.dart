import 'dart:async';

import '../../domain/media/filename.dart';
import '../../domain/media/info_hash.dart';
import '../../domain/media/pack_picker.dart';
import '../../domain/models/availability.dart';
import '../../domain/models/media.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/source_extension.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/ports.dart';
import '../playback/coverage.dart';
import '../playback/request.dart';
import 'best_source.dart';

const bestSourceSearchTimeout = Duration(seconds: 8);
const bestSourceAvailabilityTimeout = Duration(seconds: 3);

class BestSourceSearchResult {
  const BestSourceSearchResult({
    required this.releases,
    this.sourceErrors = const [],
    this.timedOut = false,
  });

  final List<PlaybackRelease> releases;
  final List<String> sourceErrors;
  final bool timedOut;
}

/// Searches, validates, cache-checks, and ranks releases for one exact episode.
///
/// Player episode navigation uses this same ordering as the details picker. A
/// result is admitted only when its torrent identity is safe and its title (or
/// an inspected file list) can identify the requested episode.
Future<BestSourceSearchResult> searchBestEpisodeSources({
  required SourceResolver resolver,
  required DebridClient debrid,
  required String apiKey,
  required Media media,
  required int episode,
  required Settings preferences,
  Duration searchTimeout = bestSourceSearchTimeout,
  Duration availabilityTimeout = bestSourceAvailabilityTimeout,
}) async {
  final results = <TorrentResult>[];
  final sourceErrors = <String>[];
  final seenHashes = <String>{};
  var timedOut = false;
  final done = Completer<void>();
  StreamSubscription<SourceSearchBatch>? subscription;
  final timer = Timer(searchTimeout, () {
    timedOut = true;
    if (!done.isCompleted) done.complete();
  });

  try {
    subscription = resolver
        .search(
          TorrentQuery(
            anilistId: media.id,
            idMal: media.idMal,
            titles: sourceSearchTitles(media),
            episode: episode,
            episodeCount: media.maxEpisode,
            resolution: preferences.rssQuality,
            exclusions: const [],
          ),
          movie: media.format == MediaFormat.movie,
        )
        .listen(
          (batch) {
            if (batch.error case final error?) {
              sourceErrors.add('${batch.source.name}: $error');
            }
            for (final result in batch.results) {
              final hash = validatedTorrentHash(
                declaredHash: result.hash,
                link: result.link,
              );
              if (hash == null) continue;
              if (!releaseHoldsEpisode(
                parseFilename(result.title),
                episode: episode,
                absoluteEpisode: result.mappedEpisode,
                episodeCount: media.maxEpisode,
              )) {
                continue;
              }
              seenHashes.add(hash);
              results.add(result);
            }
          },
          onError: (Object error) {
            sourceErrors.add('$error');
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
    await done.future;
  } finally {
    timer.cancel();
    final cancellation = subscription?.cancel();
    if (cancellation != null) {
      // Source adapters are outside the player lifecycle. A broken cancel
      // future must not strand episode navigation after results already won.
      unawaited(cancellation.catchError((_) {}));
    }
  }

  final details = <String, DebridAvailabilityDetail>{};
  if (seenHashes.isNotEmpty) {
    try {
      final inspected = await debrid
          .inspectAvailability(apiKey, seenHashes.toList(growable: false))
          .timeout(availabilityTimeout);
      for (final entry in inspected.entries) {
        details[entry.key.toLowerCase()] = entry.value;
      }
    } on TimeoutException {
      sourceErrors.add(
        'Cache check timed out after ${availabilityTimeout.inSeconds}s.',
      );
    } catch (error) {
      sourceErrors.add('Cache check: $error');
    }
  }

  final playable = <TorrentResult>[];
  final releaseEpisodes = <TorrentResult, int?>{};
  for (final result in results) {
    final hash = validatedTorrentHash(
      declaredHash: result.hash,
      link: result.link,
    );
    final magnet = validatedTorrentMagnet(
      declaredHash: result.hash,
      link: result.link,
    );
    if (hash == null || magnet == null) continue;
    final detail = details[hash];
    final state = detail?.availability ?? Availability.unknown;
    if (state == Availability.unavailable) continue;
    if (preferences.debridCachedOnly && state != Availability.cached) continue;

    final titleEpisode = releaseEpisodeFor(
      parseFilename(result.title),
      episode: episode,
      absoluteEpisode: result.mappedEpisode,
    )?.round();
    final fileEpisode = _episodeFromFiles(
      result,
      detail?.files,
      episode: episode,
    );
    if (detail?.files != null && fileEpisode == null) continue;
    final releaseEpisode = fileEpisode ?? titleEpisode;
    if (releaseEpisode == null &&
        media.format != MediaFormat.movie &&
        media.maxEpisode != 1) {
      continue;
    }
    releaseEpisodes[result] = releaseEpisode;
    playable.add(result);
  }

  final ranked = rankBestSources(
    playable,
    preferences: preferences,
    availability: (result) {
      final hash = validatedTorrentHash(
        declaredHash: result.hash,
        link: result.link,
      );
      return details[hash]?.availability ?? Availability.unknown;
    },
  );
  final rankedHashes = <String>{};
  final releases = <PlaybackRelease>[];
  for (final result in ranked) {
    final hash = validatedTorrentHash(
      declaredHash: result.hash,
      link: result.link,
    )!;
    if (!rankedHashes.add(hash)) continue;
    releases.add(
      PlaybackRelease(
        magnet: validatedTorrentMagnet(
          declaredHash: result.hash,
          link: result.link,
        )!,
        releaseEpisode: releaseEpisodes[result],
      ),
    );
  }
  return BestSourceSearchResult(
    releases: releases,
    sourceErrors: List.unmodifiable(sourceErrors),
    timedOut: timedOut,
  );
}

List<String> sourceSearchTitles(Media media) {
  final titles = {
    media.title.userPreferred,
    media.title.romaji,
    media.title.english,
    media.title.native,
    ...media.synonyms,
  }.whereType<String>().where((item) => item.trim().isNotEmpty).toList();
  return titles.isEmpty ? [media.title.display] : titles;
}

int? _episodeFromFiles(
  TorrentResult result,
  List<DebridCachedFile>? files, {
  required int episode,
}) {
  if (files == null) return null;
  final candidates = [for (final file in files) PackFile(file.path, file.size)];
  if (!candidates.any((file) => isVideoPath(file.path))) return null;
  final episodes = <int>[
    episode,
    if (result.mappedEpisode != null && result.mappedEpisode != episode)
      result.mappedEpisode!,
  ];
  for (final candidate in episodes) {
    try {
      final picked = pickEpisodeFile(
        candidates,
        candidate.toDouble(),
        parseNames,
      );
      if (picked != null && isVideoPath(candidates[picked].path)) {
        return candidate;
      }
    } on EpisodeSelectionFailure {
      // Try absolute numbering after local numbering before rejecting the pack.
    }
  }
  return null;
}
