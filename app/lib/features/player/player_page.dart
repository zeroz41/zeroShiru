import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../application/playback/backend.dart';
import '../../application/playback/providers.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/media_engine.dart';

const _idleSnapshot = PlaybackSnapshot(
  generation: 0,
  phase: PlaybackPhase.idle,
);

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, this.initialSource});

  final PlayerFile? initialSource;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final PlaybackBackend _backend;
  late final Widget _surface;
  PlaybackSnapshot _latest = _idleSnapshot;
  BoxFit _fit = BoxFit.contain;
  double _lastAudibleVolume = 1;

  MediaEngine get _engine => _backend.engine;

  @override
  void initState() {
    super.initState();
    _backend = ref.read(playbackBackendProvider);
    _surface = _backend.buildSurface(
      key: const ValueKey('playback-surface'),
      fit: _fit,
    );
    if (widget.initialSource != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_open(widget.initialSource!));
      });
    }
  }

  @override
  void didUpdateWidget(PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSource != null &&
        oldWidget.initialSource?.url != widget.initialSource!.url) {
      unawaited(_open(widget.initialSource!));
    }
  }

  Future<void> _open(PlayerFile source) async {
    try {
      await _engine.open(source);
      if (mounted) await _engine.play();
    } on PlaybackFailure {
      // The redacted failure is already represented in the state stream.
    }
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

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      unawaited(_togglePlayback());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(const Duration(seconds: -2)));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(const Duration(seconds: 2)));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_engine.setVolume((_latest.volume + 0.05).clamp(0, 3)));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_engine.setVolume((_latest.volume - 0.05).clamp(0, 3)));
    } else if (key == LogicalKeyboardKey.keyM) {
      unawaited(_toggleMute());
    } else if (key == LogicalKeyboardKey.keyC) {
      unawaited(_cycleSubtitles());
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      unawaited(_engine.setSpeed((_latest.speed - 0.1).clamp(0.1, 16)));
    } else if (key == LogicalKeyboardKey.bracketRight) {
      unawaited(_engine.setSpeed((_latest.speed + 0.1).clamp(0.1, 16)));
    } else if (key == LogicalKeyboardKey.backslash) {
      unawaited(_engine.setSpeed(1));
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
              source: widget.initialSource,
              surface: _fit == BoxFit.contain
                  ? _surface
                  : _backend.buildSurface(
                      key: const ValueKey('playback-surface'),
                      fit: _fit,
                    ),
              fit: _fit,
              onBack: _leave,
              onRetry: widget.initialSource == null
                  ? null
                  : () => unawaited(_open(widget.initialSource!)),
              onTogglePlayback: () => unawaited(_togglePlayback()),
              onSeek: (position) => unawaited(_engine.seek(position)),
              onVolume: (volume) => unawaited(_engine.setVolume(volume)),
              onToggleMute: () => unawaited(_toggleMute()),
              onSpeed: (speed) => unawaited(_engine.setSpeed(speed)),
              onAudio: (track) => unawaited(_engine.selectAudio(track)),
              onSubtitle: (track) => unawaited(_engine.selectSubtitle(track)),
              onToggleFit: _toggleFit,
            );
          },
        ),
      ),
    );
  }
}

class _PlayerStage extends StatelessWidget {
  const _PlayerStage({
    required this.snapshot,
    required this.source,
    required this.surface,
    required this.fit,
    required this.onBack,
    required this.onRetry,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onSpeed,
    required this.onAudio,
    required this.onSubtitle,
    required this.onToggleFit,
  });

  final PlaybackSnapshot snapshot;
  final PlayerFile? source;
  final Widget surface;
  final BoxFit fit;
  final VoidCallback onBack;
  final VoidCallback? onRetry;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onSpeed;
  final ValueChanged<String?> onAudio;
  final ValueChanged<String?> onSubtitle;
  final VoidCallback onToggleFit;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          surface,
          if (source == null) const _IdlePlayer(),
          if (snapshot.phase == PlaybackPhase.failed)
            _PlayerFailure(error: snapshot.error, onRetry: onRetry),
          if (snapshot.phase
              case PlaybackPhase.opening || PlaybackPhase.buffering)
            const Center(
              child: CircularProgressIndicator(
                color: ShiruTokens.highlight,
                strokeWidth: 2,
              ),
            ),
          _TopChrome(title: source?.name, onBack: onBack),
          if (source != null && snapshot.phase != PlaybackPhase.failed)
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
                onToggleFit: onToggleFit,
              ),
            ),
        ],
      ),
    );
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({required this.title, required this.onBack});

  final String? title;
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
                    child: Text(
                      title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
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
                      if (snapshot.subtitleTracks.isNotEmpty)
                        _TrackMenu(
                          tooltip: 'Subtitles',
                          icon: snapshot.selectedPrimarySubtitle == null
                              ? Icons.subtitles_off_rounded
                              : Icons.subtitles_rounded,
                          tracks: snapshot.subtitleTracks,
                          selected: snapshot.selectedPrimarySubtitle,
                          includeOff: true,
                          onSelected: onSubtitle,
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
            child: Text(_trackLabel(tracks[index], index)),
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
    : track.language?.toUpperCase() ?? 'Track ${index + 1}';

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
