import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../application/learning/providers.dart';
import '../../application/learning/subtitle_providers.dart';
import '../../application/playback/backend.dart';
import '../../application/playback/probe.dart';
import '../../application/playback/providers.dart';
import '../../application/playback/request.dart';
import '../../application/settings/providers.dart';
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
  String? _learningAutoAttempt;
  SubtitleRendering _requestedSubtitleRendering = SubtitleRendering.standard;
  int _activePlaybackGeneration = 0;
  BoxFit _fit = BoxFit.contain;
  double _lastAudibleVolume = 1;
  bool _exitHandled = false;

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
            oldWidget.initialLaunch?.episode !=
                widget.initialLaunch!.episode)) {
      unawaited(_resolveLaunch(widget.initialLaunch!));
    } else if (widget.initialSource != null &&
        oldWidget.initialSource?.url != widget.initialSource!.url) {
      _source = widget.initialSource;
      unawaited(_open(widget.initialSource!));
    }
  }

  Future<void> _resolveLaunch(PlaybackLaunch launch) async {
    final generation = ++_resolveGeneration;
    _learningSubtitleRequest = null;
    _learningAutoAttempt = null;
    _activePlaybackGeneration = 0;
    setState(() {
      _launch = launch;
      _resolving = true;
      _resolveError = null;
      _resolveStatus = 'Connecting to ${_serviceTitle(launch.service)}…';
      _source = null;
    });
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
      if (mounted && generation == _resolveGeneration) {
        setState(() {
          _resolveStatus =
              'Resolving episode ${launch.episode} with ${_serviceTitle(launch.service)}…';
        });
      }
      requestPlayback(episode: launch.episode, mediaId: launch.media.id);
      final resolved = await client.resolve(
        key,
        launch.magnet,
        episode: launch.episode,
      );
      final source = _pickResolvedTarget(resolved, launch.episode);
      final probeTransport = ref.read(playbackProbeTransportProvider);
      if (probeTransport != null) {
        if (mounted && generation == _resolveGeneration) {
          setState(() {
            _resolveStatus = 'Checking stream health before opening MPV…';
          });
        }
        final verdict = await verifiedStream(
          source.url,
          transport: probeTransport,
        );
        if (!verdict.alive) {
          await client.forgetResolved(key, resolved.hash);
          throw DebridException(
            DebridErrorKind.unavailable,
            'The selected ${_serviceTitle(launch.service)} stream did not deliver media bytes. Retry for a fresh link or choose another release.',
          );
        }
      }
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _source = source;
        _resolving = false;
        _resolveStatus =
            'Opening secure ${_serviceTitle(launch.service)} stream…';
      });
      await _open(source);
    } on DebridException catch (error) {
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _resolving = false;
        _resolveStatus = null;
        _resolveError = error;
      });
    } catch (_) {
      if (!mounted || generation != _resolveGeneration) return;
      setState(() {
        _resolving = false;
        _resolveStatus = null;
        _resolveError = const DebridException(
          DebridErrorKind.service,
          'The release could not be prepared for playback.',
        );
      });
    }
  }

  Future<void> _retry() async {
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
    final opened = _engine.state
        .firstWhere(
          (snapshot) =>
              snapshot.phase == PlaybackPhase.ready ||
              snapshot.phase == PlaybackPhase.failed,
        )
        .timeout(const Duration(seconds: 30));
    try {
      await _engine.open(source);
      _activePlaybackGeneration = (await opened).generation;
      if (mounted) await _engine.play();
    } on PlaybackFailure {
      // The redacted failure is already represented in the state stream.
    }
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
          releaseName:
              _source?.torrentName ??
              _source?.name ??
              launch.media.title.display,
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

      final translationLanguage = _languageBase(
        settings.learningTranslationLanguage,
      );
      final translation = _latest.subtitleTracks
          .where(
            (track) =>
                !track.isBitmapSubtitle &&
                _languageBase(track.language) == translationLanguage,
          )
          .firstOrNull;
      if (translation != null) {
        await _engine.selectSubtitle(translation.id, secondary: true);
      }
      final japaneseAudio = _latest.audioTracks
          .where((track) => _languageBase(track.language) == 'ja')
          .firstOrNull;
      if (japaneseAudio != null && japaneseAudio.id != _latest.selectedAudio) {
        await _engine.selectAudio(japaneseAudio.id);
      }
      await _engine.addSubtitle(
        match.source,
        title: match.title,
        language: 'ja',
      );
      return _LearningSubtitleLoadResult.ready(
        'Japanese text attached from ${match.provider} and cached for this episode.',
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
      unawaited(_autoPrepareLearningTracks(snapshot, settings));
    });
  }

  Future<void> _autoPrepareLearningTracks(
    PlaybackSnapshot snapshot,
    Settings settings,
  ) async {
    final japaneseAudio = snapshot.audioTracks
        .where((track) => _languageBase(track.language) == 'ja')
        .firstOrNull;
    final textTracks = snapshot.subtitleTracks
        .where((track) => !track.isBitmapSubtitle)
        .toList();
    final japanese = textTracks
        .where((track) => _languageBase(track.language) == 'ja')
        .firstOrNull;
    final translation = textTracks
        .where(
          (track) =>
              track.id != japanese?.id &&
              _languageBase(track.language) ==
                  _languageBase(settings.learningTranslationLanguage),
        )
        .firstOrNull;
    try {
      if (japaneseAudio != null && japaneseAudio.id != snapshot.selectedAudio) {
        await _engine.selectAudio(japaneseAudio.id);
      }
      if (japanese != null) {
        await _engine.selectSubtitle(japanese.id);
        await _engine.selectSubtitle(translation?.id, secondary: true);
      } else if (settings.learningAutoFetchJapaneseSubtitles) {
        await _findJapaneseLearningSubtitle();
      }
    } on PlaybackFailure {
      // The visible subtitle panel remains the explicit retry surface.
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
    try {
      await _engine.pause();
    } on PlaybackFailure {
      // Resolution below will replace the current source either way.
    }
    if (!mounted) return;
    await _resolveLaunch(
      PlaybackLaunch(
        media: launch.media,
        episode: target,
        magnet: launch.magnet,
        service: launch.service,
      ),
    );
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
      _engine.setSubtitleDelay(_latest.primarySubtitleDelay + delta);

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
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
    return PopScope<Object?>(
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
                onAudio: (track) => _run(() => _engine.selectAudio(track)),
                onSubtitle: (track) =>
                    _run(() => _engine.selectSubtitle(track)),
                onSecondarySubtitle: (track) =>
                    _run(() => _engine.selectSubtitle(track, secondary: true)),
                onSubtitleRendering: (mode) {
                  _requestedSubtitleRendering = mode;
                  _run(() => _engine.setSubtitleRendering(mode));
                },
                onFindJapaneseSubtitle: _findJapaneseLearningSubtitle,
                onLearningLookup: () {
                  if (snapshot.phase == PlaybackPhase.playing ||
                      snapshot.phase == PlaybackPhase.buffering) {
                    _run(_engine.pause);
                  }
                },
                onSubtitleDelay: (delay, secondary) => _run(
                  () => _engine.setSubtitleDelay(delay, secondary: secondary),
                ),
                onAddSubtitle: (request) => _run(
                  () => _engine.addSubtitle(
                    request.source,
                    title: request.title,
                    language: request.language,
                  ),
                ),
                onToggleFit: _toggleFit,
              );
            },
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
    required this.onFindJapaneseSubtitle,
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
  final ValueChanged<SubtitleRendering> onSubtitleRendering;
  final Future<_LearningSubtitleLoadResult> Function() onFindJapaneseSubtitle;
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
            const Center(
              child: CircularProgressIndicator(
                color: ShiruTokens.highlight,
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
                    onFindJapaneseSubtitle: onFindJapaneseSubtitle,
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
        : ShiruTokens.motion;
    Widget animatedChrome({required Widget child, required Offset hidden}) {
      return IgnorePointer(
        ignoring: !_visible,
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : hidden,
          duration: duration,
          curve: ShiruTokens.easeSettle,
          child: AnimatedOpacity(
            key: ValueKey('player-chrome-${hidden.dy < 0 ? 'top' : 'bottom'}'),
            opacity: _visible ? 1 : 0,
            duration: duration,
            curve: ShiruTokens.easeSettle,
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
                const SizedBox(width: ShiruTokens.space3),
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
                  const SizedBox(width: ShiruTokens.space2),
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
                                ?.copyWith(color: ShiruTokens.textLight),
                          ),
                      ],
                    ),
                  ),
                  if (provider != null) ...[
                    const SizedBox(width: ShiruTokens.space3),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC202327),
                        border: Border.all(color: ShiruTokens.surfaceBorder),
                        borderRadius: BorderRadius.circular(
                          ShiruTokens.radiusPill,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: ShiruTokens.space3,
                          vertical: ShiruTokens.space1,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.cloud_outlined,
                              size: 16,
                              color: ShiruTokens.accentVeryLight,
                            ),
                            const SizedBox(width: ShiruTokens.space1),
                            Text(
                              provider!,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: ShiruTokens.space5),
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
                const ColoredBox(color: ShiruTokens.darkVeryDim),
          )
        else
          const ColoredBox(color: ShiruTokens.darkVeryDim),
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
            minimum: const EdgeInsets.all(ShiruTokens.space6),
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
                        const SizedBox(height: ShiruTokens.space5),
                        details,
                      ],
                    );
                  }
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: 210, child: cover),
                      const SizedBox(width: ShiruTokens.space5),
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
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
        border: Border.all(color: const Color(0x38FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0xA6000000),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusCard - 1),
        child: AspectRatio(
          aspectRatio: ShiruTokens.cardArtAspect,
          child: url == null
              ? const ColoredBox(color: ShiruTokens.darkVeryLight)
              : Image(
                  image: CachedNetworkImageProvider(url!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: ShiruTokens.darkVeryLight),
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
        const SizedBox(height: ShiruTokens.space2),
        Text(
          'Episode $episode',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: ShiruTokens.textLight),
        ),
        const SizedBox(height: ShiruTokens.space4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xD9090A0B),
            border: Border.all(color: ShiruTokens.surfaceBorder),
            borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ShiruTokens.space3,
              vertical: ShiruTokens.space2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: ShiruTokens.accentVeryLight,
                  ),
                ),
                const SizedBox(width: ShiruTokens.space2),
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
          const Icon(
            Icons.play_circle_outline_rounded,
            size: 52,
            color: ShiruTokens.textMuted,
          ),
          const SizedBox(height: ShiruTokens.space3),
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
            padding: const EdgeInsets.all(ShiruTokens.space6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 46,
                  color: ShiruTokens.errorVeryLight,
                ),
                const SizedBox(height: ShiruTokens.space4),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: ShiruTokens.space5),
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
    required this.onFindJapaneseSubtitle,
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
  final ValueChanged<SubtitleRendering> onSubtitleRendering;
  final Future<_LearningSubtitleLoadResult> Function() onFindJapaneseSubtitle;
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
            ShiruTokens.space5,
            42,
            ShiruTokens.space5,
            ShiruTokens.space4,
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
              const SizedBox(height: ShiruTokens.space2),
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
                      const SizedBox(width: ShiruTokens.space2),
                      Text(
                        '${_formatDuration(snapshot.position)} / '
                        '${_formatDuration(duration)}',
                        style: const TextStyle(
                          fontFamily: ShiruTokens.fontFamilyStats,
                          fontSize: ShiruTokens.fontSize12,
                          color: ShiruTokens.text,
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
                        onFindJapaneseSubtitle: onFindJapaneseSubtitle,
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

class _SeekBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final end = duration.inMilliseconds
        .toDouble()
        .clamp(1, double.infinity)
        .toDouble();
    final played = position.inMilliseconds.toDouble().clamp(0, end).toDouble();
    final loaded = buffered.inMilliseconds.toDouble().clamp(0, end) / end;
    return SizedBox(
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
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
              activeTrackColor: ShiruTokens.seekbarAccent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: ShiruTokens.seekbarAccent,
              overlayColor: const Color(0x33E5204C),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(
              value: played,
              max: end,
              onChanged: duration > Duration.zero
                  ? (value) => onSeek(Duration(milliseconds: value.round()))
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _LearningSubtitleOverlay extends ConsumerStatefulWidget {
  const _LearningSubtitleOverlay({
    required this.snapshot,
    required this.primary,
    required this.secondary,
    required this.settings,
    required this.onLookup,
  });

  final PlaybackSnapshot snapshot;
  final SubtitleCue? primary;
  final SubtitleCue? secondary;
  final Settings settings;
  final VoidCallback onLookup;

  @override
  ConsumerState<_LearningSubtitleOverlay> createState() =>
      _LearningSubtitleOverlayState();
}

class _LearningSubtitleOverlayState
    extends ConsumerState<_LearningSubtitleOverlay> {
  String? _analyzedCue;
  Future<List<LearningToken>>? _tokens;
  LearningToken? _selected;
  Future<List<LearningDefinition>>? _definitions;
  bool _pausedForCue = false;

  bool _visible(SubtitleCue? cue, Duration delay) {
    if (cue == null || cue.generation != widget.snapshot.generation) {
      return false;
    }
    final position = widget.snapshot.position - delay;
    if (position < cue.start) return false;
    return cue.end == null || position <= cue.end!;
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

  SubtitleCue? _translationCue(
    bool showPrimary,
    bool showSecondary,
    SubtitleCue? japanese,
  ) {
    final preferred = _languageBase(
      widget.settings.learningTranslationLanguage,
    );
    final candidates = <SubtitleCue>[
      if (showPrimary && widget.primary != null) widget.primary!,
      if (showSecondary && widget.secondary != null) widget.secondary!,
    ].where((cue) => cue.identity != japanese?.identity).toList();
    return candidates
            .where(
              (cue) => _languageBase(_trackFor(cue)?.language) == preferred,
            )
            .firstOrNull ??
        candidates.firstOrNull;
  }

  void _ensureAnalyzed(SubtitleCue cue) {
    if (_analyzedCue == cue.identity) return;
    _analyzedCue = cue.identity;
    _selected = null;
    _definitions = null;
    _pausedForCue = false;
    _tokens = ref
        .read(languageLearningToolsProvider)
        .tokenizeJapanese(cue.plainText);
  }

  void _lookup(LearningToken token) {
    if (!token.lookupable || token.key == _selected?.key) return;
    setState(() {
      _selected = token;
      _definitions = ref.read(languageLearningToolsProvider).lookup(token);
      if (widget.settings.learningPauseOnLookup && !_pausedForCue) {
        _pausedForCue = true;
        widget.onLookup();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final showPrimary = _visible(
      widget.primary,
      widget.snapshot.primarySubtitleDelay,
    );
    final showSecondary = _visible(
      widget.secondary,
      widget.snapshot.secondarySubtitleDelay,
    );
    if (!showPrimary && !showSecondary) return const SizedBox.shrink();
    final japanese = _japaneseCue(showPrimary, showSecondary);
    final translation = _translationCue(showPrimary, showSecondary, japanese);
    if (japanese != null) _ensureAnalyzed(japanese);
    final scale = widget.settings.learningSubtitleScale;
    return Align(
      alignment: const Alignment(0, 0.58),
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          ShiruTokens.space5,
          ShiruTokens.space6,
          ShiruTokens.space5,
          112,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 980,
              maxHeight: constraints.maxHeight,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xE6090A0B),
                border: Border.all(color: const Color(0x4D96B9FF)),
                borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
                boxShadow: const [
                  BoxShadow(color: Color(0xB3000000), blurRadius: 24),
                  BoxShadow(color: Color(0x182F75E4), blurRadius: 18),
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShiruTokens.space5,
                  vertical: ShiruTokens.space3,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (japanese == null)
                      _LearningNotice(
                        message: 'Choose a Japanese text subtitle track to make this line interactive. Bitmap subtitles need a text sidecar.',
                      )
                    else
                      FutureBuilder<List<LearningToken>>(
                        future: _tokens,
                        builder: (context, state) {
                          if (state.hasError) {
                            return Text(
                              japanese.plainText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 22 * scale,
                                color: ShiruTokens.highlight,
                              ),
                            );
                          }
                          final tokens = state.data;
                          if (tokens == null) {
                            return const Padding(
                              padding: EdgeInsets.all(ShiruTokens.space2),
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }
                          return Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.end,
                            spacing: 1,
                            runSpacing: ShiruTokens.space2,
                            children: [
                              for (final token in tokens)
                                _LearningWord(
                                  token: token,
                                  selected: token.key == _selected?.key,
                                  settings: widget.settings,
                                  scale: scale,
                                  onLookup: () => _lookup(token),
                                ),
                            ],
                          );
                        },
                      ),
                    if (translation != null &&
                        widget.settings.learningShowTranslation) ...[
                      const SizedBox(height: ShiruTokens.space2),
                      Text(
                        translation.plainText,
                        key: const ValueKey('learning-translation'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: ShiruTokens.fontFamilyStats,
                          fontSize: 16 * scale,
                          height: 1.25,
                          color: ShiruTokens.accentVeryLight,
                          shadows: const [
                            Shadow(color: Colors.black, blurRadius: 4),
                          ],
                        ),
                      ),
                    ],
                    if (_selected != null) ...[
                      const SizedBox(height: ShiruTokens.space3),
                      _DefinitionPanel(
                        token: _selected!,
                        definitions: _definitions,
                        status:
                            ref.watch(learningDictionaryStatusProvider).value ??
                            ref
                                .read(languageLearningToolsProvider)
                                .dictionaryStatus,
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
    required this.selected,
    required this.settings,
    required this.scale,
    required this.onLookup,
  });

  final LearningToken token;
  final bool selected;
  final Settings settings;
  final double scale;
  final VoidCallback onLookup;

  @override
  Widget build(BuildContext context) {
    final reading = token.reading;
    final showRuby =
        settings.learningShowFurigana &&
        settings.learningShowJapanese &&
        token.containsKanji &&
        reading != null;
    final showMain =
        settings.learningShowJapanese ||
        !settings.learningShowRomaji ||
        reading == null;
    final main = settings.learningShowJapanese
        ? token.surface
        : reading ?? token.surface;
    final content = AnimatedContainer(
      key: ValueKey('learning-token-${token.key}'),
      duration: ShiruTokens.motionQuick,
      padding: EdgeInsets.symmetric(
        horizontal: token.lookupable ? 4 : 0,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: selected ? const Color(0x593F8CFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        border: Border.all(
          color: selected ? ShiruTokens.accentVeryLight : Colors.transparent,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showRuby)
            Text(
              reading,
              style: TextStyle(
                fontFamily: ShiruTokens.fontFamilyStats,
                fontSize: 10 * scale,
                height: 1.05,
                color: ShiruTokens.accentVeryLight,
              ),
            ),
          if (showMain)
            Text(
              main,
              style: TextStyle(
                fontFamily: ShiruTokens.fontFamilyStats,
                fontSize: 22 * scale,
                fontWeight: FontWeight.w500,
                height: 1.15,
                color: selected
                    ? Colors.white
                    : token.lookupable
                    ? ShiruTokens.highlight
                    : ShiruTokens.textLight,
                shadows: const [Shadow(color: Colors.black, blurRadius: 5)],
              ),
            ),
          if (settings.learningShowRomaji && token.romanization != null)
            Text(
              token.romanization!,
              style: TextStyle(
                fontFamily: ShiruTokens.fontFamilyStats,
                fontSize: 9.5 * scale,
                height: 1.05,
                color: ShiruTokens.textLight,
              ),
            ),
        ],
      ),
    );
    if (!token.lookupable) return content;
    return Semantics(
      button: true,
      label: 'Look up ${token.surface}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onLookup(),
        child: GestureDetector(onTap: onLookup, child: content),
      ),
    );
  }
}

class _DefinitionPanel extends StatelessWidget {
  const _DefinitionPanel({
    required this.token,
    required this.definitions,
    required this.status,
  });

  final LearningToken token;
  final Future<List<LearningDefinition>>? definitions;
  final LearningDictionaryStatus? status;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      key: const ValueKey('learning-definition-panel'),
      duration: ShiruTokens.motionQuick,
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 210),
      padding: const EdgeInsets.all(ShiruTokens.space3),
      decoration: BoxDecoration(
        color: const Color(0xF51A1D20),
        border: Border.all(color: const Color(0x33FFFFFF)),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  token.baseForm ?? token.surface,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(color: ShiruTokens.highlight),
                ),
                if (token.reading != null)
                  Text(
                    [
                      token.reading!,
                      if (token.romanization != null) token.romanization!,
                    ].join('  ·  '),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: ShiruTokens.accentVeryLight),
                  ),
                if (token.partOfSpeech != null)
                  Text(
                    token.partOfSpeech!,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
          const SizedBox(width: ShiruTokens.space3),
          Expanded(
            flex: 5,
            child: status?.installed != true
                ? Text(
                    'Install JMdict in Settings → Learning for offline English definitions.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : FutureBuilder<List<LearningDefinition>>(
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
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final entry in entries.take(3))
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: ShiruTokens.space2,
                                ),
                                child: Text(
                                  entry.definitions.take(3).join(' · '),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LearningNotice extends StatelessWidget {
  const _LearningNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(
        Icons.subtitles_off_rounded,
        size: 18,
        color: ShiruTokens.warning,
      ),
      const SizedBox(width: ShiruTokens.space2),
      Flexible(
        child: Text(
          message,
          key: const ValueKey('learning-text-track-required'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}

class _LearningSubtitleLoadResult {
  const _LearningSubtitleLoadResult.ready(this.message) : ready = true;

  const _LearningSubtitleLoadResult.unavailable(this.message) : ready = false;

  final bool ready;
  final String message;
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
    required this.onFindJapaneseSubtitle,
    required this.onDelay,
    required this.onAddSubtitle,
  });

  final PlaybackSnapshot snapshot;
  final Stream<PlaybackSnapshot> snapshots;
  final Settings learningSettings;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onPrimary;
  final ValueChanged<String?> onSecondary;
  final ValueChanged<SubtitleRendering> onRendering;
  final Future<_LearningSubtitleLoadResult> Function() onFindJapaneseSubtitle;
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
          onFindJapaneseSubtitle: onFindJapaneseSubtitle,
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

class _SubtitlePanel extends StatefulWidget {
  const _SubtitlePanel({
    required this.snapshot,
    required this.snapshots,
    required this.learningSettings,
    required this.onAudio,
    required this.onPrimary,
    required this.onSecondary,
    required this.onRendering,
    required this.onFindJapaneseSubtitle,
    required this.onDelay,
    required this.onAddSubtitle,
  });

  final PlaybackSnapshot snapshot;
  final Stream<PlaybackSnapshot> snapshots;
  final Settings learningSettings;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onPrimary;
  final ValueChanged<String?> onSecondary;
  final ValueChanged<SubtitleRendering> onRendering;
  final Future<_LearningSubtitleLoadResult> Function() onFindJapaneseSubtitle;
  final void Function(Duration delay, bool secondary) onDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;

  @override
  State<_SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<_SubtitlePanel> {
  late final StreamSubscription<PlaybackSnapshot> _subscription;
  late PlaybackSnapshot _snapshot = widget.snapshot;
  late String? _primary = widget.snapshot.selectedPrimarySubtitle;
  late String? _secondary = widget.snapshot.selectedSecondarySubtitle;
  late SubtitleRendering _rendering = widget.snapshot.subtitleRendering;
  late Duration _primaryDelay = widget.snapshot.primarySubtitleDelay;
  late Duration _secondaryDelay = widget.snapshot.secondarySubtitleDelay;
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
    setState(() => _secondary = id);
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

  void _setRendering(SubtitleRendering mode) {
    _learningRequest++;
    setState(() {
      _rendering = mode;
      _learningWarning = null;
      _learningMessagePositive = false;
      _learningCanRetry = false;
    });
    widget.onRendering(mode);
    if (mode == SubtitleRendering.learning &&
        widget.learningSettings.learningAutoSelectTracks) {
      unawaited(_prepareLearningTracks());
    }
  }

  Future<void> _prepareLearningTracks() async {
    final request = ++_learningRequest;
    final warnings = <String>[];
    final japaneseAudio = _snapshot.audioTracks
        .where((track) => _languageBase(track.language) == 'ja')
        .firstOrNull;
    if (japaneseAudio != null && japaneseAudio.id != _snapshot.selectedAudio) {
      widget.onAudio(japaneseAudio.id);
    } else if (japaneseAudio == null &&
        _snapshot.audioTracks.any(
          (track) => _languageBase(track.language) != null,
        )) {
      warnings.add(
        'No Japanese audio track was found; the current audio stays selected.',
      );
    }

    final textTracks = _snapshot.subtitleTracks
        .where((track) => !track.isBitmapSubtitle)
        .toList();
    final japanese = textTracks
        .where((track) => _languageBase(track.language) == 'ja')
        .firstOrNull;
    final translationLanguage = _languageBase(
      widget.learningSettings.learningTranslationLanguage,
    );
    final translation = textTracks
        .where(
          (track) =>
              track.id != japanese?.id &&
              _languageBase(track.language) == translationLanguage,
        )
        .firstOrNull;
    if (japanese != null) {
      _selectPrimary(japanese.id);
      _selectSecondary(translation?.id);
      if (translation == null &&
          widget.learningSettings.learningShowTranslation) {
        warnings.add(
          'Japanese is ready. No matching ${_languageTitle(translationLanguage)} text track was found, so translation is hidden for this release.',
        );
      }
      if (warnings.isNotEmpty && mounted) {
        setState(() => _learningWarning = warnings.join(' '));
      }
      return;
    }

    if (!widget.learningSettings.learningAutoFetchJapaneseSubtitles) {
      warnings.add(
        'No Japanese text track is embedded. Automatic fetching is disabled; add a local ASS, SRT, or VTT sidecar.',
      );
      if (mounted) setState(() => _learningWarning = warnings.join(' '));
      return;
    }

    setState(() {
      _findingJapanese = true;
      _learningCanRetry = false;
      _learningWarning = [
        ...warnings,
        'Finding a Japanese text track for this episode…',
      ].join(' ');
    });
    final result = await widget.onFindJapaneseSubtitle();
    if (!mounted ||
        request != _learningRequest ||
        _rendering != SubtitleRendering.learning) {
      return;
    }
    setState(() {
      _findingJapanese = false;
      _learningMessagePositive = result.ready;
      _learningCanRetry = !result.ready;
      _learningWarning = [...warnings, result.message].join(' ');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820, maxHeight: 680),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShiruTokens.surfaceShell,
          border: Border.all(color: ShiruTokens.surfaceBorder),
          borderRadius: BorderRadius.circular(ShiruTokens.radiusSurfaceTop),
          boxShadow: const [
            BoxShadow(color: Color(0xD9000000), blurRadius: 36),
          ],
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ShiruTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.translate_rounded,
                    color: ShiruTokens.accentVeryLight,
                  ),
                  const SizedBox(width: ShiruTokens.space2),
                  Expanded(
                    child: Text(
                      'Subtitles & languages',
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
              const SizedBox(height: ShiruTokens.space4),
              Text('Display', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: ShiruTokens.space2),
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
              if (_learningWarning != null) ...[
                const SizedBox(height: ShiruTokens.space3),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: _learningMessagePositive
                        ? const Color(0x1F22C55E)
                        : const Color(0x2233AE17),
                    border: Border.all(
                      color: _learningMessagePositive
                          ? ShiruTokens.completed
                          : _findingJapanese
                          ? ShiruTokens.accentLight
                          : ShiruTokens.warning,
                    ),
                    borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(ShiruTokens.space3),
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
                                ? ShiruTokens.completed
                                : ShiruTokens.warning,
                            size: 19,
                          ),
                        const SizedBox(width: ShiruTokens.space2),
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
                                const SizedBox(width: ShiruTokens.space2),
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
              const SizedBox(height: ShiruTokens.space5),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 650;
                  final primary = _TrackSection(
                    title: 'Primary',
                    tracks: _snapshot.subtitleTracks,
                    selected: _primary,
                    onSelected: _selectPrimary,
                  );
                  final secondary = _TrackSection(
                    title: 'Secondary',
                    subtitle: 'Optional dual-language line',
                    tracks: _snapshot.subtitleTracks,
                    selected: _secondary,
                    onSelected: _selectSecondary,
                  );
                  if (compact) {
                    return Column(
                      children: [
                        primary,
                        const SizedBox(height: ShiruTokens.space4),
                        secondary,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: primary),
                      const SizedBox(width: ShiruTokens.space4),
                      Expanded(child: secondary),
                    ],
                  );
                },
              ),
              const SizedBox(height: ShiruTokens.space5),
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
              const SizedBox(height: ShiruTokens.space3),
              OutlinedButton.icon(
                onPressed: () async {
                  final request = await _showExternalSubtitleDialog(context);
                  if (request != null) widget.onAddSubtitle(request);
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add sidecar subtitle'),
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
    transitionDuration: reduceMotion ? Duration.zero : ShiruTokens.motion,
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      minimum: const EdgeInsets.all(ShiruTokens.space4),
      child: Center(child: panel),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: ShiruTokens.easeSettle,
        reverseCurve: ShiruTokens.easePress,
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

class _TrackSection extends StatelessWidget {
  const _TrackSection({
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShiruTokens.surfacePanel,
        border: Border.all(color: ShiruTokens.surfaceBorder),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null)
              Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: ShiruTokens.space2),
            _TrackOption(
              label: 'Off',
              selected: selected == null,
              onTap: () => onSelected(null),
            ),
            for (var index = 0; index < tracks.length; index++)
              _TrackOption(
                label: _trackLabel(tracks[index], index),
                detail: _trackDetail(tracks[index]),
                selected: selected == tracks[index].id,
                onTap: () => onSelected(tracks[index].id),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackOption extends StatelessWidget {
  const _TrackOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0x3D2F75E4) : Colors.transparent,
      borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ShiruTokens.space2,
            vertical: ShiruTokens.space2,
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: selected
                    ? ShiruTokens.accentVeryLight
                    : ShiruTokens.textMuted,
              ),
              const SizedBox(width: ShiruTokens.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    if (detail != null)
                      Text(
                        detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
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
      padding: const EdgeInsets.symmetric(vertical: ShiruTokens.space1),
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
                style: const TextStyle(fontFamily: ShiruTokens.fontFamilyStats),
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
              const SizedBox(height: ShiruTokens.space3),
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'Track name (optional)',
                  hintText: 'Full subtitles, signs & songs…',
                ),
              ),
              const SizedBox(height: ShiruTokens.space3),
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
        padding: const EdgeInsets.symmetric(horizontal: ShiruTokens.space2),
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
    'deu': 'de',
    'ger': 'de',
    'eng': 'en',
    'spa': 'es',
    'fra': 'fr',
    'fre': 'fr',
    'hin': 'hi',
    'ind': 'id',
    'ita': 'it',
    'jpn': 'ja',
    'kor': 'ko',
    'nld': 'nl',
    'dut': 'nl',
    'pol': 'pl',
    'por': 'pt',
    'rus': 'ru',
    'tha': 'th',
    'tur': 'tr',
    'ukr': 'uk',
    'vie': 'vi',
    'zho': 'zh',
    'chi': 'zh',
  };
  return iso3[base] ?? base;
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

String _serviceTitle(DebridService service) => switch (service) {
  DebridService.alldebrid => 'AllDebrid',
  DebridService.premiumize => 'Premiumize',
  DebridService.realdebrid => 'Real-Debrid',
  DebridService.torbox => 'TorBox',
};
