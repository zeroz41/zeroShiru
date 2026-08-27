import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/theme.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/hover_region.dart';
import '../../application/learning/providers.dart';
import '../../application/learning/subtitle_providers.dart';
import '../../application/logging/providers.dart';
import '../../application/playback/backend.dart';
import '../../application/playback/probe.dart';
import '../../application/playback/preferences.dart';
import '../../application/playback/providers.dart';
import '../../application/playback/request.dart';
import '../../application/settings/providers.dart';
import '../../application/sources/best_source_search.dart';
import '../../application/sources/providers.dart';
import '../../domain/models/torrent.dart';
import '../../domain/models/media.dart';
import '../../domain/models/settings.dart';
import '../../domain/ports/debrid_client.dart';
import '../../domain/ports/language_learning.dart';
import '../../domain/ports/learning_subtitles.dart';
import '../../domain/ports/media_engine.dart';

const _idleSnapshot = PlaybackSnapshot(
  generation: 0,
  phase: PlaybackPhase.idle,
);
const _playbackResolveTimeout = Duration(seconds: 65);

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, this.initialSource, this.initialLaunch});

  final PlayerFile? initialSource;
  final PlaybackLaunch? initialLaunch;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final PlaybackBackend _backend;
  late final Widget _surface;
  late final StreamSubscription<SubtitleCue> _primaryCueSubscription;
  late final StreamSubscription<SubtitleCue> _secondaryCueSubscription;
  PlaybackSnapshot _latest = _idleSnapshot;
  SubtitleCue? _primaryCue;
  SubtitleCue? _secondaryCue;
  PlayerFile? _source;
  PlaybackLaunch? _launch;
  Object? _resolveError;
  String? _resolveStatus;
  bool _resolving = false;
  int _resolveGeneration = 0;
  Future<_LearningSubtitleLoadResult>? _learningSubtitleRequest;
  Future<_LearningSubtitleLoadResult>? _learningPreparationRequest;
  String? _learningPreparationIdentity;
  String? _learningPreparationCompletedIdentity;
  _LearningSubtitleLoadResult? _learningPreparationResult;
  bool _learningPreparationPending = false;
  String? _learningAutoAttempt;
  String? _pickedPrimarySubtitle;
  String? _pickedSecondarySubtitle;
  String? _standardPrimarySubtitle;
  SubtitleRendering _requestedSubtitleRendering = SubtitleRendering.standard;
  bool _playerPreferencesLoaded = false;
  String? _playbackTuningIdentity;
  PlaybackTuning _playbackTuning = const PlaybackTuning();
  double? _appliedSubtitleScale;
  double? _pendingSubtitleScale;
  int _activePlaybackGeneration = 0;
  BoxFit _fit = BoxFit.contain;
  double _lastAudibleVolume = 1;
  bool _exitHandled = false;
  int? _retryBestEpisode;

  MediaEngine get _engine => _backend.engine;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
    _launch = widget.initialLaunch;
    _backend = ref.read(playbackBackendProvider);
    _surface = _backend.buildSurface(
      key: const ValueKey('playback-surface'),
      fit: _fit,
    );
    _primaryCueSubscription = _engine.primaryCues.listen((cue) {
      if (mounted) setState(() => _primaryCue = cue);
    });
    _secondaryCueSubscription = _engine.secondaryCues.listen((cue) {
      if (mounted) setState(() => _secondaryCue = cue);
    });
    if (widget.initialLaunch != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_resolveLaunch(widget.initialLaunch!));
      });
    } else if (widget.initialSource != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_open(widget.initialSource!));
      });
    }
  }

  @override
  void didUpdateWidget(PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialLaunch != null &&
        (oldWidget.initialLaunch?.magnet != widget.initialLaunch!.magnet ||
            oldWidget.initialLaunch?.episode != widget.initialLaunch!.episode ||
            oldWidget.initialLaunch?.releaseEpisode !=
                widget.initialLaunch!.releaseEpisode)) {
      unawaited(_resolveLaunch(widget.initialLaunch!));
    } else if (widget.initialSource != null &&
        oldWidget.initialSource?.url != widget.initialSource!.url) {
      _source = widget.initialSource;
      _clearPickedTracks();
      unawaited(_open(widget.initialSource!));
    }
  }

  Future<void> _resolveLaunch(PlaybackLaunch launch) async {
    final generation = ++_resolveGeneration;
    final started = Stopwatch()..start();
    _learningSubtitleRequest = null;
    _learningPreparationRequest = null;
    _learningPreparationIdentity = null;
    _learningPreparationCompletedIdentity = null;
    _learningPreparationResult = null;
    _learningPreparationPending = false;
    _learningAutoAttempt = null;
    _clearPickedTracks();
    _activePlaybackGeneration = 0;
    setState(() {
      _launch = launch;
      _resolving = true;
      _resolveError = null;
      _resolveStatus = 'Connecting to ${_serviceTitle(launch.service)}…';
      _source = null;
    });
    ref
        .read(appLogProvider)
        .log(
          'info',
          'playback-resolve',
          '${launch.service.name} resolve started for media ${launch.media.id} '
              'episode ${launch.episode}',
        );
    try {
      final settings = await ref.read(settingsControllerProvider.future);
      final key = settings.debridApiKeys[launch.service];
      if (key == null || key.isEmpty) {
        throw DebridException(
          DebridErrorKind.auth,
          '${_serviceTitle(launch.service)} is not connected. Add its API key in Settings.',
        );
      }
      final client = ref.read(debridClientsProvider)[launch.service];
      if (client == null) {
        throw DebridException(
          DebridErrorKind.service,
          '${_serviceTitle(launch.service)} is unavailable in this build.',
        );
      }
      final releases = launch.releases.toList(growable: false);
      PlayerFile? source;
      ResolvedDebrid? resolved;
      PlaybackRelease? selectedRelease;
      var selectedIndex = 0;
      DebridException? lastReleaseError;
      for (var index = 0; index < releases.length; index++) {
        final release = releases[index];
        if (!mounted || generation != _resolveGeneration) return;
        setState(() {
          _resolveStatus = releases.length == 1
              ? 'Resolving episode ${launch.episode} with ${_serviceTitle(launch.service)}…'
              : 'Resolving best source ${index + 1} of ${releases.length} for episode ${launch.episode}…';
        });
        requestPlayback(episode: launch.episode, mediaId: launch.media.id);
        try {
          final candidate = await client
              .resolve(
                key,
                release.magnet,
                episode: release.releaseEpisode ?? launch.episode,
              )
              .timeout(
                _playbackResolveTimeout,
                onTimeout: () => throw DebridException(
                  DebridErrorKind.timeout,
                  '${_serviceTitle(launch.service)} did not prepare the release '
                  'within ${_playbackResolveTimeout.inSeconds}s.',
                ),
              );
          final candidateSource = _pickResolvedTarget(
            candidate,
            launch.episode,
          );
          final probeTransport = ref.read(playbackProbeTransportProvider);
          if (probeTransport != null) {
            if (mounted && generation == _resolveGeneration) {
              setState(() {
                _resolveStatus = 'Checking stream health before opening MPV…';
              });
            }
            final verdict = await verifiedStream(
              candidateSource.url,
              transport: probeTransport,
            );
            if (!verdict.alive) {
              await client.forgetResolved(key, candidate.hash);
              throw DebridException(
                DebridErrorKind.unavailable,
                'The selected ${_serviceTitle(launch.service)} stream did not deliver media bytes.',
              );
            }
          }
          source = candidateSource;
          resolved = candidate;
          selectedRelease = release;
          selectedIndex = index;
          break;
        } on DebridException catch (error) {
          lastReleaseError = error;
          final hasFallback = index + 1 < releases.length;
          if (!hasFallback || !_canTryAnotherRelease(error)) rethrow;
          ref
              .read(appLogProvider)
              .log(
                'warn',
                'playback-resolve',
                'Best source ${index + 1} rejected for episode '
                    '${launch.episode} (${error.kind.name}); trying the next.',
              );
        }
      }
      if (source == null || resolved == null || selectedRelease == null) {
        throw lastReleaseError ??
            const DebridException(
              DebridErrorKind.unavailable,
              'No selected release could be prepared for playback.',
            );
      }
      if (!mounted || generation != _resolveGeneration) return;
      final activeLaunch = PlaybackLaunch(
        media: launch.media,
        episode: launch.episode,
        magnet: selectedRelease.magnet,
        service: launch.service,
        releaseEpisode: selectedRelease.releaseEpisode,
        alternatives: releases.skip(selectedIndex + 1).toList(growable: false),
      );
      setState(() {
        _launch = activeLaunch;
        _source = source;
        _resolving = false;
        _resolveStatus =
            'Opening secure ${_serviceTitle(launch.service)} stream…';
        _retryBestEpisode = null;
      });
      ref
          .read(appLogProvider)
          .log(
            'info',
            'playback-resolve',
            '${launch.service.name} prepared ${resolved.files.length} file(s) in '
                '${started.elapsedMilliseconds}ms',
          );
      await _open(source);
    } on DebridException catch (error) {
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _resolving = false;
        _resolveStatus = null;
        _resolveError = error;
      });
      ref
          .read(appLogProvider)
          .log(
            'warn',
            'playback-resolve',
            '${launch.service.name} failed after ${started.elapsedMilliseconds}ms: '
                '${error.kind.name}: ${error.message}',
          );
    } catch (error) {
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _resolving = false;
        _resolveStatus = null;
        _resolveError = const DebridException(
          DebridErrorKind.service,
          'The release could not be prepared for playback.',
        );
      });
      ref
          .read(appLogProvider)
          .log(
            'error',
            'playback-resolve',
            '${launch.service.name} failed after ${started.elapsedMilliseconds}ms: '
                '$error',
          );
    }
  }

  Future<void> _retry() async {
    if (_retryBestEpisode case final episode?) {
      await _resolveBestEpisode(episode, pauseFirst: false);
      return;
    }
    final launch = _launch;
    if (launch == null) {
      final source = _source;
      if (source != null) await _open(source);
      return;
    }
    final source = _source;
    if (source?.infoHash case final hash?) {
      try {
        final settings = await ref.read(settingsControllerProvider.future);
        final key = settings.debridApiKeys[launch.service];
        final client = ref.read(debridClientsProvider)[launch.service];
        if (key != null && key.isNotEmpty && client != null) {
          await client.forgetResolved(key, hash);
        }
      } catch (_) {
        // A failed cache invalidation must not disable the visible retry.
      }
    }
    if (mounted) await _resolveLaunch(launch);
  }

  Future<void> _open(PlayerFile source) async {
    _activePlaybackGeneration = 0;
    final settings = await ref.read(settingsControllerProvider.future);
    final tuningIdentity = playbackTuningIdentity(source);
    _playbackTuningIdentity = tuningIdentity;
    _playbackTuning = tuningIdentity == null
        ? const PlaybackTuning()
        : ref.read(playbackTuningStoreProvider).read(tuningIdentity);
    if (!_playerPreferencesLoaded) {
      _requestedSubtitleRendering = _subtitleRenderingFromSetting(
        settings.playerSubtitleMode,
      );
      _playerPreferencesLoaded = true;
    }
    final opened = _engine.state
        .firstWhere(
          (snapshot) =>
              snapshot.phase == PlaybackPhase.ready ||
              snapshot.phase == PlaybackPhase.failed,
        )
        .timeout(const Duration(seconds: 30));
    try {
      await _engine.open(
        source,
        preferences: playbackPreferencesFor(
          settings,
          subtitleMode: _requestedSubtitleRendering.name,
        ),
      );
      final ready = await opened;
      _activePlaybackGeneration = ready.generation;
      if (ready.subtitleRendering != _requestedSubtitleRendering) {
        await _engine.setSubtitleRendering(_requestedSubtitleRendering);
      }
      if (_playbackTuning.primarySubtitleDelay != Duration.zero) {
        await _engine.setSubtitleDelay(_playbackTuning.primarySubtitleDelay);
      }
      if (_playbackTuning.secondarySubtitleDelay != Duration.zero) {
        await _engine.setSubtitleDelay(
          _playbackTuning.secondarySubtitleDelay,
          secondary: true,
        );
      }
      try {
        await _engine.setSubtitleScale(settings.subtitleTextScale);
        _appliedSubtitleScale = settings.subtitleTextScale;
        if (_pendingSubtitleScale == settings.subtitleTextScale) {
          _pendingSubtitleScale = null;
        }
      } on PlaybackFailure {
        // A reduced backend can still play even when it cannot resize text.
      }
      if (mounted) await _engine.play();
    } on PlaybackFailure {
      // The redacted failure is already represented in the state stream.
    }
  }

  void _clearPickedTracks() {
    _pickedPrimarySubtitle = null;
    _pickedSecondarySubtitle = null;
    _standardPrimarySubtitle = null;
  }

  Future<_LearningSubtitleLoadResult> _findJapaneseLearningSubtitle() {
    final running = _learningSubtitleRequest;
    if (running != null) return running;
    final request = () async {
      try {
        return await _performJapaneseLearningSubtitleLookup();
      } catch (_) {
        return const _LearningSubtitleLoadResult.unavailable(
          'The Japanese subtitle could not be prepared. Try again or add a local sidecar.',
        );
      }
    }();
    _learningSubtitleRequest = request;
    unawaited(
      request.then((result) {
        if (result.ready || _learningSubtitleRequest != request) return;
        _learningSubtitleRequest = null;
      }),
    );
    return request;
  }

  Future<_LearningSubtitleLoadResult> _prepareLearningTracks() {
    final snapshot = _latest;
    final launch = _launch;
    if (_requestedSubtitleRendering != SubtitleRendering.learning ||
        snapshot.phase == PlaybackPhase.idle ||
        snapshot.phase == PlaybackPhase.opening ||
        snapshot.phase == PlaybackPhase.failed) {
      return Future.value(
        const _LearningSubtitleLoadResult.unavailable(
          'The player is not ready to prepare Learning subtitles yet.',
        ),
      );
    }
    final identity =
        '${snapshot.generation}:${launch?.media.id ?? 'source'}:'
        '${launch?.episode ?? 0}';
    final running = _learningPreparationRequest;
    if (running != null && _learningPreparationIdentity == identity) {
      return running;
    }
    final completed = _learningPreparationResult;
    if (_learningPreparationCompletedIdentity == identity &&
        completed?.ready == true) {
      return Future.value(completed);
    }

    final request = () async {
      try {
        final settings = await ref.read(settingsControllerProvider.future);
        return await _performLearningTrackPreparation(snapshot, settings);
      } catch (_) {
        return const _LearningSubtitleLoadResult.unavailable(
          'The Learning tracks could not be prepared. Try again or choose them manually.',
        );
      }
    }();
    _learningPreparationIdentity = identity;
    _learningPreparationRequest = request;
    if (mounted) {
      setState(() {
        _learningPreparationPending = true;
        _learningPreparationResult = null;
      });
    }
    unawaited(_recordLearningPreparation(request));
    return request;
  }

  Future<void> _recordLearningPreparation(
    Future<_LearningSubtitleLoadResult> request,
  ) async {
    final result = await request;
    if (!mounted ||
        _learningPreparationRequest != request ||
        _requestedSubtitleRendering != SubtitleRendering.learning) {
      return;
    }
    setState(() {
      _learningPreparationPending = false;
      _learningPreparationResult = result;
      _learningPreparationCompletedIdentity = result.ready
          ? _learningPreparationIdentity
          : null;
      _learningPreparationRequest = null;
      _learningPreparationIdentity = null;
    });
  }

  Future<_LearningSubtitleLoadResult> _performLearningTrackPreparation(
    PlaybackSnapshot snapshot,
    Settings settings,
  ) async {
    final warnings = <String>[];
    final selectedTrackIds = {
      snapshot.selectedPrimarySubtitle,
      snapshot.selectedSecondarySubtitle,
    }..remove(null);
    final pickedTrackIds = {_pickedPrimarySubtitle, _pickedSecondarySubtitle}
      ..remove(null);
    final textTracks = snapshot.subtitleTracks
        .where((track) => !track.isBitmapSubtitle)
        .toList();
    final japanese = _preferredLearningTrack(
      textTracks,
      'ja',
      selectedIds: selectedTrackIds,
      preferredIds: pickedTrackIds,
      subtitle: true,
    );
    final translationLanguage = _languageBase(
      settings.learningTranslationLanguage,
    );
    final translation = settings.learningShowTranslation
        ? _preferredLearningTrack(
            textTracks.where((track) => track.id != japanese?.id),
            translationLanguage,
            selectedIds: selectedTrackIds,
            preferredIds: pickedTrackIds,
            subtitle: true,
          )
        : null;

    try {
      if (!_learningRequestIsCurrent(snapshot)) {
        return const _LearningSubtitleLoadResult.unavailable(
          'Playback changed before the Learning tracks were ready.',
        );
      }

      if (japanese != null) {
        await _engine.selectSubtitle(japanese.id);
        await _engine.selectSubtitle(translation?.id, secondary: true);
        if (translation == null && settings.learningShowTranslation) {
          warnings.add(
            'No matching ${_languageTitle(translationLanguage)} text track was found, so translation is hidden for this release.',
          );
        }
        return _LearningSubtitleLoadResult.ready(
          ['Japanese text is ready.', ...warnings].join(' '),
        );
      }

      if (!settings.learningAutoFetchJapaneseSubtitles) {
        return _LearningSubtitleLoadResult.unavailable(
          [
            ...warnings,
            'No Japanese text track is embedded. Automatic fetching is disabled; add a local ASS, SRT, or VTT sidecar.',
          ].join(' '),
        );
      }
      await _engine.selectSubtitle(translation?.id, secondary: true);
      if (translation == null && settings.learningShowTranslation) {
        warnings.add(
          'No matching ${_languageTitle(translationLanguage)} text track was found, so translation is hidden for this release.',
        );
      }
      final fetched = await _findJapaneseLearningSubtitle();
      // Loading an external primary subtitle may rebuild MPV's track list.
      // Re-assert the requested translation afterwards so a shifted native
      // secondary selection can never silently become another language.
      if (fetched.ready && _learningRequestIsCurrent(snapshot)) {
        await _engine.selectSubtitle(translation?.id, secondary: true);
      }
      return fetched.copyWithMessage([...warnings, fetched.message].join(' '));
    } on PlaybackFailure catch (failure) {
      return _LearningSubtitleLoadResult.unavailable(failure.message);
    } catch (_) {
      return const _LearningSubtitleLoadResult.unavailable(
        'The Learning tracks could not be prepared. Try again or choose them manually.',
      );
    }
  }

  bool _learningRequestIsCurrent(PlaybackSnapshot snapshot) =>
      mounted &&
      _requestedSubtitleRendering == SubtitleRendering.learning &&
      _latest.generation == snapshot.generation &&
      _latest.phase != PlaybackPhase.failed;

  Future<_LearningSubtitleLoadResult>
  _performJapaneseLearningSubtitleLookup() async {
    final launch = _launch;
    final resolveGeneration = _resolveGeneration;
    if (launch == null) {
      return const _LearningSubtitleLoadResult.unavailable(
        'Automatic matching needs an episode opened from its show page. You can still add a local sidecar.',
      );
    }
    final settings = await ref.read(settingsControllerProvider.future);
    if (!settings.learningAutoFetchJapaneseSubtitles) {
      return const _LearningSubtitleLoadResult.unavailable(
        'Automatic Japanese subtitle fetching is disabled in Learning settings.',
      );
    }
    final repository = ref.read(learningSubtitleRepositoryProvider);
    if (repository == null) {
      return const _LearningSubtitleLoadResult.unavailable(
        'Automatic Japanese subtitles are unavailable in this build.',
      );
    }
    final credential = await ref.read(jimakuConnectionProvider.future);

    try {
      final match = await repository.findJapanese(
        LearningSubtitleQuery(
          anilistId: launch.media.id,
          episode: launch.episode,
          releaseName: _learningReleaseIdentity(
            _source,
            fallback: launch.media.title.display,
          ),
          movie: launch.media.format == MediaFormat.movie,
        ),
        credential: credential ?? '',
      );
      if (match == null) {
        return const _LearningSubtitleLoadResult.unavailable(
          'No non-OCR Japanese text subtitle was found for this episode. A local sidecar can still be added.',
        );
      }

      if (!mounted ||
          resolveGeneration != _resolveGeneration ||
          _launch?.media.id != launch.media.id ||
          _launch?.episode != launch.episode) {
        return const _LearningSubtitleLoadResult.unavailable(
          'Japanese text was cached for the previous episode.',
        );
      }
      if (_requestedSubtitleRendering != SubtitleRendering.learning) {
        return const _LearningSubtitleLoadResult.unavailable(
          'Japanese text was cached. Select Learning again when you want to attach it.',
        );
      }

      final primaryTrackId = await _engine.addSubtitle(
        match.source,
        title: match.title,
        language: 'ja',
      );
      _pickedPrimarySubtitle = primaryTrackId;
      return _LearningSubtitleLoadResult.ready(
        'Japanese text attached from ${match.provider} and cached for this episode. Source: ${match.originalName}.',
        primaryTrackId: primaryTrackId,
      );
    } on LearningSubtitleFailure catch (failure) {
      return _LearningSubtitleLoadResult.unavailable(failure.message);
    } on PlaybackFailure catch (failure) {
      return _LearningSubtitleLoadResult.unavailable(failure.message);
    } catch (_) {
      return const _LearningSubtitleLoadResult.unavailable(
        'The Japanese subtitle could not be prepared. Try again or add a local sidecar.',
      );
    }
  }

  void _maybePrepareLearningTracks(
    PlaybackSnapshot snapshot,
    Settings settings,
  ) {
    if (snapshot.subtitleRendering != SubtitleRendering.learning ||
        !settings.learningAutoSelectTracks ||
        _launch == null ||
        snapshot.phase == PlaybackPhase.idle ||
        snapshot.phase == PlaybackPhase.opening ||
        snapshot.phase == PlaybackPhase.failed ||
        snapshot.generation != _activePlaybackGeneration) {
      return;
    }
    final identity =
        '${snapshot.generation}:${_launch!.media.id}:'
        '${_launch!.episode}';
    if (_learningAutoAttempt == identity) return;
    _learningAutoAttempt = identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _requestedSubtitleRendering != SubtitleRendering.learning) {
        return;
      }
      unawaited(_autoPrepareLearningTracks(snapshot));
    });
  }

  Future<void> _autoPrepareLearningTracks(PlaybackSnapshot snapshot) async {
    if (!_learningRequestIsCurrent(snapshot)) return;
    await _prepareLearningTracks();
  }

  Future<void> _setSubtitleRendering(SubtitleRendering mode) async {
    final previous = _requestedSubtitleRendering;
    _requestedSubtitleRendering = mode;
    if (mode == SubtitleRendering.learning &&
        previous != SubtitleRendering.learning) {
      _standardPrimarySubtitle = _latest.selectedPrimarySubtitle;
    }
    if (mode != SubtitleRendering.learning && mounted) {
      setState(() {
        _learningPreparationRequest = null;
        _learningPreparationIdentity = null;
        _learningPreparationCompletedIdentity = null;
        _learningAutoAttempt = null;
        _learningPreparationPending = false;
        _learningPreparationResult = null;
      });
    }
    if (mode != SubtitleRendering.learning) {
      await _engine.selectSubtitle(null, secondary: true);
    }
    if (mode == SubtitleRendering.standard) {
      final settings = await ref.read(settingsControllerProvider.future);
      final preferred = _preferredStandardSubtitle(
        _latest,
        settings.subtitleLanguage,
        previousTrackId: _standardPrimarySubtitle,
      );
      await _engine.selectSubtitle(preferred?.id);
      _standardPrimarySubtitle = preferred?.id;
    }
    await _engine.setSubtitleRendering(mode);
    await _persistSettings(
      (current) => current.copyWith(playerSubtitleMode: mode.name),
    );
  }

  Future<void> _selectAudioTrack(String? trackId) async {
    await _engine.selectAudio(trackId);
    final language = _settingLanguageForTrack(
      _latest.audioTracks,
      trackId,
      automatic: 'und',
    );
    if (language == null) return;
    await _persistSettings(
      (current) => current.copyWith(audioLanguage: language),
    );
  }

  Future<void> _selectPrimarySubtitle(String? trackId) async {
    _pickedPrimarySubtitle = trackId;
    await _engine.selectSubtitle(trackId);
    if (_requestedSubtitleRendering != SubtitleRendering.standard) return;
    final language = _settingLanguageForTrack(_latest.subtitleTracks, trackId);
    if (language == null) return;
    await _persistSettings(
      (current) => current.copyWith(subtitleLanguage: language),
    );
  }

  Future<void> _selectSecondarySubtitle(String? trackId) async {
    _pickedSecondarySubtitle = trackId;
    await _engine.selectSubtitle(trackId, secondary: true);
    if (_requestedSubtitleRendering != SubtitleRendering.learning) return;
    final language = _settingLanguageForTrack(_latest.subtitleTracks, trackId);
    await _persistSettings((current) {
      if (language == null || language == 'jpn') {
        return current.copyWith(learningShowTranslation: trackId != null);
      }
      return current.copyWith(
        learningTranslationLanguage: language,
        learningShowTranslation: true,
      );
    });
  }

  Future<void> _persistSettings(Settings Function(Settings) update) =>
      ref.read(settingsControllerProvider.notifier).persist(update);

  void _syncSubtitleScale(double scale) {
    if (_appliedSubtitleScale == scale || _pendingSubtitleScale == scale) {
      return;
    }
    _pendingSubtitleScale = scale;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingSubtitleScale != scale) return;
      unawaited(() async {
        try {
          await _engine.setSubtitleScale(scale);
          if (mounted) _appliedSubtitleScale = scale;
        } on PlaybackFailure {
          // Bitmap subtitles and a reduced platform backend may not expose a
          // live text scale. The persisted preference still applies when a
          // capable text renderer becomes active.
        } finally {
          if (_pendingSubtitleScale == scale) _pendingSubtitleScale = null;
        }
      }());
    });
  }

  Future<void> _setAndRememberSubtitleDelay(
    Duration delay, {
    bool secondary = false,
  }) async {
    await _engine.setSubtitleDelay(delay, secondary: secondary);
    _playbackTuning = secondary
        ? _playbackTuning.copyWith(secondarySubtitleDelay: delay)
        : _playbackTuning.copyWith(primarySubtitleDelay: delay);
    final identity = _playbackTuningIdentity;
    if (identity != null) {
      await ref
          .read(playbackTuningStoreProvider)
          .write(identity, _playbackTuning);
    }
  }

  void _run(Future<void> Function() command) {
    unawaited(() async {
      try {
        await command();
      } on PlaybackFailure catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error.message)));
      }
    }());
  }

  Future<void> _pauseForExit() async {
    if (_exitHandled) return;
    _exitHandled = true;
    if (_latest.phase == PlaybackPhase.playing ||
        _latest.phase == PlaybackPhase.buffering) {
      try {
        await _engine.pause();
      } on PlaybackFailure {
        // Leaving the player must not be blocked by a failed pause command.
      }
    }
  }

  Future<void> _leave() async {
    await _pauseForExit();
    if (!mounted) return;
    if (context.canPop()) {
      context.pop(_launch?.episode);
    } else {
      context.go('/home');
    }
  }

  Future<void> _switchEpisode(int direction) async {
    final launch = _launch;
    if (launch == null || _resolving) return;
    final target = launch.episode + direction;
    final maximum = launch.media.maxEpisode;
    if (target < 1 ||
        (direction > 0 && maximum == null) ||
        (maximum != null && target > maximum)) {
      return;
    }
    await _resolveBestEpisode(target);
  }

  Future<void> _resolveBestEpisode(
    int episode, {
    bool pauseFirst = true,
  }) async {
    final current = _launch;
    if (current == null || _resolving) return;
    if (pauseFirst) {
      try {
        await _engine.pause();
      } on PlaybackFailure {
        // The replacement source can still be prepared after a failed pause.
      }
    }
    if (!mounted) return;
    final generation = ++_resolveGeneration;
    _retryBestEpisode = episode;
    final pendingLaunch = PlaybackLaunch(
      media: current.media,
      episode: episode,
      magnet: current.magnet,
      service: current.service,
    );
    setState(() {
      _launch = pendingLaunch;
      _source = null;
      _resolving = true;
      _resolveError = null;
      _resolveStatus = 'Finding the best source for episode $episode…';
    });
    try {
      final settings = await ref.read(settingsControllerProvider.future);
      final key = settings.debridApiKeys[current.service];
      if (key == null || key.isEmpty) {
        throw DebridException(
          DebridErrorKind.auth,
          '${_serviceTitle(current.service)} is not connected. Add its API key in Settings.',
        );
      }
      final resolver = ref.read(sourceResolverProvider);
      if (resolver == null) {
        throw const DebridException(
          DebridErrorKind.service,
          'No source extension is enabled. Enable one in Settings and try again.',
        );
      }
      final client = ref.read(debridClientsProvider)[current.service];
      if (client == null) {
        throw DebridException(
          DebridErrorKind.service,
          '${_serviceTitle(current.service)} is unavailable in this build.',
        );
      }
      final best = await searchBestEpisodeSources(
        resolver: resolver,
        debrid: client,
        apiKey: key,
        media: current.media,
        episode: episode,
        preferences: settings,
      );
      if (!mounted || generation != _resolveGeneration) return;
      if (best.releases.isEmpty) {
        throw DebridException(
          DebridErrorKind.unavailable,
          best.sourceErrors.isEmpty
              ? 'No playable source was found for episode $episode.'
              : 'No playable source was found for episode $episode. Some source checks failed; try again.',
        );
      }
      final selected = best.releases.first;
      ref
          .read(appLogProvider)
          .log(
            best.timedOut ? 'warn' : 'info',
            'source-picker',
            'Player navigation found ${best.releases.length} ranked release(s) '
                'for media ${current.media.id} episode $episode.',
          );
      await _resolveLaunch(
        PlaybackLaunch(
          media: current.media,
          episode: episode,
          magnet: selected.magnet,
          service: current.service,
          releaseEpisode: selected.releaseEpisode,
          alternatives: best.releases.skip(1).toList(growable: false),
        ),
      );
    } on DebridException catch (error) {
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _resolving = false;
        _resolveStatus = null;
        _resolveError = error;
      });
    } catch (error) {
      if (!mounted || generation != _resolveGeneration) return;
      ref
          .read(appLogProvider)
          .log(
            'error',
            'source-picker',
            'Player episode $episode source search failed: $error',
          );
      setState(() {
        _resolving = false;
        _resolveStatus = null;
        _resolveError = const DebridException(
          DebridErrorKind.service,
          'The best source search failed. Try again.',
        );
      });
    }
  }

  Future<void> _togglePlayback() => switch (_latest.phase) {
    PlaybackPhase.playing || PlaybackPhase.buffering => _engine.pause(),
    _ => _engine.play(),
  };

  Future<void> _seekBy(Duration delta) =>
      _engine.seek(_latest.position + delta);

  Future<void> _toggleMute() async {
    if (_latest.volume > 0) {
      _lastAudibleVolume = _latest.volume;
      await _engine.setVolume(0);
    } else {
      await _engine.setVolume(_lastAudibleVolume);
    }
  }

  Future<void> _cycleSubtitles() async {
    final tracks = _latest.subtitleTracks;
    if (tracks.isEmpty) return _engine.selectSubtitle(null);
    final selected = _latest.selectedPrimarySubtitle;
    if (selected == null) return _engine.selectSubtitle(tracks.first.id);
    final index = tracks.indexWhere((track) => track.id == selected);
    if (index < 0 || index == tracks.length - 1) {
      return _engine.selectSubtitle(null);
    }
    return _engine.selectSubtitle(tracks[index + 1].id);
  }

  Future<void> _shiftSubtitleDelay(Duration delta) =>
      _setAndRememberSubtitleDelay(_latest.primarySubtitleDelay + delta);

  bool get _learningInteractionHasFocus {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorWidgetOfExactType<_LearningWord>() != null ||
        context.findAncestorWidgetOfExactType<_DefinitionPanel>() != null;
  }

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    final learningInteractionFocused = _learningInteractionHasFocus;
    final directionalNavigation =
        _latest.subtitleRendering == SubtitleRendering.learning &&
        (event.deviceType != ui.KeyEventDeviceType.keyboard ||
            MediaQuery.maybeNavigationModeOf(context) ==
                NavigationMode.directional);
    if (directional && (learningInteractionFocused || directionalNavigation)) {
      // Let Flutter's directional focus traversal own D-pad events, plus arrow
      // keys once a keyboard user has explicitly focused a learning token.
      return KeyEventResult.ignored;
    }
    if (learningInteractionFocused && key == LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space) {
      _run(_togglePlayback);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _run(() => _seekBy(const Duration(seconds: -2)));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _run(() => _seekBy(const Duration(seconds: 2)));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _run(() => _engine.setVolume((_latest.volume + 0.05).clamp(0, 3)));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _run(() => _engine.setVolume((_latest.volume - 0.05).clamp(0, 3)));
    } else if (key == LogicalKeyboardKey.keyM) {
      _run(_toggleMute);
    } else if (key == LogicalKeyboardKey.keyC) {
      _run(_cycleSubtitles);
    } else if (key == LogicalKeyboardKey.comma) {
      final step = HardwareKeyboard.instance.isShiftPressed
          ? const Duration(seconds: -1)
          : const Duration(milliseconds: -100);
      _run(() => _shiftSubtitleDelay(step));
    } else if (key == LogicalKeyboardKey.period) {
      final step = HardwareKeyboard.instance.isShiftPressed
          ? const Duration(seconds: 1)
          : const Duration(milliseconds: 100);
      _run(() => _shiftSubtitleDelay(step));
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      _run(() => _engine.setSpeed((_latest.speed - 0.1).clamp(0.1, 16)));
    } else if (key == LogicalKeyboardKey.bracketRight) {
      _run(() => _engine.setSpeed((_latest.speed + 0.1).clamp(0.1, 16)));
    } else if (key == LogicalKeyboardKey.backslash) {
      _run(() => _engine.setSpeed(1));
    } else if (key == LogicalKeyboardKey.keyW) {
      _toggleFit();
    } else if (key == LogicalKeyboardKey.keyP) {
      unawaited(_switchEpisode(-1));
    } else if (key == LogicalKeyboardKey.keyN) {
      unawaited(_switchEpisode(1));
    } else if (key == LogicalKeyboardKey.escape) {
      unawaited(_leave());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _toggleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain ? BoxFit.cover : BoxFit.contain;
    });
  }

  @override
  Widget build(BuildContext context) {
    final learningSettings =
        ref.watch(settingsControllerProvider).value ?? const Settings();
    return Theme(
      data: buildZeroTheme(context.zeroPalette.forPlayer),
      child: PopScope<Object?>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) unawaited(_pauseForExit());
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            autofocus: true,
            onKeyEvent: _onKeyEvent,
            child: StreamBuilder<PlaybackSnapshot>(
              stream: _engine.state,
              initialData: _idleSnapshot,
              builder: (context, state) {
                final snapshot = state.data ?? _idleSnapshot;
                _latest = snapshot;
                if (snapshot.phase != PlaybackPhase.idle &&
                    snapshot.phase != PlaybackPhase.opening) {
                  _syncSubtitleScale(learningSettings.subtitleTextScale);
                }
                _maybePrepareLearningTracks(snapshot, learningSettings);
                return _PlayerStage(
                  snapshot: snapshot,
                  snapshots: _engine.state,
                  learningSettings: learningSettings,
                  source: _source,
                  launch: _launch,
                  resolving: _resolving,
                  resolveStatus: _resolveStatus,
                  resolveError: _resolveError,
                  surface: _fit == BoxFit.contain
                      ? _surface
                      : _backend.buildSurface(
                          key: const ValueKey('playback-surface'),
                          fit: _fit,
                        ),
                  fit: _fit,
                  primaryCue: _primaryCue,
                  secondaryCue: _secondaryCue,
                  learningPreparationPending: _learningPreparationPending,
                  learningPreparationResult: _learningPreparationResult,
                  onBack: () => unawaited(_leave()),
                  onRetry: _source == null && _launch == null
                      ? null
                      : () => unawaited(_retry()),
                  onTogglePlayback: () => _run(_togglePlayback),
                  onPreviousEpisode: (_launch?.episode ?? 1) > 1
                      ? () => unawaited(_switchEpisode(-1))
                      : null,
                  onNextEpisode:
                      _launch != null &&
                          _launch!.media.maxEpisode != null &&
                          _launch!.episode < _launch!.media.maxEpisode!
                      ? () => unawaited(_switchEpisode(1))
                      : null,
                  onSeek: (position) => _run(() => _engine.seek(position)),
                  onVolume: (volume) => _run(() => _engine.setVolume(volume)),
                  onToggleMute: () => _run(_toggleMute),
                  onSpeed: (speed) => _run(() => _engine.setSpeed(speed)),
                  onAudio: (track) => _run(() => _selectAudioTrack(track)),
                  onSubtitle: (track) =>
                      _run(() => _selectPrimarySubtitle(track)),
                  onSecondarySubtitle: (track) =>
                      _run(() => _selectSecondarySubtitle(track)),
                  onSubtitleRendering: _setSubtitleRendering,
                  onPrepareLearningTracks: _prepareLearningTracks,
                  onLearningLookup: () {
                    if (snapshot.phase == PlaybackPhase.playing ||
                        snapshot.phase == PlaybackPhase.buffering) {
                      _run(_engine.pause);
                    }
                  },
                  onSubtitleDelay: (delay, secondary) => _run(
                    () => _setAndRememberSubtitleDelay(
                      delay,
                      secondary: secondary,
                    ),
                  ),
                  onAddSubtitle: (request) => _run(() async {
                    final trackId = await _engine.addSubtitle(
                      request.source,
                      title: request.title,
                      language: request.language,
                    );
                    _pickedPrimarySubtitle = trackId;
                  }),
                  onToggleFit: _toggleFit,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _resolveGeneration++;
    unawaited(_pauseForExit());
    unawaited(_primaryCueSubscription.cancel());
    unawaited(_secondaryCueSubscription.cancel());
    super.dispose();
  }
}

class _PlayerStage extends StatelessWidget {
  const _PlayerStage({
    required this.snapshot,
    required this.snapshots,
    required this.learningSettings,
    required this.source,
    required this.launch,
    required this.resolving,
    required this.resolveStatus,
    required this.resolveError,
    required this.surface,
    required this.fit,
    required this.primaryCue,
    required this.secondaryCue,
    required this.learningPreparationPending,
    required this.learningPreparationResult,
    required this.onBack,
    required this.onRetry,
    required this.onTogglePlayback,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onSpeed,
    required this.onAudio,
    required this.onSubtitle,
    required this.onSecondarySubtitle,
    required this.onSubtitleRendering,
    required this.onPrepareLearningTracks,
    required this.onLearningLookup,
    required this.onSubtitleDelay,
    required this.onAddSubtitle,
    required this.onToggleFit,
  });

  final PlaybackSnapshot snapshot;
  final Stream<PlaybackSnapshot> snapshots;
  final Settings learningSettings;
  final PlayerFile? source;
  final PlaybackLaunch? launch;
  final bool resolving;
  final String? resolveStatus;
  final Object? resolveError;
  final Widget surface;
  final BoxFit fit;
  final SubtitleCue? primaryCue;
  final SubtitleCue? secondaryCue;
  final bool learningPreparationPending;
  final _LearningSubtitleLoadResult? learningPreparationResult;
  final VoidCallback onBack;
  final VoidCallback? onRetry;
  final VoidCallback onTogglePlayback;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onSpeed;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onSubtitle;
  final ValueChanged<String?> onSecondarySubtitle;
  final Future<void> Function(SubtitleRendering) onSubtitleRendering;
  final Future<_LearningSubtitleLoadResult> Function() onPrepareLearningTracks;
  final VoidCallback onLearningLookup;
  final void Function(Duration delay, bool secondary) onSubtitleDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;
  final VoidCallback onToggleFit;

  @override
  Widget build(BuildContext context) {
    final artworkLoading =
        launch != null &&
        resolveError == null &&
        (resolving ||
            source == null ||
            snapshot.phase == PlaybackPhase.idle ||
            snapshot.phase == PlaybackPhase.opening ||
            (snapshot.phase == PlaybackPhase.buffering &&
                snapshot.position == Duration.zero));
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const ValueKey('player-surface-interaction'),
            behavior: HitTestBehavior.opaque,
            onTap:
                source != null &&
                    !artworkLoading &&
                    resolveError == null &&
                    snapshot.phase != PlaybackPhase.failed
                ? onTogglePlayback
                : null,
            child: surface,
          ),
          if (artworkLoading)
            _PlayerLoading(
              launch: launch!,
              status: resolveStatus ?? 'Preparing stream…',
            )
          else if (source == null && launch == null)
            const _IdlePlayer(),
          if (resolveError != null)
            _PlayerFailure(error: resolveError, onRetry: onRetry)
          else if (snapshot.phase == PlaybackPhase.failed)
            _PlayerFailure(error: snapshot.error, onRetry: onRetry),
          if (!artworkLoading &&
              snapshot.phase == PlaybackPhase.buffering &&
              resolveError == null)
            Center(
              child: CircularProgressIndicator(
                color: context.zeroPalette.text,
                strokeWidth: 2,
              ),
            ),
          _PlayerChrome(
            autoHide:
                source != null &&
                !artworkLoading &&
                resolveError == null &&
                snapshot.phase != PlaybackPhase.failed,
            top: _TopChrome(
              title: launch?.media.title.display ?? source?.name,
              subtitle: launch == null ? null : 'Episode ${launch!.episode}',
              provider: launch == null ? null : _serviceTitle(launch!.service),
              backToEpisodes: launch != null,
              onBack: onBack,
            ),
            bottom:
                source != null &&
                    !artworkLoading &&
                    resolveError == null &&
                    snapshot.phase != PlaybackPhase.failed
                ? _PlayerControls(
                    snapshot: snapshot,
                    snapshots: snapshots,
                    learningSettings: learningSettings,
                    fit: fit,
                    onTogglePlayback: onTogglePlayback,
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode,
                    onSeek: onSeek,
                    onVolume: onVolume,
                    onToggleMute: onToggleMute,
                    onSpeed: onSpeed,
                    onAudio: onAudio,
                    onSubtitle: onSubtitle,
                    onSecondarySubtitle: onSecondarySubtitle,
                    onSubtitleRendering: onSubtitleRendering,
                    onPrepareLearningTracks: onPrepareLearningTracks,
                    onSubtitleDelay: onSubtitleDelay,
                    onAddSubtitle: onAddSubtitle,
                    onToggleFit: onToggleFit,
                  )
                : null,
          ),
          if (snapshot.subtitleRendering == SubtitleRendering.learning)
            _LearningSubtitleOverlay(
              snapshot: snapshot,
              primary: primaryCue,
              secondary: secondaryCue,
              settings: learningSettings,
              preparationPending: learningPreparationPending,
              preparationResult: learningPreparationResult,
              onRetryPreparation: onPrepareLearningTracks,
              onLookup: onLearningLookup,
            ),
        ],
      ),
    );
  }
}

class _PlayerChrome extends StatefulWidget {
  const _PlayerChrome({
    required this.autoHide,
    required this.top,
    required this.bottom,
  });

  final bool autoHide;
  final Widget top;
  final Widget? bottom;

  @override
  State<_PlayerChrome> createState() => _PlayerChromeState();
}

class _PlayerChromeState extends State<_PlayerChrome> {
  static const _idleDelay = Duration(milliseconds: 2600);

  Timer? _idleTimer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleHide());
  }

  @override
  void didUpdateWidget(_PlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoHide != widget.autoHide) {
      if (widget.autoHide) {
        _reveal();
      } else {
        _idleTimer?.cancel();
        if (!_visible) setState(() => _visible = true);
      }
    }
  }

  void _scheduleHide() {
    _idleTimer?.cancel();
    if (!mounted || !widget.autoHide) return;
    _idleTimer = Timer(_idleDelay, () {
      if (mounted && widget.autoHide) setState(() => _visible = false);
    });
  }

  void _reveal() {
    if (!_visible && mounted) setState(() => _visible = true);
    _scheduleHide();
  }

  void _hideNow() {
    _idleTimer?.cancel();
    if (mounted && widget.autoHide && _visible) {
      setState(() => _visible = false);
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : ZeroTokens.motion;
    Widget animatedChrome({required Widget child, required Offset hidden}) {
      return IgnorePointer(
        ignoring: !_visible,
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : hidden,
          duration: duration,
          curve: ZeroTokens.easeSettle,
          child: AnimatedOpacity(
            key: ValueKey('player-chrome-${hidden.dy < 0 ? 'top' : 'bottom'}'),
            opacity: _visible ? 1 : 0,
            duration: duration,
            curve: ZeroTokens.easeSettle,
            child: child,
          ),
        ),
      );
    }

    return MouseRegion(
      opaque: false,
      cursor: widget.autoHide && !_visible
          ? SystemMouseCursors.none
          : MouseCursor.defer,
      onEnter: (_) => _reveal(),
      onHover: (_) => _reveal(),
      onExit: (_) => _hideNow(),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _reveal(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: animatedChrome(
                hidden: const Offset(0, -0.18),
                child: widget.top,
              ),
            ),
            if (widget.bottom case final bottom?)
              Align(
                alignment: Alignment.bottomCenter,
                child: animatedChrome(
                  hidden: const Offset(0, 0.18),
                  child: bottom,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.title,
    required this.subtitle,
    required this.provider,
    required this.backToEpisodes,
    required this.onBack,
  });

  final String? title;
  final String? subtitle;
  final String? provider;
  final bool backToEpisodes;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 72,
            child: Row(
              children: [
                const SizedBox(width: ZeroTokens.space3),
                IconButton(
                  tooltip: backToEpisodes ? 'Back to episodes' : 'Close player',
                  onPressed: onBack,
                  icon: Icon(
                    backToEpisodes
                        ? Icons.arrow_back_rounded
                        : Icons.close_rounded,
                  ),
                ),
                if (title != null) ...[
                  const SizedBox(width: ZeroTokens.space2),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: context.zeroPalette.textSecondary,
                                ),
                          ),
                      ],
                    ),
                  ),
                  if (provider != null) ...[
                    const SizedBox(width: ZeroTokens.space3),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.zeroPalette.surface.withValues(
                          alpha: 0.8,
                        ),
                        border: Border.all(color: context.zeroPalette.border),
                        borderRadius: BorderRadius.circular(
                          ZeroTokens.radiusPill,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: ZeroTokens.space3,
                          vertical: ZeroTokens.space1,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cloud_outlined,
                              size: 16,
                              color: context.zeroPalette.accentSoft,
                            ),
                            const SizedBox(width: ZeroTokens.space1),
                            Text(
                              provider!,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: ZeroTokens.space5),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerLoading extends StatelessWidget {
  const _PlayerLoading({required this.launch, required this.status});

  final PlaybackLaunch launch;
  final String status;

  @override
  Widget build(BuildContext context) {
    final media = launch.media;
    final background = media.bannerImage ?? media.coverImage;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (background != null)
          Image(
            image: CachedNetworkImageProvider(background),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                ColoredBox(color: context.zeroPalette.surfaceModal),
          )
        else
          ColoredBox(color: context.zeroPalette.surfaceModal),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.15,
              colors: [Color(0x806A5448), Color(0xF20A101A)],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x3D000000), Color(0xB3000000)],
            ),
          ),
        ),
        Center(
          child: SafeArea(
            minimum: const EdgeInsets.all(ZeroTokens.space6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;
                  final cover = _LoadingCover(url: media.coverImage);
                  final details = _LoadingCopy(
                    title: media.title.display,
                    episode: launch.episode,
                    status: status,
                  );
                  if (compact) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 190, child: cover),
                        const SizedBox(height: ZeroTokens.space5),
                        details,
                      ],
                    );
                  }
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: 210, child: cover),
                      const SizedBox(width: ZeroTokens.space5),
                      Flexible(child: details),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingCover extends StatelessWidget {
  const _LoadingCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusCard - 1),
        child: AspectRatio(
          aspectRatio: ZeroTokens.cardArtAspect,
          child: url == null
              ? ColoredBox(color: colors.surfaceRaised)
              : Image(
                  image: CachedNetworkImageProvider(url!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: colors.surfaceRaised),
                ),
        ),
      ),
    );
  }
}

class _LoadingCopy extends StatelessWidget {
  const _LoadingCopy({
    required this.title,
    required this.episode,
    required this.status,
  });

  final String title;
  final int episode;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
            shadows: const [Shadow(color: Colors.black, blurRadius: 14)],
          ),
        ),
        const SizedBox(height: ZeroTokens.space2),
        Text(
          'Episode $episode',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: context.zeroPalette.textSecondary),
        ),
        const SizedBox(height: ZeroTokens.space4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.zeroPalette.surfaceModal.withValues(alpha: 0.85),
            border: Border.all(color: context.zeroPalette.border),
            borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ZeroTokens.space3,
              vertical: ZeroTokens.space2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.zeroPalette.accentSoft,
                  ),
                ),
                const SizedBox(width: ZeroTokens.space2),
                Flexible(
                  child: Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _IdlePlayer extends StatelessWidget {
  const _IdlePlayer();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.play_circle_outline_rounded,
            size: 52,
            color: context.zeroPalette.textMuted,
          ),
          const SizedBox(height: ZeroTokens.space3),
          Text(
            'Choose an episode to play',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ],
      ),
    );
  }
}

class _PlayerFailure extends StatelessWidget {
  const _PlayerFailure({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is PlaybackFailure
        ? (error! as PlaybackFailure).message
        : error is DebridException
        ? (error! as DebridException).message
        : 'Playback stopped unexpectedly.';
    return ColoredBox(
      color: const Color(0xD9000000),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(ZeroTokens.space6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 46,
                  color: context.zeroPalette.error,
                ),
                const SizedBox(height: ZeroTokens.space4),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: ZeroTokens.space5),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.snapshot,
    required this.snapshots,
    required this.learningSettings,
    required this.fit,
    required this.onTogglePlayback,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onSpeed,
    required this.onAudio,
    required this.onSubtitle,
    required this.onSecondarySubtitle,
    required this.onSubtitleRendering,
    required this.onPrepareLearningTracks,
    required this.onSubtitleDelay,
    required this.onAddSubtitle,
    required this.onToggleFit,
  });

  final PlaybackSnapshot snapshot;
  final Stream<PlaybackSnapshot> snapshots;
  final Settings learningSettings;
  final BoxFit fit;
  final VoidCallback onTogglePlayback;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onSpeed;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onSubtitle;
  final ValueChanged<String?> onSecondarySubtitle;
  final Future<void> Function(SubtitleRendering) onSubtitleRendering;
  final Future<_LearningSubtitleLoadResult> Function() onPrepareLearningTracks;
  final void Function(Duration delay, bool secondary) onSubtitleDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;
  final VoidCallback onToggleFit;

  bool get _playing =>
      snapshot.phase == PlaybackPhase.playing ||
      snapshot.phase == PlaybackPhase.buffering;

  @override
  Widget build(BuildContext context) {
    final duration = snapshot.duration ?? Duration.zero;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xE6000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ZeroTokens.space5,
            42,
            ZeroTokens.space5,
            ZeroTokens.space4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SeekBar(
                position: snapshot.position,
                buffered: snapshot.buffered,
                duration: duration,
                onSeek: onSeek,
              ),
              const SizedBox(height: ZeroTokens.space2),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 540;
                  return Row(
                    children: [
                      if (onPreviousEpisode != null || onNextEpisode != null)
                        IconButton(
                          tooltip: 'Previous episode (P)',
                          onPressed: onPreviousEpisode,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                      IconButton(
                        tooltip: _playing ? 'Pause' : 'Play',
                        onPressed: onTogglePlayback,
                        icon: Icon(
                          _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      if (onPreviousEpisode != null || onNextEpisode != null)
                        IconButton(
                          tooltip: 'Next episode (N)',
                          onPressed: onNextEpisode,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      if (!compact) ...[
                        IconButton(
                          tooltip: snapshot.muted ? 'Unmute' : 'Mute',
                          onPressed: onToggleMute,
                          icon: Icon(
                            snapshot.muted
                                ? Icons.volume_off_rounded
                                : snapshot.volume < 0.5
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                          ),
                        ),
                        SizedBox(
                          width: 92,
                          child: Slider(
                            value: snapshot.volume.clamp(0, 1),
                            onChanged: onVolume,
                          ),
                        ),
                      ],
                      const SizedBox(width: ZeroTokens.space2),
                      Text(
                        '${_formatDuration(snapshot.position)} / '
                        '${_formatDuration(duration)}',
                        style: TextStyle(
                          fontFamily: ZeroTokens.fontFamilyStats,
                          fontSize: ZeroTokens.fontSize12,
                          color: context.zeroPalette.text,
                        ),
                      ),
                      const Spacer(),
                      if (!compact && snapshot.audioTracks.length > 1)
                        _TrackMenu(
                          tooltip: 'Audio track',
                          icon: Icons.audiotrack_rounded,
                          tracks: snapshot.audioTracks,
                          selected: snapshot.selectedAudio,
                          includeOff: false,
                          onSelected: onAudio,
                        ),
                      _SubtitleButton(
                        snapshot: snapshot,
                        snapshots: snapshots,
                        learningSettings: learningSettings,
                        onAudio: onAudio,
                        onPrimary: onSubtitle,
                        onSecondary: onSecondarySubtitle,
                        onRendering: onSubtitleRendering,
                        onPrepareLearningTracks: onPrepareLearningTracks,
                        onDelay: onSubtitleDelay,
                        onAddSubtitle: onAddSubtitle,
                      ),
                      if (!compact)
                        _SpeedMenu(speed: snapshot.speed, onSelected: onSpeed),
                      IconButton(
                        tooltip: fit == BoxFit.contain
                            ? 'Fill viewport'
                            : 'Fit video',
                        onPressed: onToggleFit,
                        icon: Icon(
                          fit == BoxFit.contain
                              ? Icons.fit_screen_rounded
                              : Icons.aspect_ratio_rounded,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration buffered;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _previewMilliseconds;
  bool _dragging = false;
  Timer? _previewReset;

  @override
  void didUpdateWidget(_SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preview = _previewMilliseconds;
    if (!_dragging && preview != null) {
      final distance = (widget.position.inMilliseconds - preview).abs();
      if (distance <= 750) {
        _previewMilliseconds = null;
        _previewReset?.cancel();
      }
    }
  }

  void _startSeek(double value) {
    _previewReset?.cancel();
    setState(() {
      _dragging = true;
      _previewMilliseconds = value;
    });
  }

  void _previewSeek(double value) {
    setState(() => _previewMilliseconds = value);
  }

  void _commitSeek(double value) {
    setState(() {
      _dragging = false;
      _previewMilliseconds = value;
    });
    widget.onSeek(Duration(milliseconds: value.round()));
    _previewReset?.cancel();
    _previewReset = Timer(const Duration(seconds: 2), () {
      if (mounted && !_dragging) {
        setState(() => _previewMilliseconds = null);
      }
    });
  }

  @override
  void dispose() {
    _previewReset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final end = widget.duration.inMilliseconds
        .toDouble()
        .clamp(1, double.infinity)
        .toDouble();
    final played =
        (_previewMilliseconds ?? widget.position.inMilliseconds.toDouble())
            .clamp(0, end)
            .toDouble();
    final loaded =
        widget.buffered.inMilliseconds.toDouble().clamp(0, end) / end;
    return SizedBox(
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
              child: LinearProgressIndicator(
                minHeight: 3,
                value: loaded,
                backgroundColor: const Color(0x3DFFFFFF),
                valueColor: const AlwaysStoppedAnimation(Color(0x70FFFFFF)),
              ),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: context.zeroPalette.seekbarAccent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: context.zeroPalette.seekbarAccent,
              overlayColor: context.zeroPalette.seekbarAccent.withValues(
                alpha: 0.2,
              ),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(
              value: played,
              max: end,
              onChangeStart: widget.duration > Duration.zero
                  ? _startSeek
                  : null,
              onChanged: widget.duration > Duration.zero ? _previewSeek : null,
              onChangeEnd: widget.duration > Duration.zero ? _commitSeek : null,
            ),
          ),
        ],
      ),
    );
  }
}

const _subtitleShadows = <Shadow>[
  Shadow(color: Color(0xF2000000), offset: Offset(-1.6, -1.6), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(0, -1.8), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(1.6, -1.6), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(-1.8, 0), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(1.8, 0), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(-1.6, 1.6), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(0, 1.8), blurRadius: 1),
  Shadow(color: Color(0xF2000000), offset: Offset(1.6, 1.6), blurRadius: 1),
  Shadow(color: Color(0xB3000000), offset: Offset(0, 2.5), blurRadius: 4),
];

const _maximumUnknownSubtitleCueDuration = Duration(seconds: 20);
const _learningCueAlignmentTolerance = Duration(milliseconds: 750);
const _maximumRememberedLearningCues = 512;
const _learningSubtitleFontSize = 48.0;

TextStyle _learningMainTextStyle(double scale) => TextStyle(
  fontFamily: ZeroTokens.fontFamilyStats,
  fontSize: _learningSubtitleFontSize * scale,
  fontWeight: FontWeight.w700,
  height: 1.08,
  letterSpacing: 0.1,
  color: Colors.white,
  shadows: _subtitleShadows,
);

class _LearningSubtitleOverlay extends ConsumerStatefulWidget {
  const _LearningSubtitleOverlay({
    required this.snapshot,
    required this.primary,
    required this.secondary,
    required this.settings,
    required this.preparationPending,
    required this.preparationResult,
    required this.onRetryPreparation,
    required this.onLookup,
  });

  final PlaybackSnapshot snapshot;
  final SubtitleCue? primary;
  final SubtitleCue? secondary;
  final Settings settings;
  final bool preparationPending;
  final _LearningSubtitleLoadResult? preparationResult;
  final Future<_LearningSubtitleLoadResult> Function() onRetryPreparation;
  final VoidCallback onLookup;

  @override
  ConsumerState<_LearningSubtitleOverlay> createState() =>
      _LearningSubtitleOverlayState();
}

class _LearningSubtitleOverlayState
    extends ConsumerState<_LearningSubtitleOverlay> {
  final Map<String, SubtitleCue> _cueHistory = {};
  int? _cueHistoryGeneration;
  String? _analyzedCue;
  Future<List<LearningToken>>? _tokens;
  LearningToken? _selected;
  Future<List<LearningDefinition>>? _definitions;
  final Map<String, FocusNode> _tokenFocusNodes = {};
  List<LearningToken> _focusableTokens = const [];
  bool _pausedForCue = false;
  bool _definitionFocusWithin = false;

  @override
  void initState() {
    super.initState();
    _rememberCurrentCues();
  }

  @override
  void didUpdateWidget(_LearningSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rememberCurrentCues();
  }

  @override
  void dispose() {
    for (final node in _tokenFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _rememberCurrentCues() {
    final generation = widget.snapshot.generation;
    if (_cueHistoryGeneration != generation) {
      _cueHistoryGeneration = generation;
      _cueHistory.clear();
    }
    for (final cue in [widget.primary, widget.secondary]) {
      if (cue == null ||
          cue.generation != generation ||
          cue.plainText.isEmpty) {
        continue;
      }
      _cueHistory[cue.identity] = cue;
    }
    while (_cueHistory.length > _maximumRememberedLearningCues) {
      _cueHistory.remove(_cueHistory.keys.first);
    }
  }

  bool _visible(SubtitleCue? cue, String? selectedTrack) {
    if (cue == null || cue.generation != widget.snapshot.generation) {
      return false;
    }
    if (selectedTrack == null || cue.trackId != selectedTrack) return false;
    // MPV's sub-text/secondary-sub-text transition is the authoritative
    // active-cue signal. Comparing it to Flutter's independently sampled
    // position stream made every new line wait for the next position tick.
    return cue.plainText.isNotEmpty;
  }

  MediaTrack? _trackFor(SubtitleCue cue) => widget.snapshot.subtitleTracks
      .where((track) => track.id == cue.trackId)
      .firstOrNull;

  bool _isJapaneseCue(SubtitleCue cue) {
    final language = _languageBase(_trackFor(cue)?.language);
    return language == 'ja' ||
        (language == null && _looksJapanese(cue.plainText));
  }

  SubtitleCue? _japaneseCue(bool showPrimary, bool showSecondary) {
    if (showPrimary &&
        widget.primary != null &&
        _isJapaneseCue(widget.primary!)) {
      return widget.primary;
    }
    if (showSecondary &&
        widget.secondary != null &&
        _isJapaneseCue(widget.secondary!)) {
      return widget.secondary;
    }
    return null;
  }

  Duration _delayFor(SubtitleCue cue) {
    if (cue.trackId == widget.snapshot.selectedPrimarySubtitle) {
      return widget.snapshot.primarySubtitleDelay;
    }
    if (cue.trackId == widget.snapshot.selectedSecondarySubtitle) {
      return widget.snapshot.secondarySubtitleDelay;
    }
    return Duration.zero;
  }

  Duration _effectiveEnd(SubtitleCue cue) {
    final reported = cue.end;
    final end = reported == null || reported < cue.start
        ? cue.start + _maximumUnknownSubtitleCueDuration
        : reported;
    return end + _delayFor(cue);
  }

  bool _cuesAlign(SubtitleCue japanese, SubtitleCue translation) {
    final japaneseStart = japanese.start + _delayFor(japanese);
    final japaneseEnd = _effectiveEnd(japanese);
    final translationStart = translation.start + _delayFor(translation);
    final translationEnd = _effectiveEnd(translation);
    return japaneseStart <= translationEnd + _learningCueAlignmentTolerance &&
        translationStart <= japaneseEnd + _learningCueAlignmentTolerance;
  }

  List<SubtitleCue> _translationCues(
    bool showPrimary,
    bool showSecondary,
    SubtitleCue? japanese,
  ) {
    final preferred = _languageBase(
      widget.settings.learningTranslationLanguage,
    );
    final selectedTracks = {
      widget.snapshot.selectedPrimarySubtitle,
      widget.snapshot.selectedSecondarySubtitle,
    }..remove(null);
    final candidates = japanese == null
        ? <SubtitleCue>[
            if (showPrimary && widget.primary != null) widget.primary!,
            if (showSecondary && widget.secondary != null) widget.secondary!,
          ]
        : _cueHistory.values.toList();
    final aligned = candidates.where((cue) {
      if (cue.identity == japanese?.identity ||
          cue.generation != widget.snapshot.generation ||
          cue.plainText.isEmpty ||
          !selectedTracks.contains(cue.trackId)) {
        return false;
      }
      final track = _trackFor(cue);
      return track != null &&
          _trackLanguageBase(track) == preferred &&
          (japanese == null || _cuesAlign(japanese, cue));
    }).toList()..sort((left, right) => left.start.compareTo(right.start));
    final seenText = <String>{};
    return aligned.where((cue) => seenText.add(cue.plainText)).toList();
  }

  bool get _hasSelectedJapaneseTextTrack {
    final selected = {
      widget.snapshot.selectedPrimarySubtitle,
      widget.snapshot.selectedSecondarySubtitle,
    }..remove(null);
    return widget.snapshot.subtitleTracks.any(
      (track) =>
          selected.contains(track.id) &&
          !track.isBitmapSubtitle &&
          _trackLanguageBase(track) == 'ja',
    );
  }

  void _ensureAnalyzed(SubtitleCue cue) {
    if (_analyzedCue == cue.identity) return;
    final retiredFocusNodes = _tokenFocusNodes.values.toList();
    _tokenFocusNodes.clear();
    _focusableTokens = const [];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in retiredFocusNodes) {
        node.dispose();
      }
    });
    _analyzedCue = cue.identity;
    _selected = null;
    _definitions = null;
    _pausedForCue = false;
    _tokens = ref
        .read(languageLearningToolsProvider)
        .tokenizeJapanese(cue.plainText);
  }

  FocusNode _focusNodeFor(LearningToken token) => _tokenFocusNodes.putIfAbsent(
    token.key,
    () => FocusNode(debugLabel: 'Learning word ${token.surface}'),
  );

  KeyEventResult _onTokenKeyEvent(String tokenKey, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    final index = _focusableTokens.indexWhere((token) => token.key == tokenKey);
    if (direction != 0) {
      final target = index + direction;
      if (index >= 0 && target >= 0 && target < _focusableTokens.length) {
        _focusNodeFor(_focusableTokens[target]).requestFocus();
      }
      return KeyEventResult.handled;
    }
    final activates =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.select;
    if (activates && index >= 0) {
      if (event is KeyDownEvent) _toggleLookup(_focusableTokens[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showLookup(LearningToken token) {
    if (!token.lookupable) return;
    if (token.key == _selected?.key) return;
    setState(() {
      _selected = token;
      _definitions = ref.read(languageLearningToolsProvider).lookup(token);
      if (widget.settings.learningPauseOnLookup && !_pausedForCue) {
        _pausedForCue = true;
        widget.onLookup();
      }
    });
  }

  void _toggleLookup(LearningToken token) {
    if (token.key == _selected?.key) {
      _closeLookup();
    } else {
      _showLookup(token);
    }
  }

  void _closeLookup() {
    if (_selected == null) return;
    setState(() {
      _selected = null;
      _definitions = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final showPrimary = _visible(
      widget.primary,
      widget.snapshot.selectedPrimarySubtitle,
    );
    final showSecondary = _visible(
      widget.secondary,
      widget.snapshot.selectedSecondarySubtitle,
    );
    if (!showPrimary && !showSecondary) return const SizedBox.shrink();
    final japanese = _japaneseCue(showPrimary, showSecondary);
    final translations = _translationCues(showPrimary, showSecondary, japanese);
    final translationText = translations.map((cue) => cue.plainText).join('\n');
    if (japanese != null) _ensureAnalyzed(japanese);
    final scale = widget.settings.subtitleTextScale;
    final showMissingTrackNotice =
        japanese == null &&
        !_hasSelectedJapaneseTextTrack &&
        widget.preparationResult?.ready != true;
    final definition = _selected;
    return Align(
      key: const ValueKey('learning-subtitle-overlay'),
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          ZeroTokens.space5,
          ZeroTokens.space5,
          ZeroTokens.space5,
          88,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1080,
            maxHeight: MediaQuery.sizeOf(context).height * 0.58,
          ),
          child: Focus(
            skipTraversal: true,
            canRequestFocus: false,
            onFocusChange: (focused) {
              _definitionFocusWithin = focused;
              if (!focused) _closeLookup();
            },
            child: HoverRegion(
              onExit: () {
                if (!_definitionFocusWithin) _closeLookup();
              },
              builder: (context, _) => SingleChildScrollView(
                reverse: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : ZeroTokens.motionQuick,
                      reverseDuration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : ZeroTokens.motionQuick,
                      switchInCurve: ZeroTokens.easeSettle,
                      switchOutCurve: Curves.easeOut,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SizeTransition(
                          sizeFactor: animation,
                          alignment: Alignment.bottomCenter,
                          child: child,
                        ),
                      ),
                      child: definition == null
                          ? const SizedBox.shrink(
                              key: ValueKey('learning-definition-empty'),
                            )
                          : Padding(
                              key: ValueKey(
                                'learning-definition-${definition.key}',
                              ),
                              padding: const EdgeInsets.only(
                                bottom: ZeroTokens.space3,
                              ),
                              child: _DefinitionPanel(
                                token: definition,
                                definitions: _definitions,
                                onClose: _closeLookup,
                                status:
                                    ref
                                        .watch(learningDictionaryStatusProvider)
                                        .value ??
                                    ref
                                        .read(languageLearningToolsProvider)
                                        .dictionaryStatus,
                              ),
                            ),
                    ),
                    if (showMissingTrackNotice) ...[
                      _LearningNotice(
                        message: widget.preparationPending
                            ? 'Finding Japanese text for this episode…'
                            : widget.preparationResult?.message ?? 'Japanese text is not selected. Open subtitle settings to choose a text track or add a sidecar.',
                        loading: widget.preparationPending,
                        onRetry: widget.preparationResult?.ready == false
                            ? () => unawaited(widget.onRetryPreparation())
                            : null,
                      ),
                      const SizedBox(height: ZeroTokens.space2),
                    ],
                    if (japanese != null)
                      FutureBuilder<List<LearningToken>>(
                        future: _tokens,
                        builder: (context, state) {
                          if (state.hasError) {
                            return Text(
                              japanese.plainText,
                              textAlign: TextAlign.center,
                              style: _learningMainTextStyle(scale),
                            );
                          }
                          final tokens = state.data;
                          if (tokens == null) {
                            return const Padding(
                              padding: EdgeInsets.all(ZeroTokens.space2),
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }
                          final lookupableTokens = tokens
                              .where((token) => token.lookupable)
                              .toList();
                          _focusableTokens = lookupableTokens;
                          return FocusTraversalGroup(
                            policy: OrderedTraversalPolicy(),
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.end,
                              spacing: 0,
                              runSpacing: ZeroTokens.space1,
                              children: [
                                for (final (index, token) in tokens.indexed)
                                  FocusTraversalOrder(
                                    order: NumericFocusOrder(index.toDouble()),
                                    child: _LearningWord(
                                      token: token,
                                      focusNode: _focusNodeFor(token),
                                      selected: token.key == _selected?.key,
                                      settings: widget.settings,
                                      scale: scale,
                                      onHighlight: () => _showLookup(token),
                                      onActivate: () => _toggleLookup(token),
                                      onKeyEvent: (_, event) =>
                                          _onTokenKeyEvent(token.key, event),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    if (translationText.isNotEmpty &&
                        widget.settings.learningShowTranslation) ...[
                      const SizedBox(height: ZeroTokens.space2),
                      Text(
                        translationText,
                        key: const ValueKey('learning-translation'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: ZeroTokens.fontFamilyStats,
                          fontSize: _learningSubtitleFontSize * scale,
                          fontWeight: FontWeight.w700,
                          height: 1.16,
                          letterSpacing: 0.05,
                          color: const Color(0xFFF8F8F8),
                          shadows: _subtitleShadows,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LearningWord extends StatelessWidget {
  const _LearningWord({
    required this.token,
    required this.focusNode,
    required this.selected,
    required this.settings,
    required this.scale,
    required this.onHighlight,
    required this.onActivate,
    required this.onKeyEvent,
  });

  final LearningToken token;
  final FocusNode focusNode;
  final bool selected;
  final Settings settings;
  final double scale;
  final VoidCallback onHighlight;
  final VoidCallback onActivate;
  final FocusOnKeyEventCallback onKeyEvent;

  @override
  Widget build(BuildContext context) {
    final reading = token.reading ?? token.pronunciation;
    final showKanji = settings.learningShowJapanese;
    final showKana = settings.learningShowFurigana;
    final showRomaji = settings.learningShowRomaji;
    if (!showKanji && !showKana && !showRomaji) {
      return const SizedBox.shrink();
    }
    final showRuby =
        showKana && showKanji && token.containsKanji && reading != null;
    final main = showKanji
        ? token.surface
        : showKana
        ? reading ?? token.surface
        : token.romanization ?? token.surface;
    final content = AnimatedContainer(
      key: ValueKey('learning-token-${token.key}'),
      duration: ZeroTokens.motionQuick,
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      decoration: BoxDecoration(
        color: selected
            ? context.zeroPalette.accent.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showKana && showKanji)
            SizedBox(
              height: 17 * scale,
              child: showRuby
                  ? Text(
                      reading,
                      style: TextStyle(
                        fontFamily: ZeroTokens.fontFamilyStats,
                        fontSize: 15.5 * scale,
                        fontWeight: FontWeight.w700,
                        height: 1.05,
                        color: const Color(0xFFF5F5F5),
                        shadows: _subtitleShadows,
                      ),
                    )
                  : null,
            ),
          Text(
            main,
            style: _learningMainTextStyle(scale).copyWith(
              color: selected ? context.zeroPalette.text : Colors.white,
            ),
          ),
          if (showRomaji && (showKanji || showKana))
            SizedBox(
              height: 16 * scale,
              child: token.romanization == null
                  ? null
                  : Text(
                      token.romanization!,
                      style: TextStyle(
                        fontFamily: ZeroTokens.fontFamilyStats,
                        fontSize: 14 * scale,
                        fontWeight: FontWeight.w600,
                        height: 1.05,
                        letterSpacing: 0.15,
                        color: const Color(0xFFD0D0D0),
                        shadows: _subtitleShadows,
                      ),
                    ),
            ),
        ],
      ),
    );
    if (!token.lookupable) return content;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Look up ${token.surface}',
      child: Focus(
        focusNode: focusNode,
        onKeyEvent: onKeyEvent,
        onFocusChange: (focused) {
          if (focused) onHighlight();
        },
        child: HoverRegion(
          cursor: SystemMouseCursors.click,
          onEnter: onHighlight,
          builder: (context, _) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onActivate,
            child: content,
          ),
        ),
      ),
    );
  }
}

class _DefinitionPanel extends StatelessWidget {
  const _DefinitionPanel({
    required this.token,
    required this.definitions,
    required this.status,
    required this.onClose,
  });

  final LearningToken token;
  final Future<List<LearningDefinition>>? definitions;
  final LearningDictionaryStatus? status;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final reading = [
      if (token.reading != null) token.reading!,
      if (token.romanization != null) token.romanization!,
    ].join('  ·  ');
    return Center(
      child: AnimatedContainer(
        key: const ValueKey('learning-definition-panel'),
        duration: ZeroTokens.motionQuick,
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 160),
        padding: const EdgeInsets.fromLTRB(
          ZeroTokens.space3,
          ZeroTokens.space2,
          ZeroTokens.space2,
          ZeroTokens.space3,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.zeroPalette.surface.withValues(alpha: 0.85),
              context.zeroPalette.shell.withValues(alpha: 0.78),
            ],
          ),
          border: Border.all(
            color: context.zeroPalette.accentHover.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  token.baseForm ?? token.surface,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.zeroPalette.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (reading.isNotEmpty) ...[
                  const SizedBox(width: ZeroTokens.space2),
                  Flexible(
                    child: Text(
                      reading,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: context.zeroPalette.accentSoft),
                    ),
                  ),
                ],
                if (token.partOfSpeech != null) ...[
                  const SizedBox(width: ZeroTokens.space2),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.zeroPalette.navSelected,
                      borderRadius: BorderRadius.circular(
                        ZeroTokens.radiusPill,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ZeroTokens.space2,
                        vertical: 2,
                      ),
                      child: Text(
                        token.partOfSpeech!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: context.zeroPalette.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: 'Close definition',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, size: 17),
                ),
              ],
            ),
            const SizedBox(height: ZeroTokens.space2),
            if (status?.installed != true)
              Text(
                'Install JMdict in Settings → Learning for offline English definitions.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              FutureBuilder<List<LearningDefinition>>(
                future: definitions,
                builder: (context, state) {
                  if (state.connectionState != ConnectionState.done) {
                    return const LinearProgressIndicator(minHeight: 2);
                  }
                  final entries = state.data ?? const [];
                  if (entries.isEmpty) {
                    return Text(
                      'No matching JMdict entry found for this word.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  final summary = entries
                      .take(3)
                      .expand((entry) => entry.definitions.take(2))
                      .join('  ·  ');
                  return Text(
                    summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.zeroPalette.text,
                      height: 1.3,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _LearningNotice extends StatelessWidget {
  const _LearningNotice({
    required this.message,
    this.loading = false,
    this.onRetry,
  });

  final String message;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.zeroPalette.shell.withValues(alpha: 0.7),
      border: Border.all(color: context.zeroPalette.border),
      borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ZeroTokens.space3,
        vertical: ZeroTokens.space2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              Icons.subtitles_off_rounded,
              size: 17,
              color: context.zeroPalette.warning,
            ),
          const SizedBox(width: ZeroTokens.space2),
          Flexible(
            child: Text(
              message,
              key: const ValueKey('learning-text-track-required'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(shadows: _subtitleShadows),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: ZeroTokens.space2),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    ),
  );
}

class _LearningSubtitleLoadResult {
  const _LearningSubtitleLoadResult.ready(this.message, {this.primaryTrackId})
    : ready = true;

  const _LearningSubtitleLoadResult.unavailable(this.message)
    : ready = false,
      primaryTrackId = null;

  final bool ready;
  final String message;
  final String? primaryTrackId;

  _LearningSubtitleLoadResult copyWithMessage(String message) => ready
      ? _LearningSubtitleLoadResult.ready(
          message,
          primaryTrackId: primaryTrackId,
        )
      : _LearningSubtitleLoadResult.unavailable(message);
}

class _ExternalSubtitleRequest {
  const _ExternalSubtitleRequest({
    required this.source,
    this.title,
    this.language,
  });

  final String source;
  final String? title;
  final String? language;
}

class _SubtitleButton extends StatelessWidget {
  const _SubtitleButton({
    required this.snapshot,
    required this.snapshots,
    required this.learningSettings,
    required this.onAudio,
    required this.onPrimary,
    required this.onSecondary,
    required this.onRendering,
    required this.onPrepareLearningTracks,
    required this.onDelay,
    required this.onAddSubtitle,
  });

  final PlaybackSnapshot snapshot;
  final Stream<PlaybackSnapshot> snapshots;
  final Settings learningSettings;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onPrimary;
  final ValueChanged<String?> onSecondary;
  final Future<void> Function(SubtitleRendering) onRendering;
  final Future<_LearningSubtitleLoadResult> Function() onPrepareLearningTracks;
  final void Function(Duration delay, bool secondary) onDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Subtitles',
      onPressed: () => _showSubtitlePanel(
        context,
        panel: _SubtitlePanel(
          snapshot: snapshot,
          snapshots: snapshots,
          learningSettings: learningSettings,
          onAudio: onAudio,
          onPrimary: onPrimary,
          onSecondary: onSecondary,
          onRendering: onRendering,
          onPrepareLearningTracks: onPrepareLearningTracks,
          onDelay: onDelay,
          onAddSubtitle: onAddSubtitle,
        ),
      ),
      icon: Icon(
        snapshot.selectedPrimarySubtitle == null ||
                snapshot.subtitleRendering == SubtitleRendering.off
            ? Icons.subtitles_off_rounded
            : Icons.subtitles_rounded,
      ),
    );
  }
}

class _SubtitlePanel extends ConsumerStatefulWidget {
  const _SubtitlePanel({
    required this.snapshot,
    required this.snapshots,
    required this.learningSettings,
    required this.onAudio,
    required this.onPrimary,
    required this.onSecondary,
    required this.onRendering,
    required this.onPrepareLearningTracks,
    required this.onDelay,
    required this.onAddSubtitle,
  });

  final PlaybackSnapshot snapshot;
  final Stream<PlaybackSnapshot> snapshots;
  final Settings learningSettings;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onPrimary;
  final ValueChanged<String?> onSecondary;
  final Future<void> Function(SubtitleRendering) onRendering;
  final Future<_LearningSubtitleLoadResult> Function() onPrepareLearningTracks;
  final void Function(Duration delay, bool secondary) onDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;

  @override
  ConsumerState<_SubtitlePanel> createState() => _SubtitlePanelState();
}

enum _LearningLayer { kanji, kana, romaji, translation }

class _SubtitlePanelState extends ConsumerState<_SubtitlePanel> {
  late final StreamSubscription<PlaybackSnapshot> _subscription;
  late PlaybackSnapshot _snapshot = widget.snapshot;
  late String? _primary = widget.snapshot.selectedPrimarySubtitle;
  late String? _secondary = widget.snapshot.selectedSecondarySubtitle;
  late SubtitleRendering _rendering = widget.snapshot.subtitleRendering;
  late Duration _primaryDelay = widget.snapshot.primarySubtitleDelay;
  late Duration _secondaryDelay = widget.snapshot.secondarySubtitleDelay;
  late bool _showKanji = widget.learningSettings.learningShowJapanese;
  late bool _showKana = widget.learningSettings.learningShowFurigana;
  late bool _showRomaji = widget.learningSettings.learningShowRomaji;
  late bool _showTranslation = widget.learningSettings.learningShowTranslation;
  String? _learningWarning;
  bool _learningMessagePositive = false;
  bool _findingJapanese = false;
  bool _learningCanRetry = false;
  int _learningRequest = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.snapshots.listen((snapshot) {
      if (!mounted || snapshot.generation != _snapshot.generation) return;
      setState(() {
        _snapshot = snapshot;
        _primary = snapshot.selectedPrimarySubtitle;
        _secondary = snapshot.selectedSecondarySubtitle;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  void _selectPrimary(String? id) {
    setState(() => _primary = id);
    widget.onPrimary(id);
  }

  void _selectSecondary(String? id) {
    setState(() {
      _secondary = id;
      if (_rendering == SubtitleRendering.learning) {
        _showTranslation = id != null;
      }
    });
    widget.onSecondary(id);
  }

  void _setDelay(Duration value, {required bool secondary}) {
    setState(() {
      if (secondary) {
        _secondaryDelay = value;
      } else {
        _primaryDelay = value;
      }
    });
    widget.onDelay(value, secondary);
  }

  void _setLearningLayer(_LearningLayer layer, bool selected) {
    setState(() {
      switch (layer) {
        case _LearningLayer.kanji:
          _showKanji = selected;
          break;
        case _LearningLayer.kana:
          _showKana = selected;
          break;
        case _LearningLayer.romaji:
          _showRomaji = selected;
          break;
        case _LearningLayer.translation:
          _showTranslation = selected;
          break;
      }
    });
    final showKanji = _showKanji;
    final showKana = _showKana;
    final showRomaji = _showRomaji;
    final showTranslation = _showTranslation;
    unawaited(
      ref
          .read(settingsControllerProvider.notifier)
          .persist(
            (current) => current.copyWith(
              learningShowJapanese: showKanji,
              learningShowFurigana: showKana,
              learningShowRomaji: showRomaji,
              learningShowTranslation: showTranslation,
            ),
          ),
    );
  }

  Future<void> _setRendering(SubtitleRendering mode) async {
    final request = ++_learningRequest;
    setState(() {
      _rendering = mode;
      _learningWarning = null;
      _learningMessagePositive = false;
      _learningCanRetry = false;
    });
    try {
      await widget.onRendering(mode);
    } on PlaybackFailure catch (failure) {
      if (!mounted || request != _learningRequest) return;
      setState(() {
        _learningWarning = failure.message;
        _learningCanRetry = true;
      });
      return;
    }
    if (mode == SubtitleRendering.learning &&
        widget.learningSettings.learningAutoSelectTracks) {
      await _prepareLearningTracks();
    }
  }

  Future<void> _prepareLearningTracks() async {
    final request = ++_learningRequest;
    setState(() {
      _findingJapanese = true;
      _learningCanRetry = false;
      _learningWarning = 'Preparing Japanese text and translation tracks…';
    });
    final result = await widget.onPrepareLearningTracks();
    if (!mounted ||
        request != _learningRequest ||
        _rendering != SubtitleRendering.learning) {
      return;
    }
    setState(() {
      _findingJapanese = false;
      _learningMessagePositive = result.ready;
      _learningCanRetry = !result.ready;
      _learningWarning = result.message;
      _primary = result.primaryTrackId ?? _snapshot.selectedPrimarySubtitle;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
      child: Material(
        color: context.zeroPalette.shell,
        elevation: 24,
        shadowColor: Colors.black,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: context.zeroPalette.border),
          borderRadius: BorderRadius.circular(ZeroTokens.radiusSurfaceTop),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ZeroTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.translate_rounded,
                    color: context.zeroPalette.accentSoft,
                  ),
                  const SizedBox(width: ZeroTokens.space2),
                  Expanded(
                    child: Text(
                      'Subtitles',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: ZeroTokens.space4),
              Text('Display', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: ZeroTokens.space2),
              SegmentedButton<SubtitleRendering>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: SubtitleRendering.standard,
                    icon: Icon(Icons.closed_caption_rounded, size: 18),
                    label: Text('Styled'),
                  ),
                  ButtonSegment(
                    value: SubtitleRendering.learning,
                    icon: Icon(Icons.touch_app_rounded, size: 18),
                    label: Text('Learning'),
                  ),
                  ButtonSegment(
                    value: SubtitleRendering.off,
                    icon: Icon(Icons.visibility_off_rounded, size: 18),
                    label: Text('Hidden'),
                  ),
                ],
                selected: {_rendering},
                onSelectionChanged: (selection) =>
                    _setRendering(selection.single),
              ),
              if (_rendering == SubtitleRendering.learning) ...[
                const SizedBox(height: ZeroTokens.space4),
                Text(
                  'Learning layers',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: ZeroTokens.space2),
                Wrap(
                  spacing: ZeroTokens.space2,
                  runSpacing: ZeroTokens.space2,
                  children: [
                    FilterChip(
                      key: const ValueKey('learning-layer-kanji'),
                      label: const Text('Kanji'),
                      selected: _showKanji,
                      onSelected: (value) =>
                          _setLearningLayer(_LearningLayer.kanji, value),
                    ),
                    FilterChip(
                      key: const ValueKey('learning-layer-kana'),
                      label: const Text('Kana'),
                      selected: _showKana,
                      onSelected: (value) =>
                          _setLearningLayer(_LearningLayer.kana, value),
                    ),
                    FilterChip(
                      key: const ValueKey('learning-layer-romaji'),
                      label: const Text('Romaji'),
                      selected: _showRomaji,
                      onSelected: (value) =>
                          _setLearningLayer(_LearningLayer.romaji, value),
                    ),
                    FilterChip(
                      key: const ValueKey('learning-layer-translation'),
                      label: const Text('Translation'),
                      selected: _showTranslation,
                      onSelected: (value) =>
                          _setLearningLayer(_LearningLayer.translation, value),
                    ),
                  ],
                ),
              ],
              if (_learningWarning != null) ...[
                const SizedBox(height: ZeroTokens.space3),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: _learningMessagePositive
                        ? context.zeroPalette.success.withValues(alpha: 0.12)
                        : context.zeroPalette.warning.withValues(alpha: 0.13),
                    border: Border.all(
                      color: _learningMessagePositive
                          ? context.zeroPalette.success
                          : _findingJapanese
                          ? context.zeroPalette.accentHover
                          : context.zeroPalette.warning,
                    ),
                    borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(ZeroTokens.space3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_findingJapanese)
                          const SizedBox.square(
                            dimension: 19,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            _learningMessagePositive
                                ? Icons.check_circle_outline_rounded
                                : Icons.info_outline_rounded,
                            color: _learningMessagePositive
                                ? context.zeroPalette.success
                                : context.zeroPalette.warning,
                            size: 19,
                          ),
                        const SizedBox(width: ZeroTokens.space2),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _learningWarning!,
                                  key: const ValueKey('learning-track-warning'),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              if (_learningCanRetry) ...[
                                const SizedBox(width: ZeroTokens.space2),
                                TextButton(
                                  onPressed: () =>
                                      unawaited(_prepareLearningTracks()),
                                  child: const Text('Try again'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: ZeroTokens.space3),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const ValueKey('advanced-subtitle-settings'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(
                    bottom: ZeroTokens.space2,
                  ),
                  leading: const Icon(Icons.tune_rounded, size: 20),
                  title: const Text('Advanced'),
                  subtitle: const Text('Manual tracks, timing, and sidecars'),
                  children: [
                    _TrackPickerRow(
                      key: const ValueKey('primary-subtitle-track'),
                      title: 'Primary track',
                      tracks: _snapshot.subtitleTracks,
                      selected: _primary,
                      onSelected: _selectPrimary,
                    ),
                    const SizedBox(height: ZeroTokens.space2),
                    _TrackPickerRow(
                      key: const ValueKey('secondary-subtitle-track'),
                      title: 'Secondary track',
                      subtitle: 'Optional translation line',
                      tracks: _snapshot.subtitleTracks,
                      selected: _secondary,
                      onSelected: _selectSecondary,
                    ),
                    const SizedBox(height: ZeroTokens.space3),
                    _DelayRow(
                      label: 'Primary timing',
                      value: _primaryDelay,
                      onChanged: (value) => _setDelay(value, secondary: false),
                    ),
                    _DelayRow(
                      label: 'Secondary timing',
                      value: _secondaryDelay,
                      onChanged: (value) => _setDelay(value, secondary: true),
                    ),
                    const SizedBox(height: ZeroTokens.space2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final request = await _showExternalSubtitleDialog(
                            context,
                          );
                          if (request != null) widget.onAddSubtitle(request);
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add sidecar subtitle'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showSubtitlePanel(BuildContext context, {required Widget panel}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close subtitle settings',
    barrierColor: const Color(0xB3000000),
    transitionDuration: reduceMotion ? Duration.zero : ZeroTokens.motion,
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      minimum: const EdgeInsets.all(ZeroTokens.space4),
      child: Center(child: panel),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: ZeroTokens.easeSettle,
        reverseCurve: ZeroTokens.easePress,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _TrackPickerRow extends StatelessWidget {
  const _TrackPickerRow({
    super.key,
    required this.title,
    required this.tracks,
    required this.selected,
    required this.onSelected,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<MediaTrack> tracks;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = tracks.indexWhere((track) => track.id == selected);
    final selectedLabel = selected == null
        ? 'Off'
        : selectedIndex < 0
        ? 'Unavailable track'
        : _fullTrackLabel(tracks[selectedIndex], selectedIndex);
    return PopupMenuButton<_TrackChoice>(
      tooltip: 'Choose $title',
      onSelected: (choice) => onSelected(choice.id),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: const _TrackChoice(null),
          checked: selected == null,
          child: const Text('Off'),
        ),
        for (var index = 0; index < tracks.length; index++)
          CheckedPopupMenuItem(
            value: _TrackChoice(tracks[index].id),
            checked: selected == tracks[index].id,
            child: Text(_fullTrackLabel(tracks[index], index)),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.zeroPalette.panel,
          border: Border.all(color: context.zeroPalette.border),
          borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        ),
        child: Padding(
          padding: const EdgeInsets.all(ZeroTokens.space3),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: ZeroTokens.space1),
                    Text(
                      selectedLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: context.zeroPalette.accentSoft),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.expand_more_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _DelayRow extends StatelessWidget {
  const _DelayRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final seconds = value.inMilliseconds / 1000;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ZeroTokens.space1),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
          IconButton(
            tooltip: 'Earlier by 0.1 seconds',
            onPressed: () =>
                onChanged(value - const Duration(milliseconds: 100)),
            icon: const Icon(Icons.remove_rounded),
          ),
          SizedBox(
            width: 64,
            child: TextButton(
              onPressed: () => onChanged(Duration.zero),
              child: Text(
                '${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(1)}s',
                style: const TextStyle(fontFamily: ZeroTokens.fontFamilyStats),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Later by 0.1 seconds',
            onPressed: () =>
                onChanged(value + const Duration(milliseconds: 100)),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

Future<_ExternalSubtitleRequest?> _showExternalSubtitleDialog(
  BuildContext context,
) async {
  final source = TextEditingController();
  final title = TextEditingController();
  final language = TextEditingController();
  try {
    return await showDialog<_ExternalSubtitleRequest>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add sidecar subtitle'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('external-subtitle-source'),
                controller: source,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'File or HTTPS URL',
                  hintText: 'file:///…/subtitle.ass',
                ),
              ),
              const SizedBox(height: ZeroTokens.space3),
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'Track name (optional)',
                  hintText: 'Full subtitles, signs & songs…',
                ),
              ),
              const SizedBox(height: ZeroTokens.space3),
              TextField(
                controller: language,
                decoration: const InputDecoration(
                  labelText: 'Language (optional)',
                  hintText: 'en, ja, es-419…',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = source.text.trim();
              if (value.isEmpty) return;
              Navigator.of(context).pop(
                _ExternalSubtitleRequest(
                  source: value,
                  title: title.text.trim().isEmpty ? null : title.text.trim(),
                  language: language.text.trim().isEmpty
                      ? null
                      : language.text.trim(),
                ),
              );
            },
            child: const Text('Load'),
          ),
        ],
      ),
    );
  } finally {
    source.dispose();
    title.dispose();
    language.dispose();
  }
}

class _TrackChoice {
  const _TrackChoice(this.id);

  final String? id;
}

class _TrackMenu extends StatelessWidget {
  const _TrackMenu({
    required this.tooltip,
    required this.icon,
    required this.tracks,
    required this.selected,
    required this.includeOff,
    required this.onSelected,
  });

  final String tooltip;
  final IconData icon;
  final List<MediaTrack> tracks;
  final String? selected;
  final bool includeOff;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_TrackChoice>(
      tooltip: tooltip,
      icon: Icon(icon),
      onSelected: (choice) => onSelected(choice.id),
      itemBuilder: (context) => [
        if (includeOff)
          CheckedPopupMenuItem(
            value: const _TrackChoice(null),
            checked: selected == null,
            child: const Text('Off'),
          ),
        for (var index = 0; index < tracks.length; index++)
          CheckedPopupMenuItem(
            value: _TrackChoice(tracks[index].id),
            checked: selected == tracks[index].id,
            child: Text(_fullTrackLabel(tracks[index], index)),
          ),
      ],
    );
  }
}

class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.speed, required this.onSelected});

  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  final double speed;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Playback speed',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final value in speeds)
          CheckedPopupMenuItem(
            value: value,
            checked: (speed - value).abs() < 0.01,
            child: Text('$value×'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZeroTokens.space2),
        child: Text(
          '${speed.toStringAsFixed(speed == speed.roundToDouble() ? 0 : 2)}×',
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
  }
}

String _trackLabel(MediaTrack track, int index) =>
    track.title?.trim().isNotEmpty == true
    ? track.title!.trim()
    : _languageName(track.language) ?? 'Track ${index + 1}';

String _trackDetail(MediaTrack track) => [
  ?_languageName(track.language),
  if (track.codec?.trim().isNotEmpty == true) track.codec!.toUpperCase(),
  if (track.isDefault) 'Default',
  if (track.isForced) 'Forced',
  if (track.isExternal) 'External',
  if (track.isBitmapSubtitle) 'Bitmap',
].join(' · ');

String _fullTrackLabel(MediaTrack track, int index) {
  final label = _trackLabel(track, index);
  final detail = _trackDetail(track);
  return detail.isEmpty || detail == label ? label : '$label — $detail';
}

String? _languageName(String? code) {
  if (code == null || code.trim().isEmpty) return null;
  final normalized = code.toLowerCase();
  final base = normalized.split('-').first;
  const names = {
    'ar': 'Arabic',
    'de': 'German',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'hi': 'Hindi',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'nl': 'Dutch',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'th': 'Thai',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'vi': 'Vietnamese',
    'zh': 'Chinese',
  };
  final name = names[base] ?? code.toUpperCase();
  final region = normalized.contains('-')
      ? normalized.substring(normalized.indexOf('-') + 1).toUpperCase()
      : null;
  return region == null ? name : '$name ($region)';
}

String? _languageBase(String? code) {
  if (code == null || code.trim().isEmpty || code == 'und') return null;
  final base = code.trim().toLowerCase().replaceAll('_', '-').split('-').first;
  const iso3 = {
    'ara': 'ar',
    'arabic': 'ar',
    'deu': 'de',
    'ger': 'de',
    'german': 'de',
    'eng': 'en',
    'english': 'en',
    'spa': 'es',
    'spanish': 'es',
    'fra': 'fr',
    'fre': 'fr',
    'french': 'fr',
    'hin': 'hi',
    'hindi': 'hi',
    'ind': 'id',
    'indonesian': 'id',
    'ita': 'it',
    'italian': 'it',
    'ja': 'ja',
    'jp': 'ja',
    'jap': 'ja',
    'jpn': 'ja',
    'japanese': 'ja',
    'kor': 'ko',
    'korean': 'ko',
    'nld': 'nl',
    'dut': 'nl',
    'dutch': 'nl',
    'pol': 'pl',
    'polish': 'pl',
    'por': 'pt',
    'portuguese': 'pt',
    'rus': 'ru',
    'russian': 'ru',
    'tha': 'th',
    'thai': 'th',
    'tur': 'tr',
    'turkish': 'tr',
    'ukr': 'uk',
    'ukrainian': 'uk',
    'vie': 'vi',
    'vietnamese': 'vi',
    'zho': 'zh',
    'chi': 'zh',
    'chinese': 'zh',
  };
  return iso3[base] ?? base;
}

SubtitleRendering _subtitleRenderingFromSetting(String value) =>
    switch (value) {
      'learning' => SubtitleRendering.learning,
      'off' => SubtitleRendering.off,
      _ => SubtitleRendering.standard,
    };

String _learningReleaseIdentity(
  PlayerFile? source, {
  required String fallback,
}) {
  if (source == null) return fallback;
  final values = <String>[
    if (source.torrentName?.trim() case final value? when value.isNotEmpty)
      value,
    if (source.name.trim().isNotEmpty) source.name.trim(),
  ];
  return values.toSet().join(' / ');
}

String? _settingLanguageForTrack(
  Iterable<MediaTrack> tracks,
  String? trackId, {
  String? automatic,
}) {
  if (trackId == null) return automatic;
  final track = tracks
      .where((candidate) => candidate.id == trackId)
      .firstOrNull;
  if (track == null) return null;
  final language = _trackLanguageBase(track);
  if (language == 'ja') return 'jpn';
  if (language == 'en') return 'eng';
  const supported = {
    'es',
    'pt',
    'de',
    'fr',
    'it',
    'ko',
    'zh',
    'ru',
    'ar',
    'hi',
    'id',
    'pl',
    'th',
    'tr',
    'uk',
    'vi',
  };
  return supported.contains(language) ? language : null;
}

String? _trackLanguageBase(MediaTrack track) {
  final tagged = _languageBase(track.language);
  if (tagged != null) return tagged;
  final title = track.title?.toLowerCase();
  if (title == null || title.trim().isEmpty) return null;
  final words = RegExp(r'[a-z]{2,}')
      .allMatches(title)
      .map((match) => match.group(0)!)
      .toSet();
  const aliases = <String, String>{
    'ja': 'ja',
    'jp': 'ja',
    'jpn': 'ja',
    'japanese': 'ja',
    'en': 'en',
    'eng': 'en',
    'english': 'en',
    'es': 'es',
    'spa': 'es',
    'spanish': 'es',
    'pt': 'pt',
    'por': 'pt',
    'portuguese': 'pt',
    'de': 'de',
    'deu': 'de',
    'ger': 'de',
    'german': 'de',
    'fr': 'fr',
    'fra': 'fr',
    'fre': 'fr',
    'french': 'fr',
    'it': 'it',
    'ita': 'it',
    'italian': 'it',
    'ko': 'ko',
    'kor': 'ko',
    'korean': 'ko',
    'zh': 'zh',
    'zho': 'zh',
    'chi': 'zh',
    'chinese': 'zh',
    'ru': 'ru',
    'rus': 'ru',
    'russian': 'ru',
    'ar': 'ar',
    'ara': 'ar',
    'arabic': 'ar',
    'hi': 'hi',
    'hin': 'hi',
    'hindi': 'hi',
    'id': 'id',
    'ind': 'id',
    'indonesian': 'id',
    'pl': 'pl',
    'pol': 'pl',
    'polish': 'pl',
    'th': 'th',
    'tha': 'th',
    'thai': 'th',
    'tr': 'tr',
    'tur': 'tr',
    'turkish': 'tr',
    'uk': 'uk',
    'ukr': 'uk',
    'ukrainian': 'uk',
    'vi': 'vi',
    'vie': 'vi',
    'vietnamese': 'vi',
  };
  for (final word in words) {
    final language = aliases[word];
    if (language != null) return language;
  }
  return null;
}

MediaTrack? _preferredLearningTrack(
  Iterable<MediaTrack> tracks,
  String? language, {
  Iterable<String?> selectedIds = const [],
  Iterable<String?> preferredIds = const [],
  bool subtitle = false,
}) {
  final wanted = _languageBase(language);
  if (wanted == null) return null;
  final selected = selectedIds.whereType<String>().toSet();
  final preferred = preferredIds.whereType<String>().toSet();
  MediaTrack? best;
  int? bestScore;
  for (final track in tracks) {
    if (_trackLanguageBase(track) != wanted) continue;
    final title = track.title?.toLowerCase() ?? '';
    var score = track.isDefault ? 25 : 0;
    if (selected.contains(track.id)) score += 15;
    if (preferred.contains(track.id)) score += 1000;
    if (subtitle) {
      if (RegExp(r'\b(full|dialogue|dialog|complete)\b').hasMatch(title)) {
        score += 80;
      }
      if (track.isForced ||
          RegExp(r'\b(signs?|songs?|forced)\b').hasMatch(title)) {
        score -= 140;
      }
      if (RegExp(r'\b(jimaku|learning)\b').hasMatch(title)) score += 40;
    } else {
      if (RegExp(r'\b(main|original)\b').hasMatch(title)) score += 30;
      if (RegExp(r'\b(commentary|descriptive|description)\b').hasMatch(title)) {
        score -= 140;
      }
    }
    if (bestScore == null || score > bestScore) {
      best = track;
      bestScore = score;
    }
  }
  return best;
}

MediaTrack? _preferredStandardSubtitle(
  PlaybackSnapshot snapshot,
  String? language, {
  String? previousTrackId,
}) {
  final wanted = _languageBase(language);
  if (wanted != null) {
    return _preferredLearningTrack(
      snapshot.subtitleTracks,
      wanted,
      preferredIds: [previousTrackId],
      subtitle: true,
    );
  }
  final previous = snapshot.subtitleTracks
      .where((track) => track.id == previousTrackId)
      .firstOrNull;
  if (previous != null) return previous;
  final selected = snapshot.subtitleTracks
      .where((track) => track.id == snapshot.selectedPrimarySubtitle)
      .firstOrNull;
  if (selected != null) return selected;
  return snapshot.subtitleTracks.where((track) => track.isDefault).firstOrNull;
}

String _languageTitle(String? code) =>
    _languageName(_languageBase(code)) ?? 'translation';

bool _looksJapanese(String text) => text.runes.any(
  (rune) =>
      (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x3400 && rune <= 0x9fff) ||
      (rune >= 0xf900 && rune <= 0xfaff),
);

String _formatDuration(Duration value) {
  final total = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final tail =
      '${minutes.toString().padLeft(hours > 0 ? 2 : 1, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$tail' : tail;
}

PlayerFile _pickResolvedTarget(ResolvedDebrid resolved, int episode) {
  if (resolved.target case final target?) return target;
  if (resolved.files.length == 1) return resolved.files.single;
  throw DebridException(
    DebridErrorKind.rejected,
    'The release did not identify a safe file for episode $episode. Choose another release.',
  );
}

bool _canTryAnotherRelease(DebridException error) => switch (error.kind) {
  DebridErrorKind.notCached ||
  DebridErrorKind.unavailable ||
  DebridErrorKind.rejected => true,
  DebridErrorKind.auth ||
  DebridErrorKind.network ||
  DebridErrorKind.timeout ||
  DebridErrorKind.service => false,
};

String _serviceTitle(DebridService service) => switch (service) {
  DebridService.alldebrid => 'AllDebrid',
  DebridService.premiumize => 'Premiumize',
  DebridService.realdebrid => 'Real-Debrid',
  DebridService.torbox => 'TorBox',
};
