// ignore_for_file: prefer_initializing_formals

/// [TrackingRepository] implementation — AniList primary, optional MAL
/// mirror — wiring together the client, auth, sync rules and the offline
/// mutation queues.
library;

import '../../domain/models/media.dart';
import '../../domain/models/tracking_account.dart';
import '../../domain/ports/ports.dart';
import '../../domain/ports/http_transport.dart';
import 'anilist_client.dart';
import 'auth.dart';
import 'mal_client.dart';
import 'mutation_queue.dart';
import 'sync_rules.dart';

class TrackingRepositoryImpl implements TrackingRepository {
  TrackingRepositoryImpl({
    required AnilistClient anilist,
    MalClient? mal,
    required TrackingAuthStore auth,
    MutationQueue? anilistQueue,
    MutationQueue? malQueue,
    Clock clock = const SystemClock(),
    bool Function()? offline,
  }) : _anilist = anilist,
       _mal = mal,
       _auth = auth,
       _anilistQueue =
           anilistQueue ??
           MutationQueue(provider: TrackingProvider.aniList, clock: clock),
       _malQueue =
           malQueue ??
           MutationQueue(provider: TrackingProvider.myAnimeList, clock: clock),
       _clock = clock,
       _offline = offline;

  final AnilistClient _anilist;
  final MalClient? _mal;
  final TrackingAuthStore _auth;
  final MutationQueue _anilistQueue;
  final MutationQueue _malQueue;
  final Clock _clock;
  final bool Function()? _offline;

  bool get _isOffline => _offline?.call() ?? false;

  @override
  Future<List<TrackingAccount>> accounts() async {
    final now = _clock.now();
    final aniList = await _auth.readAniList();
    final myAnimeList = await _auth.readMal();
    return [
      if (aniList != null)
        TrackingAccount(
          service: TrackingAccountService.aniList,
          displayName: aniList.viewerName ?? 'AniList account',
          avatarUrl: aniList.viewerAvatar,
          health: switch (aniList.health(now)) {
            TokenHealth.valid => TrackingAccountHealth.connected,
            TokenHealth.expiring => TrackingAccountHealth.attention,
            TokenHealth.expired => TrackingAccountHealth.expired,
          },
        ),
      if (myAnimeList != null)
        TrackingAccount(
          service: TrackingAccountService.myAnimeList,
          displayName: myAnimeList.viewerName ?? 'MyAnimeList account',
          avatarUrl: myAnimeList.viewerPicture,
          health: myAnimeList.reauth || myAnimeList.needsRefresh(now)
              ? TrackingAccountHealth.attention
              : TrackingAccountHealth.connected,
        ),
    ];
  }

  /// Latest decision [updateProgress] arrived at — observable seam for the
  /// UI (toasts) and tests; updateProgress itself returns void per the port.
  SyncDecision? lastDecision;

  Future<String?> _aniToken() async {
    final token = await _auth.readAniList();
    if (token == null || !token.usable(_clock.now())) return null;
    return token.token;
  }

  @override
  Future<Media?> mediaById(int id) => _anilist.mediaById(id);

  @override
  Future<List<Media>> search(String query, {int page = 1}) async {
    final result = await _anilist.search(
      AnilistSearchFilter(search: query, page: page),
    );
    return result.media;
  }

  @override
  Future<List<Media>> userList(ListStatus status) async {
    final aniToken = await _auth.readAniList();
    if (aniToken != null && aniToken.viewerId != null) {
      final lists = await _anilist.userLists(
        userId: aniToken.viewerId!,
        token: aniToken.usable(_clock.now()) ? aniToken.token : null,
      );
      final media = [
        for (final list in lists)
          if (list.status == status) ...list.entries,
      ];
      await _flushAfterListSettled(_anilistQueue, lists: lists);
      return media;
    }

    // MAL-only account: the MAL list gives idMal + entry state; AniList's
    // public search maps those onto domain media (the old
    // getPaginatedMediaList flow).
    final malToken = await _auth.readMal();
    final mal = _mal;
    if (malToken == null || mal == null) return const [];
    final items = await mal.userList(token: malToken.token);
    final matching = [
      for (final item in items)
        if (item.status == status) item,
    ];
    await _flushAfterListSettled(_malQueue, malItems: items);
    if (matching.isEmpty) return const [];
    final byMalId = {for (final item in matching) item.idMal: item};
    final page = await _anilist.searchIds(
      idsMal: byMalId.keys.toList(),
      perPage: byMalId.length,
    );
    return [
      for (final media in page.media)
        if (media.idMal != null && byMalId.containsKey(media.idMal))
          _withMalEntry(media, byMalId[media.idMal]!),
    ];
  }

  /// The domain Media is immutable and has no copyWith; rebuild it with the
  /// MAL-derived list entry attached (old cache.js `fillEntries`).
  Media _withMalEntry(Media media, MalListItem item) {
    final status = item.status;
    if (status == null) return media;
    return Media(
      id: media.id,
      idMal: media.idMal,
      title: media.title,
      format: media.format,
      status: media.status,
      season: media.season,
      seasonYear: media.seasonYear,
      episodes: media.episodes,
      duration: media.duration,
      coverImage: media.coverImage,
      bannerImage: media.bannerImage,
      coverColor: media.coverColor,
      description: media.description,
      genres: media.genres,
      averageScore: media.averageScore,
      isAdult: media.isAdult,
      nextAiringEpisode: media.nextAiringEpisode,
      listEntry: ListEntry(
        status: status,
        progress: item.progress,
        score: item.score,
        repeat: item.repeat,
      ),
      synonyms: media.synonyms,
    );
  }

  @override
  Future<void> updateProgress(Media media, int episode) async {
    final aniToken = await _auth.readAniList();
    final malToken = await _auth.readMal();
    if (aniToken == null && malToken == null) return;

    final primary = aniToken != null
        ? TrackingProvider.aniList
        : TrackingProvider.myAnimeList;
    final state = SyncMediaState(
      id: media.id,
      idMal: media.idMal,
      status: media.status,
      format: media.format,
      episodes: media.episodes,
      maxEpisode: media.maxEpisode,
      // The domain model carries no streamingEpisodes/mappings, so the
      // zero-episode offset cannot be derived here (domain gap, see report).
      zeroEpisode: false,
      listEntry: media.listEntry == null
          ? null
          : SyncListState.fromDomain(media.listEntry!),
    );

    final decision = decideEntryUpdate(
      media: state,
      episode: episode,
      provider: primary,
      now: _clock.now(),
    );
    lastDecision = decision;
    if (decision is! SyncMutation) return;

    if (primary == TrackingProvider.aniList) {
      await _sendAniList(decision, media);
      // Mirror the same write to MAL when a MAL account is linked.
      if (malToken != null && _mal != null && media.idMal != null) {
        final malDecision = decideEntryUpdate(
          media: state,
          episode: episode,
          provider: TrackingProvider.myAnimeList,
          now: _clock.now(),
        );
        if (malDecision is SyncMutation) {
          await _sendMal(malDecision, malToken.token);
        }
      }
    } else {
      if (media.idMal == null) return;
      await _sendMal(decision, malToken!.token);
    }
  }

  Map<String, dynamic> _aniVariables(SyncMutation mutation) => {
    'id': mutation.mediaId,
    'status': anilistListStatusName(mutation.status),
    'episode': mutation.progress,
    'repeat': mutation.repeat,
    'score': mutation.score,
    if (mutation.startedAt != null) 'startedAt': mutation.startedAt!.toJson(),
    if (mutation.completedAt != null)
      'completedAt': mutation.completedAt!.toJson(),
  };

  Future<void> _sendAniList(SyncMutation mutation, Media media) async {
    final variables = _aniVariables(mutation);
    final progressBefore =
        _anilistQueue.progressBeforeOf(mutation.mediaId) ??
        media.listEntry?.progress;
    if (_isOffline) {
      _anilistQueue.enqueue(
        MutationType.entry,
        mutation.mediaId,
        variables,
        progressBefore: progressBefore,
        executed: false,
      );
      return;
    }
    try {
      final saved = await _anilist.saveMediaListEntry(
        mediaId: mutation.mediaId,
        status: mutation.status,
        progress: mutation.progress,
        repeat: mutation.repeat,
        score: mutation.score,
        startedAt: mutation.startedAt?.toJson(),
        completedAt: mutation.completedAt?.toJson(),
        token: await _aniToken(),
      );
      _anilistQueue.enqueue(
        MutationType.entry,
        mutation.mediaId,
        variables,
        result: saved == null
            ? null
            : {
                'progress': saved.progress,
                'status': saved.status == null
                    ? null
                    : anilistListStatusName(saved.status!),
              },
        progressBefore: progressBefore,
      );
    } on TransportException {
      _anilistQueue.enqueue(
        MutationType.entry,
        mutation.mediaId,
        variables,
        progressBefore: progressBefore,
        executed: false,
      );
    }
  }

  Map<String, dynamic> _malVariables(SyncMutation mutation) => {
    'idMal': mutation.idMal,
    'status': anilistListStatusName(mutation.status),
    'episode': mutation.progress,
    'repeat': mutation.repeat,
    'score': mutation.score,
    if (mutation.startedAt != null) 'startedAt': mutation.startedAt!.toJson(),
    if (mutation.completedAt != null)
      'completedAt': mutation.completedAt!.toJson(),
  };

  Future<void> _sendMal(SyncMutation mutation, String token) async {
    final mal = _mal;
    final idMal = mutation.idMal;
    if (mal == null || idMal == null) return;
    final variables = _malVariables(mutation);
    if (_isOffline) {
      _malQueue.enqueue(
        MutationType.entry,
        idMal,
        variables,
        progressBefore: _malQueue.progressBeforeOf(idMal) ?? mutation.progress,
        executed: false,
      );
      return;
    }
    try {
      await mal.setListStatus(
        idMal: idMal,
        status: mutation.status,
        progress: mutation.progress,
        repeat: mutation.repeat,
        score: mutation.score,
        startedAt: mutation.startedAt,
        completedAt: mutation.completedAt,
        token: token,
      );
    } on TransportException {
      _malQueue.enqueue(
        MutationType.entry,
        idMal,
        variables,
        progressBefore: _malQueue.progressBeforeOf(idMal) ?? mutation.progress,
        executed: false,
      );
    }
  }

  /// Reconnect signal: refresh nothing here, just push what's queued (the
  /// old app resubscribed to the online status store and flushed).
  Future<void> onReconnect() async {
    if (_anilistQueue.hasPending) await _flushAniListQueue(null);
    if (_malQueue.hasPending) await _flushMalQueue(null);
  }

  Future<void> _flushAfterListSettled(
    MutationQueue queue, {
    List<AnilistList>? lists,
    List<MalListItem>? malItems,
  }) async {
    if (!queue.hasPending) return;
    if (identical(queue, _anilistQueue)) {
      await _flushAniListQueue(lists);
    } else {
      await _flushMalQueue(malItems);
    }
  }

  Future<void> _flushAniListQueue(List<AnilistList>? lists) {
    int? freshProgress(int mediaId) {
      for (final list in lists ?? const <AnilistList>[]) {
        for (final media in list.entries) {
          if (media.id == mediaId) return media.listEntry?.progress;
        }
      }
      return null;
    }

    return _anilistQueue.flush(
      freshProgressOf: lists == null ? null : freshProgress,
      apply: (_) async {},
      execute: (mutation) async {
        final vars = mutation.variables;
        final token = vars['token'] as String? ?? await _aniToken();
        switch (mutation.type) {
          case MutationType.entry:
            await _anilist.saveMediaListEntry(
              mediaId: mutation.mediaId,
              status:
                  listStatusFromAnilist(vars['status'] as String?) ??
                  ListStatus.current,
              progress: (vars['episode'] as num?)?.toInt() ?? 0,
              repeat: (vars['repeat'] as num?)?.toInt() ?? 0,
              score: (vars['score'] as num?)?.toInt() ?? 0,
              startedAt: (vars['startedAt'] as Map?)?.cast<String, dynamic>(),
              completedAt: (vars['completedAt'] as Map?)
                  ?.cast<String, dynamic>(),
              token: token,
            );
          case MutationType.delete:
            final entryId = (vars['entryId'] as num?)?.toInt();
            if (entryId != null) {
              await _anilist.deleteMediaListEntry(entryId, token: token);
            }
          case MutationType.favourite:
            await _anilist.toggleFavourite(mutation.mediaId, token: token);
        }
      },
    );
  }

  Future<void> _flushMalQueue(List<MalListItem>? items) {
    int? freshProgress(int idMal) {
      for (final item in items ?? const <MalListItem>[]) {
        if (item.idMal == idMal) return item.progress;
      }
      return null;
    }

    return _malQueue.flush(
      freshProgressOf: items == null ? null : freshProgress,
      apply: (_) async {},
      execute: (mutation) async {
        final mal = _mal;
        if (mal == null) return;
        final vars = mutation.variables;
        final token =
            vars['token'] as String? ?? (await _auth.readMal())?.token;
        switch (mutation.type) {
          case MutationType.entry:
            FuzzyDate? date(String key) {
              final raw = (vars[key] as Map?)?.cast<String, dynamic>();
              if (raw == null) return null;
              return FuzzyDate(
                year: (raw['year'] as num?)?.toInt(),
                month: (raw['month'] as num?)?.toInt(),
                day: (raw['day'] as num?)?.toInt(),
              );
            }

            await mal.setListStatus(
              idMal: mutation.mediaId,
              status:
                  listStatusFromAnilist(vars['status'] as String?) ??
                  ListStatus.current,
              progress: (vars['episode'] as num?)?.toInt() ?? 0,
              repeat: (vars['repeat'] as num?)?.toInt() ?? 0,
              score: (vars['score'] as num?)?.toInt() ?? 0,
              startedAt: date('startedAt'),
              completedAt: date('completedAt'),
              token: token,
            );
          case MutationType.delete:
            await mal.deleteListStatus(mutation.mediaId, token: token);
          case MutationType.favourite:
            break; // MAL has no favourite mutation in the old app.
        }
      },
    );
  }
}
