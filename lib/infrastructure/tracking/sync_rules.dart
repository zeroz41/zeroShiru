/// The "when does a watch count" rules — a pure port of the redo branch's
/// `Helper.updateEntry` (providers/helper.js:154).
///
/// The playback threshold gate (85% watched, 70% for external players, once
/// per file) is the CALLER's job. This module applies everything after it:
///
/// 1. refuse when the file failed to resolve;
/// 2. refuse when the media status is CANCELLED;
/// 3. `videoEpisode = (episode || singleEpisode) + (zeroEpisode ? 1 : 0)`;
/// 4. refuse when the episode numbers cannot be resolved at all;
/// 5. refuse when `videoEpisode > maxEpisode`;
/// 6. NEVER move progress backwards (refuse when progress > videoEpisode);
/// 7. refuse redundant same-progress writes, unless it is the final episode
///    or a single-episode work;
/// 8. status is REPEATING when it already was, else CURRENT; COMPLETED when
///    `videoEpisode == maxEpisode` and the show is not NOT_YET_RELEASED,
///    incrementing `repeat` on a rewatch completion;
/// 9. fuzzy dates: startedAt filled on CURRENT/REPEATING, completedAt on
///    COMPLETED, existing complete dates always win; when startedAt would
///    sort after completedAt, completedAt becomes today and startedAt
///    yesterday;
/// 10. only send when status/progress/score/repeat actually changed;
/// 11. score is x10 for AniList (POINT_10 -> POINT_100), raw for MAL.
///
/// Everything is pure: state in, decision out — nothing is fetched, nothing
/// is mutated, no clock is read (the caller passes `now`).
library;

import '../../domain/models/media.dart';

/// Which provider the mutation is destined for. Decides score scaling only.
enum TrackingProvider { aniList, myAnimeList }

/// Year/month/day triple as AniList models it. Any component may be missing.
class FuzzyDate {
  const FuzzyDate({this.year, this.month, this.day});

  factory FuzzyDate.of(DateTime date) =>
      FuzzyDate(year: date.year, month: date.month, day: date.day);

  final int? year;
  final int? month;
  final int? day;

  /// The old code only trusts a date that has all three components.
  bool get isComplete => year != null && month != null && day != null;

  /// Sortable `yyyy-mm-dd`; only meaningful when [isComplete].
  String get sortKey =>
      '${(year ?? 0).toString().padLeft(4, '0')}-'
      '${(month ?? 0).toString().padLeft(2, '0')}-'
      '${(day ?? 0).toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {'year': year, 'month': month, 'day': day};

  @override
  bool operator ==(Object other) =>
      other is FuzzyDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => sortKey;
}

/// The user's existing list entry, as the rules need to see it.
///
/// The domain [ListEntry] lacks the fuzzy dates, so this snapshot carries
/// them separately; callers that only have a domain entry pass null dates.
class SyncListState {
  const SyncListState({
    this.status,
    this.progress,
    this.score,
    this.repeat = 0,
    this.startedAt,
    this.completedAt,
    this.enabledCustomLists = const [],
  });

  factory SyncListState.fromDomain(ListEntry entry) => SyncListState(
    status: entry.status,
    progress: entry.progress,
    score: entry.score,
    repeat: entry.repeat,
    enabledCustomLists: entry.customLists,
  );

  final ListStatus? status;
  final int? progress;

  /// POINT_10 scale (what AniList returns with `score(format: POINT_10)`,
  /// and what MAL uses natively).
  final double? score;
  final int repeat;
  final FuzzyDate? startedAt;
  final FuzzyDate? completedAt;
  final List<String> enabledCustomLists;
}

/// Everything the rules need to know about the show being watched.
class SyncMediaState {
  const SyncMediaState({
    required this.id,
    this.idMal,
    this.status,
    this.format,
    this.episodes,
    this.maxEpisode,
    this.zeroEpisode = false,
    this.listEntry,
  });

  final int id;
  final int? idMal;
  final MediaStatus? status;
  final MediaFormat? format;

  /// Total episode count; null while unknown/releasing.
  final int? episodes;

  /// Highest episode that can currently exist (`getMediaMaxEp`) — the domain
  /// [Media.maxEpisode] getter for callers that have a domain model.
  final int? maxEpisode;

  /// Whether this show has an "Episode 0" (offsets file episode numbers +1).
  final bool zeroEpisode;

  final SyncListState? listEntry;
}

enum SyncRefusalReason {
  /// The file failed to resolve to a media — never write blind.
  resolveFailed,

  /// The media was CANCELLED on the tracker.
  mediaCancelled,

  /// Neither a video episode nor a max episode could be determined.
  episodeUnresolvable,

  /// The watched episode is beyond anything that can currently exist.
  beyondLatestEpisode,

  /// The user's progress is already further along — progress never regresses.
  progressWouldRegress,

  /// Same-progress write that is neither the final episode nor a
  /// single-episode work.
  redundantProgress,

  /// Status, progress, score and repeat are all unchanged — nothing to send.
  noChange,
}

sealed class SyncDecision {
  const SyncDecision();
}

class SyncRefusal extends SyncDecision {
  const SyncRefusal(this.reason);

  final SyncRefusalReason reason;

  @override
  String toString() => 'SyncRefusal(${reason.name})';
}

/// The mutation to send. [score] is already provider-scaled: POINT_100 int
/// for AniList, raw 0-10 for MAL.
class SyncMutation extends SyncDecision {
  const SyncMutation({
    required this.mediaId,
    this.idMal,
    required this.status,
    required this.progress,
    required this.score,
    required this.repeat,
    this.startedAt,
    this.completedAt,
    this.customLists = const [],
    required this.startsNewRewatch,
  });

  final int mediaId;
  final int? idMal;
  final ListStatus status;
  final int progress;
  final int score;
  final int repeat;
  final FuzzyDate? startedAt;
  final FuzzyDate? completedAt;
  final List<String> customLists;

  /// True when this write flips the entry into REPEATING for the first time
  /// (the old app reset local anime progress on a new rewatch).
  final bool startsNewRewatch;
}

/// Fuzzy-date fill, ported from `Helper.getFuzzyDate`. Existing complete
/// dates always win; otherwise startedAt is stamped today on
/// CURRENT/REPEATING and completedAt today on COMPLETED. An inverted pair
/// (start after finish) collapses to yesterday/today.
({FuzzyDate? startedAt, FuzzyDate? completedAt}) fuzzyDatesFor({
  required SyncListState? existing,
  required ListStatus status,
  required DateTime now,
}) {
  final today = FuzzyDate.of(now);
  var startedAt = (existing?.startedAt?.isComplete ?? false)
      ? existing!.startedAt
      : (status == ListStatus.current || status == ListStatus.repeating
            ? today
            : null);
  var completedAt = (existing?.completedAt?.isComplete ?? false)
      ? existing!.completedAt
      : (status == ListStatus.completed ? today : null);
  if (startedAt != null &&
      completedAt != null &&
      startedAt.sortKey.compareTo(completedAt.sortKey) > 0) {
    completedAt = today;
    startedAt = FuzzyDate.of(now.subtract(const Duration(days: 1)));
  }
  return (startedAt: startedAt, completedAt: completedAt);
}

/// Applies the rules. [episode] is the episode number parsed from the file
/// (null/0 when the file carries none — movies, single-episode OVAs).
SyncDecision decideEntryUpdate({
  required SyncMediaState media,
  int? episode,
  bool failed = false,
  required TrackingProvider provider,
  required DateTime now,
}) {
  // 1. Refuse when the resolve failed — "Failed to Update Progress".
  if (failed) return const SyncRefusal(SyncRefusalReason.resolveFailed);

  // 2. Refuse cancelled media. NOT_YET_RELEASED is deliberately allowed:
  //    AniList can lag behind leaks/early releases.
  if (media.status == MediaStatus.cancelled) {
    return const SyncRefusal(SyncRefusalReason.mediaCancelled);
  }

  // 3. Episode arithmetic. Some OVAs/movies are a single unnumbered episode;
  //    zero-episode shows offset everything by one.
  final singleEpisode =
      ((media.episodes == null && (episode == null || episode == 1)) ||
          (media.format == MediaFormat.movie && media.episodes == 1))
      ? 1
      : 0;
  final videoEpisode =
      ((episode ?? 0) != 0 ? episode! : singleEpisode) +
      (media.zeroEpisode ? 1 : 0);
  final maxEpisode = (media.maxEpisode ?? 0) != 0
      ? media.maxEpisode!
      : singleEpisode;

  // 4. Nothing resolvable at all.
  if (videoEpisode == 0 || maxEpisode == 0) {
    return const SyncRefusal(SyncRefusalReason.episodeUnresolvable);
  }

  // 5. Beyond anything that can currently exist.
  if (videoEpisode > maxEpisode) {
    return const SyncRefusal(SyncRefusalReason.beyondLatestEpisode);
  }

  final existing = media.listEntry;
  final progress = existing?.progress;

  // 6. Progress NEVER moves backwards.
  if (progress != null && progress > videoEpisode) {
    return const SyncRefusal(SyncRefusalReason.progressWouldRegress);
  }

  // 7. No redundant same-progress writes — unless it is the final episode
  //    (completion may still need to be recorded) or a single-episode work.
  if (progress != null &&
      progress == videoEpisode &&
      videoEpisode != maxEpisode &&
      singleEpisode == 0) {
    return const SyncRefusal(SyncRefusalReason.redundantProgress);
  }

  // 8. Status and repeat.
  final wasRepeating = existing?.status == ListStatus.repeating;
  var status = wasRepeating ? ListStatus.repeating : ListStatus.current;
  var repeat = existing?.repeat ?? 0;
  if (videoEpisode == maxEpisode &&
      media.status != MediaStatus.notYetReleased) {
    // No chance you watched the whole season of something unreleased.
    status = ListStatus.completed;
    if (wasRepeating) repeat = (existing?.repeat ?? 0) + 1;
  }

  // 11. Provider score scaling (POINT_10 -> POINT_100 for AniList, raw MAL).
  final existingScore = existing?.score ?? 0;
  final score = provider == TrackingProvider.aniList
      ? (existingScore * 10).round()
      : existingScore.round();

  // 9. Fuzzy dates for the final status.
  final dates = fuzzyDatesFor(existing: existing, status: status, now: now);

  // 10. Only send when something actually changed.
  final scoreUnchanged = provider == TrackingProvider.aniList
      ? existingScore == score / 10
      : existingScore == score.toDouble();
  if (existing?.status == status &&
      existing?.progress == videoEpisode &&
      scoreUnchanged &&
      (existing?.repeat ?? 0) == repeat) {
    return const SyncRefusal(SyncRefusalReason.noChange);
  }

  return SyncMutation(
    mediaId: media.id,
    idMal: media.idMal,
    status: status,
    progress: videoEpisode,
    score: score,
    repeat: repeat,
    startedAt: dates.startedAt,
    completedAt: dates.completedAt,
    customLists: existing?.enabledCustomLists ?? const [],
    startsNewRewatch: status == ListStatus.repeating && !wasRepeating,
  );
}
