/// Episode-aware Japanese subtitle acquisition for the opt-in learning mode.
///
/// The player owns track selection; this port only resolves a trusted remote
/// catalog result into one local text subtitle file. Keeping the download and
/// cache behind a port makes provider credentials and network policy invisible
/// to the player UI.
library;

enum LearningSubtitleFailureKind {
  authentication,
  rateLimited,
  unavailable,
  invalidResponse,
  unsafeFile,
}

class LearningSubtitleFailure implements Exception {
  const LearningSubtitleFailure(this.kind, this.message);

  final LearningSubtitleFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

class LearningSubtitleQuery {
  const LearningSubtitleQuery({
    required this.anilistId,
    required this.episode,
    required this.releaseName,
    this.movie = false,
  });

  final int anilistId;
  final int episode;

  /// The video/release name is a tie-breaker when a catalog has several timed
  /// variants for the same episode. It is never sent as watched subtitle text.
  final String releaseName;
  final bool movie;
}

class LearningSubtitleMatch {
  const LearningSubtitleMatch({
    required this.source,
    required this.title,
    required this.provider,
    required this.originalName,
  });

  /// A local file URI suitable for [MediaEngine.addSubtitle].
  final String source;
  final String title;
  final String provider;
  final String originalName;
}

abstract interface class LearningSubtitleRepository {
  /// Verifies that the credential can access the read-only provider API.
  Future<void> validateCredential(String credential);

  /// Returns null when the catalog has no Japanese text subtitle for the
  /// episode. Implementations download once and return a local cached file.
  Future<LearningSubtitleMatch?> findJapanese(
    LearningSubtitleQuery query, {
    required String credential,
  });
}
