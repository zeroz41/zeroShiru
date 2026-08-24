import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../application/playback/backend.dart';
import '../../application/playback/probe.dart';
import '../../application/playback/providers.dart';
import '../../application/playback/request.dart';
import '../../application/settings/providers.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/debrid_client.dart';
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
  Object? _resolveError;
  String? _resolveStatus;
  bool _resolving = false;
  int _resolveGeneration = 0;
  BoxFit _fit = BoxFit.contain;
  double _lastAudibleVolume = 1;

  MediaEngine get _engine => _backend.engine;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
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
    setState(() {
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
    final launch = widget.initialLaunch;
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
    try {
      await _engine.open(source);
      if (mounted) await _engine.play();
    } on PlaybackFailure {
      // The redacted failure is already represented in the state stream.
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

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
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
    return Scaffold(
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
            return _PlayerStage(
              snapshot: snapshot,
              source: _source,
              launch: widget.initialLaunch,
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
              onBack: _leave,
              onRetry: _source == null && widget.initialLaunch == null
                  ? null
                  : () => unawaited(_retry()),
              onTogglePlayback: () => _run(_togglePlayback),
              onSeek: (position) => _run(() => _engine.seek(position)),
              onVolume: (volume) => _run(() => _engine.setVolume(volume)),
              onToggleMute: () => _run(_toggleMute),
              onSpeed: (speed) => _run(() => _engine.setSpeed(speed)),
              onAudio: (track) => _run(() => _engine.selectAudio(track)),
              onSubtitle: (track) => _run(() => _engine.selectSubtitle(track)),
              onSecondarySubtitle: (track) =>
                  _run(() => _engine.selectSubtitle(track, secondary: true)),
              onSubtitleRendering: (mode) =>
                  _run(() => _engine.setSubtitleRendering(mode)),
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
    );
  }

  @override
  void dispose() {
    _resolveGeneration++;
    unawaited(_primaryCueSubscription.cancel());
    unawaited(_secondaryCueSubscription.cancel());
    super.dispose();
  }
}

class _PlayerStage extends StatelessWidget {
  const _PlayerStage({
    required this.snapshot,
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
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onSpeed,
    required this.onAudio,
    required this.onSubtitle,
    required this.onSecondarySubtitle,
    required this.onSubtitleRendering,
    required this.onSubtitleDelay,
    required this.onAddSubtitle,
    required this.onToggleFit,
  });

  final PlaybackSnapshot snapshot;
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
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onSpeed;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onSubtitle;
  final ValueChanged<String?> onSecondarySubtitle;
  final ValueChanged<SubtitleRendering> onSubtitleRendering;
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
          surface,
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
          if (snapshot.subtitleRendering == SubtitleRendering.learning)
            _LearningSubtitleOverlay(
              snapshot: snapshot,
              primary: primaryCue,
              secondary: secondaryCue,
            ),
          _TopChrome(
            title: launch?.media.title.display ?? source?.name,
            subtitle: launch == null ? null : 'Episode ${launch!.episode}',
            provider: launch == null ? null : _serviceTitle(launch!.service),
            onBack: onBack,
          ),
          if (source != null &&
              !artworkLoading &&
              resolveError == null &&
              snapshot.phase != PlaybackPhase.failed)
            Align(
              alignment: Alignment.bottomCenter,
              child: _PlayerControls(
                snapshot: snapshot,
                fit: fit,
                onTogglePlayback: onTogglePlayback,
                onSeek: onSeek,
                onVolume: onVolume,
                onToggleMute: onToggleMute,
                onSpeed: onSpeed,
                onAudio: onAudio,
                onSubtitle: onSubtitle,
                onSecondarySubtitle: onSecondarySubtitle,
                onSubtitleRendering: onSubtitleRendering,
                onSubtitleDelay: onSubtitleDelay,
                onAddSubtitle: onAddSubtitle,
                onToggleFit: onToggleFit,
              ),
            ),
        ],
      ),
    );
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.title,
    required this.subtitle,
    required this.provider,
    required this.onBack,
  });

  final String? title;
  final String? subtitle;
  final String? provider;
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
                  tooltip: 'Back',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
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
    required this.fit,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onSpeed,
    required this.onAudio,
    required this.onSubtitle,
    required this.onSecondarySubtitle,
    required this.onSubtitleRendering,
    required this.onSubtitleDelay,
    required this.onAddSubtitle,
    required this.onToggleFit,
  });

  final PlaybackSnapshot snapshot;
  final BoxFit fit;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onSpeed;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onSubtitle;
  final ValueChanged<String?> onSecondarySubtitle;
  final ValueChanged<SubtitleRendering> onSubtitleRendering;
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
                      IconButton(
                        tooltip: _playing ? 'Pause' : 'Play',
                        onPressed: onTogglePlayback,
                        icon: Icon(
                          _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
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
                      if (!compact)
                        SizedBox(
                          width: 92,
                          child: Slider(
                            value: snapshot.volume.clamp(0, 1),
                            onChanged: onVolume,
                          ),
                        ),
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
                        onPrimary: onSubtitle,
                        onSecondary: onSecondarySubtitle,
                        onRendering: onSubtitleRendering,
                        onDelay: onSubtitleDelay,
                        onAddSubtitle: onAddSubtitle,
                      ),
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

class _LearningSubtitleOverlay extends StatelessWidget {
  const _LearningSubtitleOverlay({
    required this.snapshot,
    required this.primary,
    required this.secondary,
  });

  final PlaybackSnapshot snapshot;
  final SubtitleCue? primary;
  final SubtitleCue? secondary;

  bool _visible(SubtitleCue? cue, Duration delay) {
    if (cue == null || cue.generation != snapshot.generation) return false;
    final position = snapshot.position - delay;
    if (position < cue.start) return false;
    return cue.end == null || position <= cue.end!;
  }

  @override
  Widget build(BuildContext context) {
    final showPrimary = _visible(primary, snapshot.primarySubtitleDelay);
    final showSecondary = _visible(secondary, snapshot.secondarySubtitleDelay);
    if (!showPrimary && !showSecondary) return const SizedBox.shrink();
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, 0.68),
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: ShiruTokens.space6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xC9090A0B),
                border: Border.all(color: ShiruTokens.surfaceBorder),
                borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
                boxShadow: const [
                  BoxShadow(color: Color(0xA6000000), blurRadius: 18),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShiruTokens.space5,
                  vertical: ShiruTokens.space3,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showSecondary)
                      Text(
                        secondary!.plainText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: ShiruTokens.fontFamilyStats,
                          fontSize: 17,
                          height: 1.25,
                          color: ShiruTokens.accentVeryLight,
                          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                        ),
                      ),
                    if (showSecondary && showPrimary)
                      const SizedBox(height: ShiruTokens.space2),
                    if (showPrimary)
                      Text(
                        primary!.plainText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: ShiruTokens.fontFamilyStats,
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          color: ShiruTokens.highlight,
                          shadows: [Shadow(color: Colors.black, blurRadius: 5)],
                        ),
                      ),
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
    required this.onPrimary,
    required this.onSecondary,
    required this.onRendering,
    required this.onDelay,
    required this.onAddSubtitle,
  });

  final PlaybackSnapshot snapshot;
  final ValueChanged<String?> onPrimary;
  final ValueChanged<String?> onSecondary;
  final ValueChanged<SubtitleRendering> onRendering;
  final void Function(Duration delay, bool secondary) onDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Subtitles',
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0xB3000000),
        builder: (context) => _SubtitlePanel(
          snapshot: snapshot,
          onPrimary: onPrimary,
          onSecondary: onSecondary,
          onRendering: onRendering,
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
    required this.onPrimary,
    required this.onSecondary,
    required this.onRendering,
    required this.onDelay,
    required this.onAddSubtitle,
  });

  final PlaybackSnapshot snapshot;
  final ValueChanged<String?> onPrimary;
  final ValueChanged<String?> onSecondary;
  final ValueChanged<SubtitleRendering> onRendering;
  final void Function(Duration delay, bool secondary) onDelay;
  final ValueChanged<_ExternalSubtitleRequest> onAddSubtitle;

  @override
  State<_SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<_SubtitlePanel> {
  late String? _primary = widget.snapshot.selectedPrimarySubtitle;
  late String? _secondary = widget.snapshot.selectedSecondarySubtitle;
  late SubtitleRendering _rendering = widget.snapshot.subtitleRendering;
  late Duration _primaryDelay = widget.snapshot.primarySubtitleDelay;
  late Duration _secondaryDelay = widget.snapshot.secondarySubtitleDelay;

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

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 690),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShiruTokens.surfaceShell,
            border: Border.all(color: ShiruTokens.surfaceBorder),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(ShiruTokens.radiusSurfaceTop),
            ),
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
                  onSelectionChanged: (selection) {
                    final mode = selection.single;
                    setState(() => _rendering = mode);
                    widget.onRendering(mode);
                  },
                ),
                const SizedBox(height: ShiruTokens.space5),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 650;
                    final primary = _TrackSection(
                      title: 'Primary',
                      tracks: widget.snapshot.subtitleTracks,
                      selected: _primary,
                      onSelected: _selectPrimary,
                    );
                    final secondary = _TrackSection(
                      title: 'Secondary',
                      subtitle: 'Optional dual-language line',
                      tracks: widget.snapshot.subtitleTracks,
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
      ),
    );
  }
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
