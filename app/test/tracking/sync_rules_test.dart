/// Table-driven tests for the ported Helper.updateEntry rules — every
/// refusal and every transition.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/models/media.dart';
import 'package:zeroshiru/infrastructure/tracking/sync_rules.dart';

void main() {
  final now = DateTime(2026, 8, 23, 20, 0, 0);
  final today = FuzzyDate.of(now);
  final yesterday = FuzzyDate.of(now.subtract(const Duration(days: 1)));

  SyncMediaState show({
    int? episodes = 12,
    int? maxEpisode,
    MediaStatus? status = MediaStatus.releasing,
    MediaFormat? format = MediaFormat.tv,
    bool zeroEpisode = false,
    SyncListState? entry,
  }) => SyncMediaState(
    id: 1,
    idMal: 100,
    status: status,
    format: format,
    episodes: episodes,
    maxEpisode: maxEpisode ?? episodes,
    zeroEpisode: zeroEpisode,
    listEntry: entry,
  );

  SyncDecision decide(
    SyncMediaState media, {
    int? episode,
    bool failed = false,
    TrackingProvider provider = TrackingProvider.aniList,
  }) => decideEntryUpdate(
    media: media,
    episode: episode,
    failed: failed,
    provider: provider,
    now: now,
  );

  SyncRefusalReason? refusalOf(SyncDecision decision) =>
      decision is SyncRefusal ? decision.reason : null;

  group('refusals', () {
    test('resolve failure refuses before anything else', () {
      final decision = decide(show(), episode: 5, failed: true);
      expect(refusalOf(decision), SyncRefusalReason.resolveFailed);
    });

    test('CANCELLED media refuses', () {
      final decision = decide(show(status: MediaStatus.cancelled), episode: 5);
      expect(refusalOf(decision), SyncRefusalReason.mediaCancelled);
    });

    test('NOT_YET_RELEASED media is deliberately allowed (leaks happen)', () {
      final decision = decide(
        show(status: MediaStatus.notYetReleased),
        episode: 5,
      );
      expect(decision, isA<SyncMutation>());
    });

    test('no resolvable episode numbers refuses', () {
      // episodes known (so not single-episode) but episode 2 of a show with
      // no max: nothing can be computed.
      final decision = decide(
        show(episodes: null, maxEpisode: null),
        episode: 2,
      );
      expect(refusalOf(decision), SyncRefusalReason.episodeUnresolvable);
    });

    test('episode beyond the latest possible refuses', () {
      final decision = decide(show(episodes: 12), episode: 13);
      expect(refusalOf(decision), SyncRefusalReason.beyondLatestEpisode);
    });

    test('progress NEVER moves backwards', () {
      final decision = decide(
        show(
          entry: const SyncListState(status: ListStatus.current, progress: 8),
        ),
        episode: 5,
      );
      expect(refusalOf(decision), SyncRefusalReason.progressWouldRegress);
    });

    test('same-progress mid-season write is redundant', () {
      final decision = decide(
        show(
          entry: const SyncListState(status: ListStatus.current, progress: 5),
        ),
        episode: 5,
      );
      expect(refusalOf(decision), SyncRefusalReason.redundantProgress);
    });

    test('same-progress write on the FINAL episode is not redundant', () {
      // Completion may still need to be recorded (status changes).
      final decision = decide(
        show(
          episodes: 12,
          entry: const SyncListState(status: ListStatus.current, progress: 12),
        ),
        episode: 12,
      );
      expect(decision, isA<SyncMutation>());
      expect((decision as SyncMutation).status, ListStatus.completed);
    });

    test('same-progress write on a single-episode work is not redundant', () {
      final decision = decide(
        show(
          episodes: 1,
          format: MediaFormat.movie,
          status: MediaStatus.finished,
          entry: const SyncListState(status: ListStatus.current, progress: 1),
        ),
        episode: 1,
      );
      expect(decision, isA<SyncMutation>());
    });

    test(
      'no actual change refuses (status/progress/score/repeat all equal)',
      () {
        // COMPLETED at final episode, already completed, score & repeat same.
        final decision = decide(
          show(
            episodes: 1,
            format: MediaFormat.movie,
            status: MediaStatus.finished,
            entry: const SyncListState(
              status: ListStatus.completed,
              progress: 1,
              score: 8,
              repeat: 0,
            ),
          ),
          episode: 1,
        );
        expect(refusalOf(decision), SyncRefusalReason.noChange);
      },
    );
  });

  group('episode arithmetic', () {
    test('movies / single-episode works count as episode 1 with no number', () {
      final decision = decide(
        show(
          episodes: 1,
          format: MediaFormat.movie,
          status: MediaStatus.finished,
        ),
        episode: null,
      );
      final mutation = decision as SyncMutation;
      expect(mutation.progress, 1);
      expect(mutation.status, ListStatus.completed);
    });

    test('unknown-count works with episode 1 count as single episode', () {
      final decision = decide(
        show(episodes: null, maxEpisode: null, status: MediaStatus.finished),
        episode: 1,
      );
      final mutation = decision as SyncMutation;
      expect(mutation.progress, 1);
      expect(mutation.status, ListStatus.completed);
    });

    test('zero-episode shows are offset by one', () {
      final decision = decide(
        show(episodes: 13, zeroEpisode: true),
        episode: 4, // file says episode 4 -> tracker episode 5
      );
      expect((decision as SyncMutation).progress, 5);
    });

    test('zero-episode offset can push past the max and refuse', () {
      final decision = decide(
        show(episodes: 12, zeroEpisode: true),
        episode: 12,
      );
      expect(refusalOf(decision), SyncRefusalReason.beyondLatestEpisode);
    });
  });

  group('status transitions', () {
    test('fresh watch of a mid-season episode goes CURRENT', () {
      final decision = decide(show(), episode: 5);
      final mutation = decision as SyncMutation;
      expect(mutation.status, ListStatus.current);
      expect(mutation.progress, 5);
      expect(mutation.repeat, 0);
      expect(mutation.startsNewRewatch, isFalse);
    });

    test('an already-REPEATING entry stays REPEATING mid-season', () {
      final decision = decide(
        show(
          episodes: 12,
          entry: const SyncListState(
            status: ListStatus.repeating,
            progress: 3,
            repeat: 1,
          ),
        ),
        episode: 5,
      );
      expect((decision as SyncMutation).status, ListStatus.repeating);
      expect(decision.repeat, 1);
    });

    test('final episode of a released show completes', () {
      final decision = decide(
        show(
          episodes: 12,
          status: MediaStatus.finished,
          entry: const SyncListState(status: ListStatus.current, progress: 11),
        ),
        episode: 12,
      );
      final mutation = decision as SyncMutation;
      expect(mutation.status, ListStatus.completed);
      expect(
        mutation.repeat,
        0,
        reason: 'first completion does not bump repeat',
      );
    });

    test('final episode while NOT_YET_RELEASED does NOT complete', () {
      final decision = decide(
        show(episodes: 12, status: MediaStatus.notYetReleased),
        episode: 12,
      );
      expect((decision as SyncMutation).status, ListStatus.current);
    });

    test('rewatch completion increments repeat', () {
      final decision = decide(
        show(
          episodes: 12,
          status: MediaStatus.finished,
          entry: const SyncListState(
            status: ListStatus.repeating,
            progress: 11,
            repeat: 2,
          ),
        ),
        episode: 12,
      );
      final mutation = decision as SyncMutation;
      expect(mutation.status, ListStatus.completed);
      expect(mutation.repeat, 3);
    });
  });

  group('fuzzy dates', () {
    test('startedAt stamped today on a fresh CURRENT write', () {
      final decision = decide(show(), episode: 5);
      final mutation = decision as SyncMutation;
      expect(mutation.startedAt, today);
      expect(mutation.completedAt, isNull);
    });

    test('completedAt stamped today on completion', () {
      final decision = decide(
        show(episodes: 12, status: MediaStatus.finished),
        episode: 12,
      );
      final mutation = decision as SyncMutation;
      expect(mutation.completedAt, today);
    });

    test('existing complete startedAt is preserved', () {
      const started = FuzzyDate(year: 2024, month: 1, day: 5);
      final decision = decide(
        show(
          entry: const SyncListState(
            status: ListStatus.current,
            progress: 2,
            startedAt: started,
          ),
        ),
        episode: 5,
      );
      expect((decision as SyncMutation).startedAt, started);
    });

    test('incomplete existing dates are replaced, not trusted', () {
      const partial = FuzzyDate(year: 2024); // month/day missing
      final decision = decide(
        show(
          entry: const SyncListState(
            status: ListStatus.current,
            progress: 2,
            startedAt: partial,
          ),
        ),
        episode: 5,
      );
      expect((decision as SyncMutation).startedAt, today);
    });

    test('startedAt after completedAt collapses to yesterday/today', () {
      const started = FuzzyDate(year: 2030, month: 1, day: 1); // in the future
      final decision = decide(
        show(
          episodes: 12,
          status: MediaStatus.finished,
          entry: const SyncListState(
            status: ListStatus.current,
            progress: 11,
            startedAt: started,
          ),
        ),
        episode: 12,
      );
      final mutation = decision as SyncMutation;
      expect(mutation.completedAt, today);
      expect(mutation.startedAt, yesterday);
    });
  });

  group('score scaling', () {
    test('AniList score is x10 (POINT_10 -> POINT_100)', () {
      final decision = decide(
        show(
          entry: const SyncListState(
            status: ListStatus.current,
            progress: 2,
            score: 8.5,
          ),
        ),
        episode: 5,
        provider: TrackingProvider.aniList,
      );
      expect((decision as SyncMutation).score, 85);
    });

    test('MAL score stays raw', () {
      final decision = decide(
        show(
          entry: const SyncListState(
            status: ListStatus.current,
            progress: 2,
            score: 8,
          ),
        ),
        episode: 5,
        provider: TrackingProvider.myAnimeList,
      );
      expect((decision as SyncMutation).score, 8);
    });

    test('no score sends 0', () {
      final decision = decide(show(), episode: 5);
      expect((decision as SyncMutation).score, 0);
    });
  });

  group('custom lists', () {
    test('enabled custom lists ride along on the mutation', () {
      final decision = decide(
        show(
          entry: const SyncListState(
            status: ListStatus.current,
            progress: 2,
            enabledCustomLists: ['Rewatch Club'],
          ),
        ),
        episode: 5,
      );
      expect((decision as SyncMutation).customLists, ['Rewatch Club']);
    });
  });
}
