import '../models/media.dart';

/// Enriches a media entry with episode titles, summaries, and artwork.
/// Failure is non-fatal: the feature layer always has a numbered fallback.
abstract interface class EpisodeRepository {
  Future<List<EpisodeInfo>> episodes(Media media);
}
