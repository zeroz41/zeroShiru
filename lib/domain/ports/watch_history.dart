/// Local watch history: what the player records and the home rails read.
///
/// This store is tracker-independent. AniList/MAL sync layers on top of it —
/// a connected account mirrors completions outward, but Continue Watching,
/// resume positions, and personalization all work from this local record
/// alone, so a fresh install with no account still has a working history.
library;

import '../models/media.dart';

/// A partial below this floor is "barely opened": not worth resuming, not
/// worth a Continue Watching slot. Shared by the store (read filtering) and
/// the player (resume decision).
const Duration minimumMeaningfulWatch = Duration(seconds: 30);

/// One episode's recorded playback state.
class EpisodeWatchProgress {
  const EpisodeWatchProgress({
    required this.mediaId,
    required this.episode,
    required this.position,
    required this.duration,
    required this.completed,
    required this.updatedAt,
  });

  final int mediaId;
  final int episode;
  final Duration position;
  final Duration duration;

  /// Sticky: once an episode crosses the completion threshold it stays
  /// completed, even if the user later rewatches part of it.
  final bool completed;
  final DateTime updatedAt;

  double get fraction => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

/// A show the user has watched, with enough state to resume it.
class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.media,
    required this.watchedThrough,
    required this.updatedAt,
    this.resume,
  });

  /// Snapshot of the show as it was when last played; carries no list entry.
  final Media media;

  /// Highest episode recorded as completed, 0 when none finished yet.
  final int watchedThrough;

  /// Most recent meaningfully-started but uncompleted episode, if any.
  final EpisodeWatchProgress? resume;

  final DateTime updatedAt;

  /// The episode a Continue Watching action should open.
  int get nextEpisode => resume?.episode ?? watchedThrough + 1;
}

abstract interface class WatchHistoryRepository {
  /// Upserts playback state for one episode. [completed] latches true and is
  /// never un-set by later partial positions.
  Future<void> record({
    required Media media,
    required int episode,
    required Duration position,
    required Duration duration,
    bool completed = false,
  });

  Future<EpisodeWatchProgress?> progressFor(int mediaId, int episode);

  /// Every recorded episode of one show, ordered by episode number.
  Future<List<EpisodeWatchProgress>> progressForMedia(int mediaId);

  /// Highest completed episode for the show, 0 when none.
  Future<int> watchedThrough(int mediaId);

  /// Shows most recently played first.
  Future<List<WatchHistoryEntry>> recent({int limit = 30});

  /// Removes one show (and its episode rows) from history.
  Future<void> forget(int mediaId);

  /// Fires after any mutation so rails can refresh.
  Stream<void> get changes;
}
