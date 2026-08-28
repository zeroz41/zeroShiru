import 'dart:math' as math;

import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../../domain/ports/ports.dart';

class HomeFeed {
  const HomeFeed({
    required this.hero,
    required this.trending,
    required this.newReleases,
    required this.popular,
    this.genreSections = const [],
  });

  final List<Media> hero;
  final List<Media> trending;
  final List<Media> newReleases;
  final List<Media> popular;
  final List<HomeGenreSection> genreSections;
}

class HomeGenreSection {
  const HomeGenreSection({required this.genre, required this.media});

  final String genre;
  final List<Media> media;
}

class PersonalizedHomeFeed {
  const PersonalizedHomeFeed({
    this.continueWatching = const [],
    this.recommendations = const [],
    this.favoriteGenres = const [],
  });

  final List<ContinueWatchingItem> continueWatching;
  final List<Media> recommendations;
  final List<String> favoriteGenres;

  bool get isEmpty => continueWatching.isEmpty && recommendations.isEmpty;
}

/// One Continue Watching slot: the show plus the episode a tap should open
/// and, when the user stopped mid-episode, how far through it they were.
class ContinueWatchingItem {
  const ContinueWatchingItem({
    required this.media,
    required this.episode,
    this.resumeProgress,
  });

  final Media media;

  /// The mid-episode resume target, or the next unwatched episode.
  final int episode;

  /// Watched fraction of [episode], null when it has not been meaningfully
  /// started (the card then falls back to series progress).
  final double? resumeProgress;
}

/// The season AniList uses for northern-hemisphere anime cours.
MediaSeason mediaSeasonAt(DateTime date) => switch (date.month) {
  <= 3 => MediaSeason.winter,
  <= 6 => MediaSeason.spring,
  <= 9 => MediaSeason.summer,
  _ => MediaSeason.fall,
};

/// Loads the first useful offline-tolerant library screen. The shared query
/// cache beneath [catalog] coalesces duplicates and serves previous sessions.
Future<HomeFeed> loadHomeFeed(
  CatalogRepository catalog, {
  DateTime? now,
}) async {
  final today = now ?? DateTime.now();
  final seasonalQuery = MediaBrowseQuery(
    perPage: 25,
    sort: MediaSort.trending,
    season: mediaSeasonAt(today),
    year: today.year,
    excludedStatuses: const [MediaStatus.notYetReleased],
  );

  final pages = await Future.wait([
    catalog.browse(seasonalQuery),
    catalog.browse(
      MediaBrowseQuery(
        perPage: 25,
        sort: MediaSort.popularity,
        year: today.year,
        excludedStatuses: const [MediaStatus.notYetReleased],
      ),
    ),
    catalog.browse(
      const MediaBrowseQuery(perPage: 25, sort: MediaSort.popularity),
    ),
  ]);
  final trending = pages[0].items;
  final newReleases = pages[1].items;
  final popular = pages[2].items;
  return HomeFeed(
    hero: trending.take(8).toList(growable: false),
    trending: trending,
    newReleases: newReleases,
    popular: popular,
    genreSections: _genreSections([...trending, ...newReleases, ...popular]),
  );
}

/// Adds depth to a personalized row whose generic Home catalogue may contain
/// very few titles from the user's strongest genre. The catalogue adapter
/// supplies SWR caching; failure simply leaves the already-rendered generic
/// recommendations in place.
Future<List<Media>> loadPersonalizedGenreCandidates(
  CatalogRepository catalog,
  String genre,
) async {
  try {
    final page = await catalog.browse(
      MediaBrowseQuery(
        perPage: 25,
        sort: MediaSort.score,
        genres: [genre],
        excludedStatuses: const [MediaStatus.notYetReleased],
      ),
    );
    return page.items;
  } catch (_) {
    return const [];
  }
}

List<HomeGenreSection> _genreSections(List<Media> source) {
  const priority = [
    'Action',
    'Fantasy',
    'Comedy',
    'Romance',
    'Adventure',
    'Drama',
    'Sci-Fi',
    'Mystery',
    'Slice of Life',
    'Sports',
  ];
  final unique = <int, Media>{for (final media in source) media.id: media};
  return [
    for (final genre in priority)
      if (unique.values.where((media) => media.genres.contains(genre)).length >=
          5)
        HomeGenreSection(
          genre: genre,
          media: unique.values
              .where((media) => media.genres.contains(genre))
              .take(25)
              .toList(growable: false),
        ),
  ].take(3).toList(growable: false);
}

/// Builds a small, explainable recommendation set from the user's active
/// watches. It deliberately re-ranks the already cached home catalogue rather
/// than adding another network request to startup.
///
/// Progress evidence comes from two places: the local watch history (always
/// present, no account required) and the tracker's Currently Watching list.
/// Local history leads Continue Watching because it is ordered by when the
/// user actually pressed play here, then tracker-only shows follow.
///
/// Recommendation ranking is intentionally not a genre filter. Established
/// profiles reserve every fifth slot for discovery; low-confidence profiles
/// explore sooner. A final diversity pass keeps one franchise and one exact
/// taste cluster from flooding the row.
Future<PersonalizedHomeFeed> loadPersonalizedHomeFeed(
  TrackingRepository tracking,
  HomeFeed home, {
  List<WatchHistoryEntry> localHistory = const [],
  DateTime? now,
}) async {
  List<Media> watching;
  try {
    watching = await tracking.userList(ListStatus.current);
  } catch (_) {
    // A tracker outage (or no account) must not empty the local rails.
    watching = const [];
  }

  return buildPersonalizedHomeFeed(
    home,
    watching: watching,
    localHistory: localHistory,
    now: now,
  );
}

/// Pure personalization pass used by Home so local history can render without
/// waiting for a remote tracker. Re-running it when tracker or catalog data
/// arrives is cheap: the input is at most a few cached catalogue pages.
PersonalizedHomeFeed buildPersonalizedHomeFeed(
  HomeFeed home, {
  List<Media> watching = const [],
  List<WatchHistoryEntry> localHistory = const [],
  DateTime? now,
}) {
  final continueWatching = <ContinueWatchingItem>[];
  final continueIds = <int>{};
  for (final entry in localHistory) {
    final maximum = entry.media.maxEpisode;
    final finished =
        entry.resume == null &&
        maximum != null &&
        entry.watchedThrough >= maximum;
    if (finished) continue;
    if (entry.watchedThrough == 0 && entry.resume == null) continue;
    if (!continueIds.add(entry.media.id)) continue;
    final fraction = entry.resume?.fraction ?? 0;
    continueWatching.add(
      ContinueWatchingItem(
        media: entry.media.withListEntry(
          ListEntry(status: ListStatus.current, progress: entry.watchedThrough),
        ),
        episode: entry.nextEpisode,
        resumeProgress: fraction > 0 ? fraction : null,
      ),
    );
  }
  for (final media in watching) {
    final progress = media.listEntry?.progress ?? 0;
    final maximum = media.maxEpisode;
    final active = progress > 0 && (maximum == null || progress < maximum);
    if (active && continueIds.add(media.id)) {
      continueWatching.add(
        ContinueWatchingItem(media: media, episode: progress + 1),
      );
    }
  }

  final referenceTime = now ?? DateTime.now();
  final tasteSeeds = <int, _TasteSeed>{};
  void rememberTaste(Media media, double evidence) {
    if (evidence <= 0 || media.genres.isEmpty) return;
    final previous = tasteSeeds[media.id];
    tasteSeeds[media.id] = _TasteSeed(
      media:
          previous != null && previous.media.genres.length > media.genres.length
          ? previous.media
          : media,
      // Local history and a tracker entry for the same show are corroborating
      // records, not two independent votes.
      evidence: math.max(previous?.evidence ?? 0, evidence),
    );
  }

  for (final media in watching) {
    rememberTaste(media, _trackerTasteEvidence(media));
  }
  for (final entry in localHistory) {
    rememberTaste(entry.media, _localTasteEvidence(entry, referenceTime));
  }

  final profileConfidence =
      (1 -
              math.exp(
                -tasteSeeds.values.fold<double>(
                      0,
                      (sum, seed) => sum + seed.evidence,
                    ) /
                    2.5,
              ))
          .clamp(0.0, 1.0);

  final affinity = <String, double>{};
  for (final seed in tasteSeeds.values) {
    final genres = seed.media.genres
        .map((genre) => genre.trim())
        .where((genre) => genre.isNotEmpty)
        .toSet();
    if (genres.isEmpty) continue;
    // One show contributes one vote in total. A title carrying five genre
    // labels must not count five times as much as a focused slice-of-life show.
    final contribution = seed.evidence / genres.length;
    for (final genre in genres) {
      affinity.update(
        genre,
        (score) => score + contribution,
        ifAbsent: () => contribution,
      );
    }
  }
  final favoriteGenres = affinity.keys.toList(growable: false)
    ..sort((a, b) {
      final byWeight = affinity[b]!.compareTo(affinity[a]!);
      return byWeight != 0 ? byWeight : a.compareTo(b);
    });

  final watchedIds = {
    for (final media in watching) media.id,
    for (final entry in localHistory) entry.media.id,
  };
  final catalogCandidates = <int, _CatalogCandidate>{};
  var catalogOrder = 0;
  void addCandidates(List<Media> media, double sourcePrior) {
    for (final item in media) {
      if (watchedIds.contains(item.id)) continue;
      final previous = catalogCandidates[item.id];
      catalogCandidates[item.id] = _CatalogCandidate(
        media: item,
        sourcePrior: math.max(previous?.sourcePrior ?? 0, sourcePrior),
        order: previous?.order ?? catalogOrder++,
      );
    }
  }

  addCandidates(home.trending, 1);
  addCandidates(home.newReleases, 0.8);
  addCandidates(home.popular, 0.6);

  final dominantGenres = favoriteGenres.isEmpty
      ? const <String>[]
      : favoriteGenres
            .where(
              (genre) =>
                  affinity[genre]! >= affinity[favoriteGenres.first]! * 0.55,
            )
            .take(2)
            .toList(growable: false);
  // One accidental partial play is useful weak evidence, but not enough to
  // publicly label the user's taste or trigger an extra catalogue request.
  final shownFavoriteGenres = profileConfidence >= 0.18
      ? dominantGenres
      : const <String>[];
  final watchedFranchises = {
    for (final seed in tasteSeeds.values)
      _franchiseKey(seed.media.title.display),
  };
  final recommendations = affinity.isEmpty
      ? const <Media>[]
      : _rankRecommendations(
          catalogCandidates.values,
          affinity: affinity,
          dominantGenres: dominantGenres.toSet(),
          profileConfidence: profileConfidence,
          excludedFranchises: watchedFranchises,
        );

  return PersonalizedHomeFeed(
    continueWatching: continueWatching,
    recommendations: recommendations,
    favoriteGenres: shownFavoriteGenres,
  );
}

class _TasteSeed {
  const _TasteSeed({required this.media, required this.evidence});

  final Media media;
  final double evidence;
}

double _trackerTasteEvidence(Media media) {
  final progress = media.listEntry?.progress ?? 0;
  if (progress <= 0) return 0;
  final maximum = media.maxEpisode;
  final fraction = maximum != null && maximum > 0
      ? (progress / maximum).clamp(0.0, 1.0)
      : progress / (progress + 3);
  final score = media.listEntry?.score;
  final ratingConfidence = score == null || score <= 0
      ? 1.0
      : (0.5 + score / 20).clamp(0.5, 1.0);
  return (0.20 + 0.80 * math.sqrt(fraction)) * ratingConfidence;
}

double _localTasteEvidence(WatchHistoryEntry entry, DateTime now) {
  final consumed = entry.watchedThrough + (entry.resume?.fraction ?? 0);
  if (consumed <= 0) return 0;
  final maximum = entry.media.maxEpisode;
  final fraction = maximum != null && maximum > 0
      ? (consumed / maximum).clamp(0.0, 1.0)
      : consumed / (consumed + 3);
  final ageInDays = math.max(0, now.difference(entry.updatedAt).inHours / 24);
  // Smooth decay: recent watches lead, but an old favorite never becomes a
  // negative signal. Weight halves after roughly six months.
  final recency = 1 / (1 + ageInDays / 180);
  return (0.10 + 0.90 * math.sqrt(fraction)) * recency;
}

class _CatalogCandidate {
  const _CatalogCandidate({
    required this.media,
    required this.sourcePrior,
    required this.order,
  });

  final Media media;
  final double sourcePrior;
  final int order;
}

class _RankedCandidate {
  const _RankedCandidate({
    required this.media,
    required this.relevance,
    required this.quality,
    required this.baseScore,
    required this.order,
  });

  final Media media;
  final double relevance;
  final double quality;
  final double baseScore;
  final int order;
}

List<Media> _rankRecommendations(
  Iterable<_CatalogCandidate> source, {
  required Map<String, double> affinity,
  required Set<String> dominantGenres,
  required double profileConfidence,
  required Set<String> excludedFranchises,
}) {
  final userMagnitude = math.sqrt(
    affinity.values.fold<double>(0, (sum, value) => sum + value * value),
  );
  final ranked = <_RankedCandidate>[];
  for (final candidate in source) {
    if (excludedFranchises.contains(
      _franchiseKey(candidate.media.title.display),
    )) {
      continue;
    }
    final genres = candidate.media.genres.toSet();
    final dotProduct = genres.fold<double>(
      0,
      (sum, genre) => sum + (affinity[genre] ?? 0),
    );
    // Cosine similarity prevents a title with many labels from winning just
    // because it has more chances to overlap the profile.
    final relevance = genres.isEmpty || userMagnitude == 0
        ? 0.0
        : dotProduct / (userMagnitude * math.sqrt(genres.length));
    final quality = ((candidate.media.averageScore ?? 55) / 100).clamp(
      0.0,
      1.0,
    );
    final personalizationWeight = 0.42 + profileConfidence * 0.30;
    final qualityWeight = 0.40 - profileConfidence * 0.20;
    final sourceWeight = 0.18 - profileConfidence * 0.10;
    ranked.add(
      _RankedCandidate(
        media: candidate.media,
        relevance: relevance,
        quality: quality,
        baseScore:
            relevance * personalizationWeight +
            quality * qualityWeight +
            candidate.sourcePrior * sourceWeight -
            _installmentPenalty(candidate.media.title.display),
        order: candidate.order,
      ),
    );
  }

  // AniList returns seasons as separate media. Keep the strongest likely
  // entry point for each recognizable franchise instead of showing a wall of
  // sequels. Unknown title structures simply remain independent candidates.
  final byFranchise = <String, _RankedCandidate>{};
  for (final candidate in ranked) {
    final key = _franchiseKey(candidate.media.title.display);
    final current = byFranchise[key];
    if (current == null || _compareCandidates(candidate, current) < 0) {
      byFranchise[key] = candidate;
    }
  }

  final remaining = byFranchise.values.toList();
  final selected = <_RankedCandidate>[];
  final discoveryInterval = profileConfidence < 0.40
      ? 3
      : profileConfidence < 0.70
      ? 4
      : 5;
  while (remaining.isNotEmpty && selected.length < 25) {
    final discoverySlot = (selected.length + 1) % discoveryInterval == 0;
    var pool = discoverySlot
        ? remaining.where(
            (candidate) => candidate.media.genres.every(
              (genre) => !dominantGenres.contains(genre),
            ),
          )
        : remaining.where((candidate) => candidate.relevance > 0);
    if (pool.isEmpty) pool = remaining;
    final next = pool.reduce(
      (best, candidate) =>
          _diversifiedScore(candidate, selected) >
              _diversifiedScore(best, selected)
          ? candidate
          : _diversifiedScore(candidate, selected) ==
                    _diversifiedScore(best, selected) &&
                _compareCandidates(candidate, best) < 0
          ? candidate
          : best,
    );
    selected.add(next);
    remaining.remove(next);
  }
  return selected.map((candidate) => candidate.media).toList(growable: false);
}

double _diversifiedScore(
  _RankedCandidate candidate,
  List<_RankedCandidate> selected,
) {
  if (selected.isEmpty) return candidate.baseScore;
  final genres = candidate.media.genres.toSet();
  var greatestOverlap = 0.0;
  for (final prior in selected) {
    final other = prior.media.genres.toSet();
    final union = {...genres, ...other}.length;
    if (union == 0) continue;
    final overlap = genres.intersection(other).length / union;
    greatestOverlap = math.max(greatestOverlap, overlap);
  }
  return candidate.baseScore - greatestOverlap * 0.10;
}

int _compareCandidates(_RankedCandidate a, _RankedCandidate b) {
  final byScore = b.baseScore.compareTo(a.baseScore);
  if (byScore != 0) return byScore;
  final byQuality = b.quality.compareTo(a.quality);
  return byQuality != 0 ? byQuality : a.order.compareTo(b.order);
}

String _franchiseKey(String title) {
  final normalized = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  // AniList can honor a native-title preference. Do not collapse unrelated
  // Japanese/Chinese titles into one empty ASCII key.
  if (normalized.isEmpty) return title.toLowerCase().trim();
  final words = normalized.split(RegExp(r'\s+'));

  var cut = words.length;
  for (var index = 1; index < words.length; index++) {
    final word = words[index];
    if (word == 'season' || word == 'cour') {
      cut = index;
      if (index > 1 && words[index - 1] == 'final') cut--;
      if (cut > 1 && words[cut - 1] == 'the') cut--;
      if (cut > 1 && _isOrdinal(words[cut - 1])) cut--;
      break;
    }
    if (word == 'part' &&
        index + 1 < words.length &&
        _isInstallmentNumber(words[index + 1])) {
      cut = index;
      break;
    }
  }
  if (cut == words.length && words.length > 2 && _isRomanNumeral(words.last)) {
    cut--;
  }
  final family = words.take(cut).join(' ');
  return family.isEmpty ? words.join(' ') : family;
}

double _installmentPenalty(String title) {
  final normalized = title.toLowerCase();
  if (RegExp(r'\b(?:the\s+)?final\s+season\b').hasMatch(normalized)) {
    return 0.16;
  }
  final season = RegExp(
    r'\b(\d+)(?:st|nd|rd|th)?\s+season\b|\bseason\s+(\d+)\b',
  ).firstMatch(normalized);
  final seasonNumber = int.tryParse(season?.group(1) ?? season?.group(2) ?? '');
  if (seasonNumber != null && seasonNumber > 1) {
    return math.min(0.16, (seasonNumber - 1) * 0.05);
  }
  final part = RegExp(r'\bpart\s+(\d+)\b').firstMatch(normalized);
  final partNumber = int.tryParse(part?.group(1) ?? '');
  if (partNumber != null && partNumber > 1) {
    return math.min(0.10, (partNumber - 1) * 0.04);
  }
  final normalizedKey = normalized
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (normalizedKey.isNotEmpty && _franchiseKey(title) != normalizedKey) {
    return 0.05;
  }
  return 0;
}

bool _isOrdinal(String word) => RegExp(r'^\d+(?:st|nd|rd|th)$').hasMatch(word);

bool _isInstallmentNumber(String word) =>
    int.tryParse(word) != null || _isRomanNumeral(word);

bool _isRomanNumeral(String word) => RegExp(r'^[ivx]{1,4}$').hasMatch(word);
