import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../application/library/providers.dart';
import '../../application/playback/request.dart';
import '../../application/settings/providers.dart';
import '../../application/sources/best_source.dart';
import '../../application/sources/providers.dart';
import '../../application/sources/release_language.dart';
import '../../application/playback/coverage.dart';
import '../../domain/models/availability.dart';
import '../../domain/models/media.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/source_extension.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/debrid_client.dart';
import '../../domain/media/info_hash.dart';
import '../../domain/media/filename.dart';
import '../../domain/media/pack_picker.dart';
import 'episode_selector.dart';

typedef EpisodeSelected = void Function(Media media, int episode);

/// Opens the details experience over the current library page. The underlying
/// page remains mounted, while the details surface itself uses nearly the full
/// viewport instead of behaving like a small alert dialog.
Future<void> showMediaDetails(
  BuildContext context,
  Media media, {
  EpisodeSelected? onEpisodeSelected,
  int? initialEpisode,
}) async {
  var selectedEpisode = initialEpisode;
  while (true) {
    if (!context.mounted) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final launch = await showGeneralDialog<PlaybackLaunch>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close details',
      barrierColor: const Color(0xD9000000),
      transitionDuration: reduceMotion ? Duration.zero : ZeroTokens.motionPanel,
      pageBuilder: (context, animation, secondaryAnimation) => MediaDetails(
        media: media,
        initialEpisode: selectedEpisode,
        onEpisodeSelected: onEpisodeSelected,
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: ZeroTokens.easeSettle,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.025),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
    if (launch == null || !context.mounted) return;
    selectedEpisode = launch.episode;
    selectedEpisode =
        await context.push<int>('/player', extra: launch) ?? selectedEpisode;
  }
}

class MediaDetails extends ConsumerStatefulWidget {
  const MediaDetails({
    super.key,
    required this.media,
    this.initialEpisode,
    this.onEpisodeSelected,
  });

  final Media media;
  final int? initialEpisode;
  final EpisodeSelected? onEpisodeSelected;

  @override
  ConsumerState<MediaDetails> createState() => _MediaDetailsState();
}

class _MediaDetailsState extends ConsumerState<MediaDetails> {
  late int _episode;
  late final TextEditingController _magnet;
  final _sourcePickerKey = GlobalKey<_ReleaseHandoffState>();
  bool _releaseOpen = false;
  bool _findingBestSource = false;
  String? _playbackError;
  String? _releaseError;

  Media get media => widget.media;

  @override
  void initState() {
    super.initState();
    _episode = _requestedEpisode(media, widget.initialEpisode);
    _magnet = TextEditingController();
  }

  @override
  void didUpdateWidget(MediaDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != media.id ||
        oldWidget.initialEpisode != widget.initialEpisode) {
      _episode = _requestedEpisode(media, widget.initialEpisode);
      _releaseOpen = false;
      _findingBestSource = false;
      _playbackError = null;
      _releaseError = null;
      _magnet.clear();
    }
  }

  @override
  void dispose() {
    _magnet.dispose();
    super.dispose();
  }

  void _selectEpisode(int episode) {
    setState(() {
      _episode = episode;
      _playbackError = null;
      _releaseError = null;
    });
    widget.onEpisodeSelected?.call(media, episode);
  }

  void _playEpisode(int episode) {
    final selectionChanged = episode != _episode;
    if (selectionChanged) {
      setState(() {
        _episode = episode;
        _playbackError = null;
        _releaseError = null;
      });
    }
    if (widget.onEpisodeSelected case final callback?) {
      callback(media, episode);
      return;
    }
    if (!selectionChanged) {
      _sourcePickerKey.currentState?.playBest();
      return;
    }
    // Let the source engine receive the selected episode in didUpdateWidget
    // before asking it to resolve the best release.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _episode == episode) {
        _sourcePickerKey.currentState?.playBest();
      }
    });
  }

  void _watchNow() => _playEpisode(_episode);

  void _openReleases() {
    setState(() {
      _releaseOpen = true;
      _playbackError = null;
      _releaseError = null;
    });
  }

  void _closeReleases() {
    setState(() => _releaseOpen = false);
  }

  void _launch(Settings? settings, [_ReleaseChoice? selected]) {
    final service = settings?.debridService;
    final key = service == null ? null : settings?.debridApiKeys[service];
    if (service == null || key == null || key.isEmpty) {
      setState(() {
        _releaseError =
            'Connect a debrid service in Settings before starting playback.';
      });
      return;
    }
    final magnet = selected?.magnet.trim() ?? _magnet.text.trim();
    if (magnet.isEmpty) {
      setState(() {
        _releaseError = 'Paste a release magnet or info hash first.';
      });
      return;
    }
    Navigator.of(context).pop(
      PlaybackLaunch(
        media: media,
        episode: _episode,
        magnet: magnet,
        service: service,
        releaseEpisode: selected?.releaseEpisode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 900;
    final settings = ref.watch(settingsControllerProvider);
    final currentSettings = settings.value;
    final episodes =
        ref.watch(episodeMetadataProvider(media)).value ??
        fallbackEpisodeMetadata(media);
    final selectedEpisode = _episodeInfo(episodes, _episode, media);
    if (currentSettings != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sourcePickerKey.currentState?.prefetchBest();
      });
    }

    return SafeArea(
      minimum: EdgeInsets.all(compact ? 0 : ZeroTokens.space3),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1580, maxHeight: 1040),
          child: FractionallySizedBox(
            widthFactor: compact ? 1 : 0.985,
            heightFactor: compact ? 1 : 0.985,
            child: Material(
              color: context.zeroPalette.surfaceModal,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  compact ? 0 : ZeroTokens.radiusCard,
                ),
                side: compact
                    ? BorderSide.none
                    : BorderSide(color: context.zeroPalette.border),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _DetailsBackdrop(media: media, episode: selectedEpisode),
                  if (compact)
                    _CompactDetails(
                      media: media,
                      episode: _episode,
                      episodeInfo: selectedEpisode,
                      episodes: episodes,
                      findingBestSource: _findingBestSource,
                      playbackError: _playbackError,
                      onWatch: _watchNow,
                      onChooseSource: _openReleases,
                      onSelectEpisode: _selectEpisode,
                      onPlayEpisode: _playEpisode,
                    )
                  else
                    _DesktopDetails(
                      media: media,
                      episode: _episode,
                      episodeInfo: selectedEpisode,
                      episodes: episodes,
                      findingBestSource: _findingBestSource,
                      playbackError: _playbackError,
                      onWatch: _watchNow,
                      onChooseSource: _openReleases,
                      onSelectEpisode: _selectEpisode,
                      onPlayEpisode: _playEpisode,
                    ),
                  Positioned(
                    top: ZeroTokens.space3,
                    right: ZeroTokens.space3,
                    child: _CloseButton(
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Positioned.fill(
                    child: _SourcePickerOverlay(
                      visible: _releaseOpen,
                      compact: compact,
                      onDismiss: _closeReleases,
                      child: _ReleaseHandoff(
                        key: _sourcePickerKey,
                        media: media,
                        episode: _episode,
                        open: _releaseOpen,
                        error: _releaseError,
                        controller: _magnet,
                        settings: currentSettings,
                        onClose: _closeReleases,
                        onResolvingBest: (loading) {
                          if (!mounted || _findingBestSource == loading) return;
                          setState(() => _findingBestSource = loading);
                        },
                        onBestError: (error) {
                          if (!mounted || _playbackError == error) return;
                          setState(() => _playbackError = error);
                        },
                        onLaunch: (source) => _launch(currentSettings, source),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailsBackdrop extends StatelessWidget {
  const _DetailsBackdrop({required this.media, required this.episode});

  final Media media;
  final EpisodeInfo episode;

  @override
  Widget build(BuildContext context) {
    final image = episode.imageUrl ?? media.bannerImage ?? media.coverImage;
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 330,
            width: double.infinity,
            child: image == null
                ? ColoredBox(color: context.zeroPalette.backgroundTop)
                : Image(
                    image: CachedNetworkImageProvider(image),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        ColoredBox(color: context.zeroPalette.backgroundTop),
                  ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                context.zeroPalette.surfaceModal.withValues(alpha: 0.36),
                context.zeroPalette.surfaceModal.withValues(alpha: 0.85),
                context.zeroPalette.surfaceModal,
              ],
              stops: [0, 0.29, 0.55],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.85, -0.75),
              radius: 1.1,
              colors: [
                context.zeroPalette.accentDim.withValues(alpha: 0),
                context.zeroPalette.surfaceModal.withValues(alpha: 0.5),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopDetails extends StatelessWidget {
  const _DesktopDetails({
    required this.media,
    required this.episode,
    required this.episodeInfo,
    required this.episodes,
    required this.findingBestSource,
    required this.playbackError,
    required this.onWatch,
    required this.onChooseSource,
    required this.onSelectEpisode,
    required this.onPlayEpisode,
  });

  final Media media;
  final int episode;
  final EpisodeInfo episodeInfo;
  final List<EpisodeInfo> episodes;
  final bool findingBestSource;
  final String? playbackError;
  final VoidCallback onWatch;
  final VoidCallback onChooseSource;
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<int> onPlayEpisode;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 7,
          child: _OverviewScroll(
            media: media,
            episode: episode,
            episodeInfo: episodeInfo,
            findingBestSource: findingBestSource,
            playbackError: playbackError,
            onWatch: onWatch,
            onChooseSource: onChooseSource,
          ),
        ),
        const VerticalDivider(width: 1),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 410, maxWidth: 540),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ZeroTokens.space4,
              68,
              ZeroTokens.space4,
              ZeroTokens.space4,
            ),
            child: Column(
              children: [
                Expanded(
                  child: EpisodeSelector(
                    episodeCount: media.maxEpisode ?? 1,
                    watchedThrough: media.listEntry?.progress ?? 0,
                    selectedEpisode: episode,
                    fallbackArtwork: media.bannerImage ?? media.coverImage,
                    durationMinutes: media.duration,
                    items: episodes,
                    expanded: true,
                    onSelected: onSelectEpisode,
                    onPlay: onPlayEpisode,
                    playingEpisode: findingBestSource ? episode : null,
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

class _CompactDetails extends StatelessWidget {
  const _CompactDetails({
    required this.media,
    required this.episode,
    required this.episodeInfo,
    required this.episodes,
    required this.findingBestSource,
    required this.playbackError,
    required this.onWatch,
    required this.onChooseSource,
    required this.onSelectEpisode,
    required this.onPlayEpisode,
  });

  final Media media;
  final int episode;
  final EpisodeInfo episodeInfo;
  final List<EpisodeInfo> episodes;
  final bool findingBestSource;
  final String? playbackError;
  final VoidCallback onWatch;
  final VoidCallback onChooseSource;
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<int> onPlayEpisode;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        ZeroTokens.space4,
        120,
        ZeroTokens.space4,
        ZeroTokens.space6,
      ),
      children: [
        _OverviewHeader(
          media: media,
          episode: episode,
          episodeInfo: episodeInfo,
          compact: true,
          findingBestSource: findingBestSource,
          playbackError: playbackError,
          onWatch: onWatch,
          onChooseSource: onChooseSource,
        ),
        const SizedBox(height: ZeroTokens.space5),
        _AboutEpisode(episode: episodeInfo),
        if ((media.maxEpisode ?? 0) > 0) ...[
          const SizedBox(height: ZeroTokens.space5),
          EpisodeSelector(
            episodeCount: media.maxEpisode!,
            watchedThrough: media.listEntry?.progress ?? 0,
            selectedEpisode: episode,
            fallbackArtwork: media.bannerImage ?? media.coverImage,
            durationMinutes: media.duration,
            items: episodes,
            maxHeight: 610,
            onSelected: onSelectEpisode,
            onPlay: onPlayEpisode,
            playingEpisode: findingBestSource ? episode : null,
          ),
        ],
      ],
    );
  }
}

class _OverviewScroll extends StatelessWidget {
  const _OverviewScroll({
    required this.media,
    required this.episode,
    required this.episodeInfo,
    required this.findingBestSource,
    required this.playbackError,
    required this.onWatch,
    required this.onChooseSource,
  });

  final Media media;
  final int episode;
  final EpisodeInfo episodeInfo;
  final bool findingBestSource;
  final String? playbackError;
  final VoidCallback onWatch;
  final VoidCallback onChooseSource;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          ZeroTokens.space6,
          154,
          ZeroTokens.space6,
          ZeroTokens.space7,
        ),
        children: [
          _OverviewHeader(
            media: media,
            episode: episode,
            episodeInfo: episodeInfo,
            compact: false,
            findingBestSource: findingBestSource,
            playbackError: playbackError,
            onWatch: onWatch,
            onChooseSource: onChooseSource,
          ),
          const SizedBox(height: ZeroTokens.space6),
          _AboutEpisode(episode: episodeInfo),
        ],
      ),
    );
  }
}

class _OverviewHeader extends StatelessWidget {
  const _OverviewHeader({
    required this.media,
    required this.episode,
    required this.episodeInfo,
    required this.compact,
    required this.findingBestSource,
    required this.playbackError,
    required this.onWatch,
    required this.onChooseSource,
  });

  final Media media;
  final int episode;
  final EpisodeInfo episodeInfo;
  final bool compact;
  final bool findingBestSource;
  final String? playbackError;
  final VoidCallback onWatch;
  final VoidCallback onChooseSource;

  @override
  Widget build(BuildContext context) {
    final info = _TitleBlock(
      media: media,
      episode: episode,
      episodeInfo: episodeInfo,
      findingBestSource: findingBestSource,
      playbackError: playbackError,
      onWatch: onWatch,
      onChooseSource: onChooseSource,
    );
    if (compact) {
      return Column(
        children: [
          _EpisodeStill(media: media, episode: episodeInfo),
          const SizedBox(height: ZeroTokens.space4),
          info,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: 330,
          child: _EpisodeStill(media: media, episode: episodeInfo),
        ),
        const SizedBox(width: ZeroTokens.space5),
        Expanded(child: info),
      ],
    );
  }
}

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.media,
    required this.episode,
    required this.episodeInfo,
    required this.findingBestSource,
    required this.playbackError,
    required this.onWatch,
    required this.onChooseSource,
  });

  final Media media;
  final int episode;
  final EpisodeInfo episodeInfo;
  final bool findingBestSource;
  final String? playbackError;
  final VoidCallback onWatch;
  final VoidCallback onChooseSource;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          media.title.display,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: context.zeroPalette.accentSoft,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: ZeroTokens.space2),
        Text(
          episodeInfo.title?.trim().isNotEmpty == true
              ? episodeInfo.title!
              : 'Episode $episode',
          key: const ValueKey('selected-episode-title'),
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
            shadows: const [Shadow(color: Colors.black, blurRadius: 18)],
          ),
        ),
        const SizedBox(height: ZeroTokens.space3),
        Wrap(
          spacing: ZeroTokens.space4,
          runSpacing: ZeroTokens.space2,
          children: [
            _MetaItem(
              icon: Icons.movie_filter_outlined,
              label: 'Episode $episode',
            ),
            if (episodeInfo.durationMinutes != null)
              _MetaItem(
                icon: Icons.schedule_rounded,
                label: '${episodeInfo.durationMinutes} min',
              ),
            if (episodeInfo.airDate != null)
              _MetaItem(
                icon: Icons.calendar_month_rounded,
                label: _episodeDate(episodeInfo.airDate!),
              ),
            _MetaItem(
              icon: episode <= (media.listEntry?.progress ?? 0)
                  ? Icons.check_circle_rounded
                  : Icons.play_circle_outline_rounded,
              label: episode <= (media.listEntry?.progress ?? 0)
                  ? 'Watched'
                  : 'Unwatched',
            ),
          ],
        ),
        const SizedBox(height: ZeroTokens.space4),
        Wrap(
          spacing: ZeroTokens.space2,
          runSpacing: ZeroTokens.space2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const ValueKey('watch-now'),
              onPressed: findingBestSource ? null : onWatch,
              icon: findingBestSource
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(
                findingBestSource ? 'Finding best source…' : 'Play episode',
              ),
              style: FilledButton.styleFrom(minimumSize: const Size(214, 44)),
            ),
            OutlinedButton.icon(
              key: const ValueKey('choose-source'),
              onPressed: findingBestSource ? null : onChooseSource,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Choose source'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(154, 44)),
            ),
            if (media.listEntry case final entry?) _StatusPill(entry: entry),
          ],
        ),
        const SizedBox(height: ZeroTokens.space2),
        _AutoSourceHint(error: playbackError),
      ],
    );
  }
}

class _AboutEpisode extends StatelessWidget {
  const _AboutEpisode({required this.episode});

  final EpisodeInfo episode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(label: 'About this episode'),
        const SizedBox(height: ZeroTokens.space4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Text(
            episode.summary?.trim().isNotEmpty == true
                ? episode.summary!
                : 'No episode synopsis is available yet.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              height: 1.6,
              color: context.zeroPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _AutoSourceHint extends StatelessWidget {
  const _AutoSourceHint({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final hasError = error?.isNotEmpty == true;
    return AnimatedSwitcher(
      duration: ZeroTokens.motion,
      child: Row(
        key: ValueKey(hasError ? error : 'automatic-source-hint'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasError ? Icons.error_outline_rounded : Icons.auto_awesome_rounded,
            size: 15,
            color: hasError
                ? context.zeroPalette.warning
                : context.zeroPalette.textMuted,
          ),
          const SizedBox(width: ZeroTokens.space1),
          Flexible(
            child: Text(
              hasError ? error! : 'Best source is preloaded using cache, language, resolution, and swarm health.',
              key: hasError ? const ValueKey('best-source-error') : null,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: hasError
                    ? context.zeroPalette.warning
                    : context.zeroPalette.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps source choice out of the browsing layout while preserving the source
/// engine's state for instant play. On wide screens it reads as a side sheet;
/// on compact screens it becomes a nearly full-height modal sheet.
class _SourcePickerOverlay extends StatelessWidget {
  const _SourcePickerOverlay({
    required this.visible,
    required this.compact,
    required this.onDismiss,
    required this.child,
  });

  final bool visible;
  final bool compact;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final alignment = compact ? Alignment.bottomCenter : Alignment.centerRight;
    final padding = compact
        ? const EdgeInsets.fromLTRB(
            ZeroTokens.space2,
            72,
            ZeroTokens.space2,
            ZeroTokens.space2,
          )
        : const EdgeInsets.fromLTRB(
            80,
            54,
            ZeroTokens.space4,
            ZeroTokens.space4,
          );
    return Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      child: ExcludeSemantics(
        excluding: !visible,
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: ZeroTokens.motionPanel,
            curve: ZeroTokens.easeSettle,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Semantics(
                  button: true,
                  label: 'Close source picker',
                  child: GestureDetector(
                    key: const ValueKey('source-picker-scrim'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onDismiss,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.66),
                    ),
                  ),
                ),
                Align(
                  alignment: alignment,
                  child: Padding(
                    padding: padding,
                    child: AnimatedSlide(
                      offset: visible
                          ? Offset.zero
                          : Offset(compact ? 0 : 0.06, compact ? 0.06 : 0),
                      duration: ZeroTokens.motionPanel,
                      curve: ZeroTokens.easeSettle,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: compact ? 680 : 590,
                          maxHeight: compact ? 760 : 860,
                        ),
                        child: SizedBox(width: double.infinity, child: child),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReleaseChoice {
  const _ReleaseChoice(this.magnet, {this.releaseEpisode});

  final String magnet;
  final int? releaseEpisode;
}

class _SourceRequestKey {
  const _SourceRequestKey({
    required this.mediaId,
    required this.episode,
    required this.resolution,
    required this.service,
    required this.credentialFingerprint,
    required this.resolverIdentity,
  });

  final int mediaId;
  final int episode;
  final String resolution;
  final DebridService? service;
  final int credentialFingerprint;
  final int resolverIdentity;

  @override
  bool operator ==(Object other) =>
      other is _SourceRequestKey &&
      other.mediaId == mediaId &&
      other.episode == episode &&
      other.resolution == resolution &&
      other.service == service &&
      other.credentialFingerprint == credentialFingerprint &&
      other.resolverIdentity == resolverIdentity;

  @override
  int get hashCode => Object.hash(
    mediaId,
    episode,
    resolution,
    service,
    credentialFingerprint,
    resolverIdentity,
  );
}

class _SourceSnapshot {
  _SourceSnapshot({
    required this.createdAt,
    required this.results,
    required this.availability,
    required this.availabilityDetails,
    required this.releaseEpisodes,
    required this.rejectedHashes,
    required this.sourceErrors,
  });

  final DateTime createdAt;
  final List<TorrentResult> results;
  final Map<String, Availability> availability;
  final Map<String, DebridAvailabilityDetail> availabilityDetails;
  final Map<String, int> releaseEpisodes;
  final Set<String> rejectedHashes;
  final List<String> sourceErrors;

  bool get isFresh =>
      DateTime.now().difference(createdAt) < const Duration(minutes: 5);
}

class _ReleaseHandoff extends ConsumerStatefulWidget {
  const _ReleaseHandoff({
    super.key,
    required this.media,
    required this.episode,
    required this.open,
    required this.error,
    required this.controller,
    required this.settings,
    required this.onClose,
    required this.onResolvingBest,
    required this.onBestError,
    required this.onLaunch,
  });

  final Media media;
  final int episode;
  final bool open;
  final String? error;
  final TextEditingController controller;
  final Settings? settings;
  final VoidCallback onClose;
  final ValueChanged<bool> onResolvingBest;
  final ValueChanged<String?> onBestError;
  final ValueChanged<_ReleaseChoice> onLaunch;

  @override
  ConsumerState<_ReleaseHandoff> createState() => _ReleaseHandoffState();
}

enum _ReleaseSort { best, seeders, quality, size }

class _ReleaseHandoffState extends ConsumerState<_ReleaseHandoff> {
  static const _snapshotLimit = 8;
  static final _snapshots = <_SourceRequestKey, _SourceSnapshot>{};

  StreamSubscription<SourceSearchBatch>? _subscription;
  Timer? _availabilityTimer;
  final _results = <TorrentResult>[];
  final _availability = <String, Availability>{};
  final _availabilityDetails = <String, DebridAvailabilityDetail>{};
  final _releaseEpisodes = <String, int>{};
  final _rejectedHashes = <String>{};
  final _checked = <String>{};
  final _sourceErrors = <String>[];
  bool _loading = false;
  bool _manual = false;
  bool _cachedOnly = false;
  bool _quickPlayPending = false;
  bool _searchCompleted = false;
  _SourceRequestKey? _activeRequest;
  _ReleaseSort _sort = _ReleaseSort.best;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.open) prefetchBest();
  }

  @override
  void didUpdateWidget(_ReleaseHandoff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episode != widget.episode ||
        oldWidget.media.id != widget.media.id) {
      prefetchBest();
    } else if (widget.open && !oldWidget.open) {
      prefetchBest();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _availabilityTimer?.cancel();
    super.dispose();
  }

  void playBest() {
    final settings =
        ref.read(settingsControllerProvider).value ?? widget.settings;
    final service = settings?.debridService;
    if (service == null || settings?.activeDebridKey?.isNotEmpty != true) {
      widget.onBestError(
        'Connect a debrid service in Settings before starting playback.',
      );
      widget.onResolvingBest(false);
      return;
    }
    if (ref.read(sourceResolverProvider) == null) {
      widget.onBestError(
        'Install and enable a source extension in Settings first.',
      );
      widget.onResolvingBest(false);
      return;
    }
    _quickPlayPending = true;
    widget.onBestError(null);
    widget.onResolvingBest(true);
    final request = _requestKey();
    if (_activeRequest == request && _searchCompleted) {
      _launchBest();
      return;
    }
    if (_restoreSnapshot(request)) {
      _launchBest();
      return;
    }
    if (_activeRequest == request && _loading) return;
    unawaited(_search());
  }

  /// Warms the exact same result set consumed by [playBest] without changing
  /// the visible UI. Repeated calls for the same episode are free.
  void prefetchBest() {
    if (ref.read(sourceResolverProvider) == null) return;
    final request = _requestKey();
    if (_activeRequest == request && (_loading || _searchCompleted)) return;
    if (_restoreSnapshot(request)) return;
    unawaited(_search());
  }

  _SourceRequestKey _requestKey() {
    final settings =
        ref.read(settingsControllerProvider).value ??
        widget.settings ??
        const Settings();
    final resolver = ref.read(sourceResolverProvider);
    final credential = settings.activeDebridKey;
    return _SourceRequestKey(
      mediaId: widget.media.id,
      episode: widget.episode,
      resolution: settings.rssQuality,
      service: settings.debridService,
      credentialFingerprint: credential == null
          ? 0
          : Object.hash(credential.length, credential.hashCode),
      resolverIdentity: identityHashCode(resolver),
    );
  }

  Future<void> _search({bool force = false}) async {
    final resolver = ref.read(sourceResolverProvider);
    final searchSettings =
        ref.read(settingsControllerProvider).value ?? widget.settings;
    final request = _requestKey();
    if (!force) {
      if (_activeRequest == request && (_loading || _searchCompleted)) return;
      if (_restoreSnapshot(request)) return;
    }
    final generation = ++_generation;
    // Claim the request before cancellation yields so selection, picker-open,
    // and play callbacks in the same frame all join this one search.
    _activeRequest = request;
    _searchCompleted = false;
    _loading = resolver != null;
    await _subscription?.cancel();
    _availabilityTimer?.cancel();
    if (!mounted || generation != _generation) return;
    setState(() {
      _results.clear();
      _availability.clear();
      _availabilityDetails.clear();
      _releaseEpisodes.clear();
      _rejectedHashes.clear();
      _checked.clear();
      _sourceErrors.clear();
      _manual = false;
    });
    if (resolver == null) {
      _finishQuickPlayWithError(
        'Install and enable a source extension in Settings first.',
      );
      return;
    }
    final titles = {
      widget.media.title.userPreferred,
      widget.media.title.romaji,
      widget.media.title.english,
      widget.media.title.native,
      ...widget.media.synonyms,
    }.whereType<String>().where((item) => item.trim().isNotEmpty).toList();
    final stream = resolver.search(
      TorrentQuery(
        anilistId: widget.media.id,
        idMal: widget.media.idMal,
        titles: titles.isEmpty ? [widget.media.title.display] : titles,
        episode: widget.episode,
        episodeCount: widget.media.maxEpisode,
        resolution: searchSettings?.rssQuality ?? '',
        exclusions: const [],
      ),
      movie: widget.media.format == MediaFormat.movie,
    );
    _subscription = stream.listen(
      (batch) {
        if (!mounted || generation != _generation) return;
        final existing = {for (final item in _results) ?_hashOf(item)};
        final additions = batch.results.where((item) {
          final hash = _hashOf(item);
          if (hash == null) return false;
          if (!_holdsEpisode(item)) return false;
          return existing.add(hash);
        });
        setState(() {
          _results.addAll(additions);
          if (batch.error != null) {
            _sourceErrors.add('${batch.source.name}: ${batch.error}');
          }
        });
      },
      onDone: () async {
        if (!mounted || generation != _generation) return;
        _subscription = null;
        setState(() => _loading = false);
        _availabilityTimer?.cancel();
        await _checkAvailability(generation);
        if (!mounted || generation != _generation) return;
        setState(() => _searchCompleted = true);
        _saveSnapshot(request);
        if (_quickPlayPending) {
          _launchBest();
        }
      },
      onError: (Object error) {
        if (!mounted || generation != _generation) return;
        _subscription = null;
        setState(() {
          _loading = false;
          _searchCompleted = true;
          _sourceErrors.add('$error');
        });
        _saveSnapshot(request);
        _finishQuickPlayWithError('Sources could not be searched. Try again.');
      },
    );
  }

  bool _restoreSnapshot(_SourceRequestKey request) {
    final snapshot = _snapshots[request];
    if (snapshot == null) return false;
    if (!snapshot.isFresh) {
      _snapshots.remove(request);
      return false;
    }
    setState(() {
      _activeRequest = request;
      _searchCompleted = true;
      _loading = false;
      _manual = false;
      _results
        ..clear()
        ..addAll(snapshot.results);
      _availability
        ..clear()
        ..addAll(snapshot.availability);
      _availabilityDetails
        ..clear()
        ..addAll(snapshot.availabilityDetails);
      _releaseEpisodes
        ..clear()
        ..addAll(snapshot.releaseEpisodes);
      _rejectedHashes
        ..clear()
        ..addAll(snapshot.rejectedHashes);
      _checked
        ..clear()
        ..addAll(snapshot.availability.keys);
      _sourceErrors
        ..clear()
        ..addAll(snapshot.sourceErrors);
    });
    return true;
  }

  void _saveSnapshot(_SourceRequestKey request) {
    _snapshots.remove(request);
    _snapshots[request] = _SourceSnapshot(
      createdAt: DateTime.now(),
      results: List.unmodifiable(_results),
      availability: Map.unmodifiable(_availability),
      availabilityDetails: Map.unmodifiable(_availabilityDetails),
      releaseEpisodes: Map.unmodifiable(_releaseEpisodes),
      rejectedHashes: Set.unmodifiable(_rejectedHashes),
      sourceErrors: List.unmodifiable(_sourceErrors),
    );
    while (_snapshots.length > _snapshotLimit) {
      _snapshots.remove(_snapshots.keys.first);
    }
  }

  void _launchBest() {
    final results = _rankedFor(_ReleaseSort.best);
    if (results.isEmpty) {
      _finishQuickPlayWithError(
        _sourceErrors.isEmpty
            ? 'No playable source was found. You can choose one manually.'
            : 'No playable source was found this time. Try choosing a source.',
      );
      return;
    }
    final result = results.first;
    final hash = _hashOf(result);
    final magnet = validatedTorrentMagnet(
      declaredHash: result.hash,
      link: result.link,
    );
    if (magnet == null) {
      _finishQuickPlayWithError('The best source did not have a valid magnet.');
      return;
    }
    _quickPlayPending = false;
    widget.onResolvingBest(false);
    widget.onBestError(null);
    widget.onLaunch(
      _ReleaseChoice(
        magnet,
        releaseEpisode: hash == null
            ? _titleEpisode(result)
            : _releaseEpisodes[hash] ?? _titleEpisode(result),
      ),
    );
  }

  void _finishQuickPlayWithError(String message) {
    if (!_quickPlayPending) return;
    _quickPlayPending = false;
    widget.onResolvingBest(false);
    widget.onBestError(message);
  }

  bool _holdsEpisode(TorrentResult result) => releaseHoldsEpisode(
    parseFilename(result.title),
    episode: widget.episode,
    absoluteEpisode: result.mappedEpisode,
    episodeCount: widget.media.maxEpisode,
  );

  String? _hashOf(TorrentResult result) =>
      validatedTorrentHash(declaredHash: result.hash, link: result.link);

  int? _titleEpisode(TorrentResult result) => releaseEpisodeFor(
    parseFilename(result.title),
    episode: widget.episode,
    absoluteEpisode: result.mappedEpisode,
  )?.round();

  void _scheduleAvailability(int generation, {bool immediate = false}) {
    final settings = widget.settings;
    final needsFileInspection = settings?.debridService == DebridService.torbox;
    if ((!needsFileInspection &&
            !_cachedOnly &&
            settings?.debridCacheCheck != true &&
            settings?.debridCachedOnly != true) ||
        settings?.debridService == null ||
        settings?.activeDebridKey?.isNotEmpty != true) {
      return;
    }
    _availabilityTimer?.cancel();
    _availabilityTimer = Timer(
      immediate || _checked.isEmpty
          ? Duration.zero
          : const Duration(milliseconds: 45),
      () => unawaited(_checkAvailability(generation)),
    );
  }

  Future<void> _checkAvailability(int generation) async {
    final settings = widget.settings;
    final service = settings?.debridService;
    final key = settings?.activeDebridKey;
    if (service == null || key == null || key.isEmpty) return;
    final client = ref.read(debridClientsProvider)[service];
    if (client == null) return;
    final hashes = <String>[];
    for (final result in _results) {
      final hash = _hashOf(result);
      if (hash != null && _checked.add(hash)) hashes.add(hash);
    }
    if (hashes.isEmpty) return;
    try {
      final answers = await client.inspectAvailability(key, hashes);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final hash in hashes) {
          final detail = answers[hash];
          _availability[hash] = detail?.availability ?? Availability.unknown;
          if (detail == null) continue;
          _availabilityDetails[hash] = detail;
          final result = _results
              .where((item) => _hashOf(item) == hash)
              .firstOrNull;
          if (result == null) continue;
          final releaseEpisode = _episodeFromFiles(result, detail.files);
          if (releaseEpisode != null) {
            _releaseEpisodes[hash] = releaseEpisode;
          } else if (detail.availability == Availability.cached &&
              detail.files != null) {
            _rejectedHashes.add(hash);
          }
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _sourceErrors.add('Cache check: $error'));
    }
  }

  int? _episodeFromFiles(TorrentResult result, List<DebridCachedFile>? files) {
    if (files == null) return _titleEpisode(result);
    final candidates = [
      for (final file in files) PackFile(file.path, file.size),
    ];
    if (!candidates.any((file) => isVideoPath(file.path))) return null;
    final episodes = <int>[
      widget.episode,
      if (result.mappedEpisode != null &&
          result.mappedEpisode != widget.episode)
        result.mappedEpisode!,
    ];
    for (final episode in episodes) {
      try {
        final picked = pickEpisodeFile(
          candidates,
          episode.toDouble(),
          parseNames,
        );
        if (picked != null && isVideoPath(candidates[picked].path)) {
          return episode;
        }
      } on EpisodeSelectionFailure {
        // Try the mapped numbering before declaring this batch unusable.
      }
    }
    return null;
  }

  List<TorrentResult> get _ranked => _rankedFor(_sort);

  List<TorrentResult> _rankedFor(_ReleaseSort sort) {
    final values = _results.where((item) {
      if (!_canShow(item)) return false;
      if (!_cachedOnly && widget.settings?.debridCachedOnly != true) {
        return true;
      }
      final hash = _hashOf(item);
      final state = availabilityOf(_availability, hash);
      return state == Availability.cached || !_availability.containsKey(hash);
    }).toList();
    final preferences =
        ref.read(settingsControllerProvider).value ??
        widget.settings ??
        const Settings();
    if (sort == _ReleaseSort.best) {
      return rankBestSources(
        values,
        preferences: preferences,
        availability: (result) =>
            availabilityOf(_availability, _hashOf(result)),
      );
    }
    values.sort(
      (a, b) => switch (sort) {
        _ReleaseSort.seeders => (b.seeders ?? 0).compareTo(a.seeders ?? 0),
        _ReleaseSort.quality => sourceQuality(
          b.title,
        ).compareTo(sourceQuality(a.title)),
        _ReleaseSort.size => (b.size ?? 0).compareTo(a.size ?? 0),
        _ReleaseSort.best => 0,
      },
    );
    return values;
  }

  bool _canShow(TorrentResult result) {
    final hash = _hashOf(result);
    if (hash == null || _rejectedHashes.contains(hash)) return false;
    final settings = widget.settings;
    final inspectingWithTorBox =
        settings?.debridService == DebridService.torbox &&
        settings?.activeDebridKey?.isNotEmpty == true;
    if (inspectingWithTorBox) {
      final detail = _availabilityDetails[hash];
      if (detail == null) return false;
      if (detail.availability == Availability.cached && detail.files != null) {
        return _releaseEpisodes.containsKey(hash);
      }
    }
    return _titleEpisode(result) != null ||
        widget.media.format == MediaFormat.movie ||
        widget.media.maxEpisode == 1;
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final service = settings?.debridService;
    final connected =
        service != null && (settings?.activeDebridKey?.isNotEmpty ?? false);
    final provider = service == null ? 'TorBox' : _serviceTitle(service);
    final results = _ranked;
    return Container(
      key: const ValueKey('release-handoff'),
      width: double.infinity,
      padding: const EdgeInsets.all(ZeroTokens.space3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [context.zeroPalette.surface, context.zeroPalette.shell],
        ),
        border: Border.all(
          color: widget.open
              ? context.zeroPalette.accentHover.withValues(alpha: 0.4)
              : context.zeroPalette.border,
        ),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
      ),
      child: Column(
        mainAxisSize: widget.open ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SourceCloudIcon(),
              const SizedBox(width: ZeroTokens.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose a source',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      connected
                          ? widget.open
                                ? _loading
                                      ? '$provider · Episode ${widget.episode} · Searching…'
                                      : '$provider · Episode ${widget.episode} · ${results.length} playable'
                                : 'Automatic source engine ready'
                          : 'Connect a debrid service in Settings to play',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: connected
                            ? context.zeroPalette.success
                            : context.zeroPalette.warning,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.open)
                IconButton(
                  tooltip: 'Refresh sources',
                  onPressed: _loading ? null : () => _search(force: true),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              if (widget.open)
                IconButton(
                  key: const ValueKey('close-source-results'),
                  tooltip: 'Collapse sources',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                ),
              _ConnectionDot(connected: connected),
            ],
          ),
          if (widget.open) ...[
            const SizedBox(height: ZeroTokens.space2),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: ZeroTokens.space2),
            _SourceToolbar(
              sort: _sort,
              cachedOnly: _cachedOnly || settings?.debridCachedOnly == true,
              cachedLocked: settings?.debridCachedOnly == true,
              onSort: (value) => setState(() => _sort = value),
              onCachedOnly: (value) {
                setState(() => _cachedOnly = value);
                if (value) {
                  _scheduleAvailability(_generation, immediate: true);
                }
              },
            ),
            const SizedBox(height: ZeroTokens.space2),
            Expanded(
              child: _manual
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.only(right: ZeroTokens.space1),
                      child: _ManualRelease(
                        controller: widget.controller,
                        error: widget.error,
                        connected: connected,
                        provider: provider,
                        onLaunch: () => widget.onLaunch(
                          _ReleaseChoice(widget.controller.text),
                        ),
                      ),
                    )
                  : results.isEmpty
                  ? _EmptyReleaseResults(
                      loading: _loading,
                      hasErrors: _sourceErrors.isNotEmpty,
                      onManual: () => setState(() => _manual = true),
                    )
                  : ListView.separated(
                      key: const ValueKey('source-results'),
                      itemCount: results.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: ZeroTokens.space2),
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final hash = _hashOf(result);
                        final magnet = validatedTorrentMagnet(
                          declaredHash: result.hash,
                          link: result.link,
                        )!;
                        return _ReleaseResultTile(
                          result: result,
                          availability: availabilityOf(_availability, hash),
                          checking:
                              hash != null &&
                              (settings?.debridCacheCheck == true ||
                                  settings?.debridCachedOnly == true ||
                                  _cachedOnly) &&
                              !_availability.containsKey(hash),
                          connected: connected,
                          provider: provider,
                          onPlay: () => widget.onLaunch(
                            _ReleaseChoice(
                              magnet,
                              releaseEpisode: hash == null
                                  ? _titleEpisode(result)
                                  : _releaseEpisodes[hash] ??
                                        _titleEpisode(result),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_sourceErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: ZeroTokens.space2),
                child: Text(
                  '${_sourceErrors.length} source operation${_sourceErrors.length == 1 ? '' : 's'} failed; other results remain available.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.zeroPalette.warning),
                ),
              ),
            TextButton.icon(
              key: const ValueKey('manual-release-toggle'),
              onPressed: () => setState(() => _manual = !_manual),
              icon: const Icon(Icons.link_rounded, size: 18),
              label: Text(
                _manual ? 'Hide manual link' : 'Use magnet or info hash',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceToolbar extends StatelessWidget {
  const _SourceToolbar({
    required this.sort,
    required this.cachedOnly,
    required this.cachedLocked,
    required this.onSort,
    required this.onCachedOnly,
  });

  final _ReleaseSort sort;
  final bool cachedOnly;
  final bool cachedLocked;
  final ValueChanged<_ReleaseSort> onSort;
  final ValueChanged<bool> onCachedOnly;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        FilterChip(
          key: const ValueKey('cached-source-filter'),
          selected: cachedOnly,
          onSelected: cachedLocked ? null : onCachedOnly,
          avatar: const Icon(Icons.bolt_rounded, size: 16),
          label: const Text('Cached only'),
        ),
        const Spacer(),
        Text(
          'Sort',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: context.zeroPalette.textMuted),
        ),
        const SizedBox(width: ZeroTokens.space1),
        PopupMenuButton<_ReleaseSort>(
          key: const ValueKey('source-sort'),
          tooltip: 'Sort source results',
          initialValue: sort,
          onSelected: onSort,
          itemBuilder: (context) => const [
            PopupMenuItem(value: _ReleaseSort.best, child: Text('Best match')),
            PopupMenuItem(
              value: _ReleaseSort.seeders,
              child: Text('Most seeders'),
            ),
            PopupMenuItem(
              value: _ReleaseSort.quality,
              child: Text('Highest quality'),
            ),
            PopupMenuItem(
              value: _ReleaseSort.size,
              child: Text('Largest file'),
            ),
          ],
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.zeroPalette.panel,
              border: Border.all(color: context.zeroPalette.border),
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ZeroTokens.space2,
                vertical: ZeroTokens.space1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(switch (sort) {
                    _ReleaseSort.best => 'Best',
                    _ReleaseSort.seeders => 'Seeders',
                    _ReleaseSort.quality => 'Quality',
                    _ReleaseSort.size => 'Size',
                  }, style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(width: ZeroTokens.space1),
                  const Icon(Icons.expand_more_rounded, size: 16),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceCloudIcon extends StatelessWidget {
  const _SourceCloudIcon();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.zeroPalette.navSelected,
      shape: BoxShape.circle,
    ),
    child: Padding(
      padding: const EdgeInsets.all(7),
      child: Icon(
        Icons.cloud_outlined,
        size: 18,
        color: context.zeroPalette.accentSoft,
      ),
    ),
  );
}

class _EmptyReleaseResults extends ConsumerWidget {
  const _EmptyReleaseResults({
    required this.loading,
    required this.hasErrors,
    required this.onManual,
  });

  final bool loading;
  final bool hasErrors;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(sourceCatalogProvider).value?.enabledCount ?? 0;
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(ZeroTokens.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                installed == 0
                    ? Icons.extension_off_outlined
                    : Icons.manage_search_rounded,
                size: 32,
                color: context.zeroPalette.inactive,
              ),
              const SizedBox(height: ZeroTokens.space2),
              Text(
                loading
                    ? 'Finding releases…'
                    : installed == 0
                    ? 'Install and enable source extensions in Settings.'
                    : hasErrors
                    ? 'No source returned a release this time.'
                    : 'No matching releases found.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.zeroPalette.textSecondary),
              ),
              if (!loading) ...[
                const SizedBox(height: ZeroTokens.space2),
                TextButton(
                  onPressed: onManual,
                  child: const Text('Enter a link manually'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReleaseResultTile extends StatelessWidget {
  const _ReleaseResultTile({
    required this.result,
    required this.availability,
    required this.checking,
    required this.connected,
    required this.provider,
    required this.onPlay,
  });

  final TorrentResult result;
  final Availability availability;
  final bool checking;
  final bool connected;
  final String provider;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final canPlay =
        connected &&
        (checking ||
            availability == Availability.cached ||
            availability == Availability.unknown);
    return Material(
      color: context.zeroPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
      child: InkWell(
        key: ValueKey('source-result-${result.hash ?? result.link.hashCode}'),
        onTap: canPlay ? onPlay : null,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        child: Padding(
          padding: const EdgeInsets.all(ZeroTokens.space3),
          child: Row(
            children: [
              _AvailabilityBadge(state: availability, checking: checking),
              const SizedBox(width: ZeroTokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: ZeroTokens.space1),
                    Wrap(
                      spacing: ZeroTokens.space2,
                      runSpacing: ZeroTokens.space1,
                      children: [
                        Text(
                          result.sourceId ?? 'Source',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: context.zeroPalette.accentSoft),
                        ),
                        if (result.size != null) Text(_fileSize(result.size!)),
                        if (result.seeders != null)
                          Text('${result.seeders} seeders'),
                        if (result.type != null)
                          Text(result.type!.toUpperCase()),
                        if (explicitReleaseLanguageLabel(result)
                            case final languages?)
                          Text(languages),
                      ],
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: !connected
                    ? 'Connect debrid first'
                    : canPlay
                    ? 'Play through $provider'
                    : availability == Availability.available
                    ? 'This release is not cached by $provider'
                    : 'This release is unavailable on $provider',
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: canPlay
                      ? context.zeroPalette.accentHover
                      : context.zeroPalette.inactive,
                  size: 30,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvailabilityBadge extends StatelessWidget {
  const _AvailabilityBadge({required this.state, required this.checking});

  final Availability state;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    final (label, color, icon) = checking
        ? ('Checking', colors.textSecondary, Icons.sync_rounded)
        : switch (state) {
            Availability.cached => (
              'Cached',
              colors.success,
              Icons.bolt_rounded,
            ),
            Availability.available => (
              'Not cached',
              colors.warning,
              Icons.cloud_queue_rounded,
            ),
            Availability.unavailable => (
              'Unavailable',
              colors.error,
              Icons.cloud_off_outlined,
            ),
            Availability.unknown => (
              'Unknown',
              colors.textSecondary,
              Icons.help_outline_rounded,
            ),
          };
    return SizedBox(
      width: 62,
      child: Column(
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color, fontSize: 9),
          ),
        ],
      ),
    );
  }
}

class _ManualRelease extends StatelessWidget {
  const _ManualRelease({
    required this.controller,
    required this.error,
    required this.connected,
    required this.provider,
    required this.onLaunch,
  });

  final TextEditingController controller;
  final String? error;
  final bool connected;
  final String provider;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('release-magnet'),
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => onLaunch(),
          decoration: const InputDecoration(
            hintText: 'Paste magnet link or info hash',
            prefixIcon: Icon(Icons.link_rounded, size: 19),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: ZeroTokens.space2),
          Text(
            error!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.zeroPalette.error),
          ),
        ],
        const SizedBox(height: ZeroTokens.space2),
        FilledButton.icon(
          key: const ValueKey('resolve-play'),
          onPressed: connected ? onLaunch : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text('Resolve with $provider'),
        ),
      ],
    );
  }
}

String _fileSize(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value >= 10 || unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return Tooltip(
      message: connected ? 'Connected' : 'Not configured',
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: connected ? colors.success : colors.warning,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (connected ? colors.success : colors.warning).withValues(
                alpha: 0.35,
              ),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeStill extends StatelessWidget {
  const _EpisodeStill({required this.media, required this.episode});

  final Media media;
  final EpisodeInfo episode;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    final image = episode.imageUrl ?? media.bannerImage ?? media.coverImage;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: colors.isLight ? 0.24 : 0.65),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusCard - 1),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: ZeroTokens.motionPanel,
                child: image == null
                    ? ColoredBox(
                        key: const ValueKey('episode-still-fallback'),
                        color: colors.surfaceRaised,
                      )
                    : Image(
                        key: ValueKey(image),
                        image: CachedNetworkImageProvider(image),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            ColoredBox(color: colors.surfaceRaised),
                      ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x99000000)],
                  ),
                ),
              ),
              Positioned(
                left: ZeroTokens.space3,
                bottom: ZeroTokens.space3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.88),
                    border: Border.all(color: colors.border),
                    borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ZeroTokens.space3,
                      vertical: ZeroTokens.space1,
                    ),
                    child: Text(
                      'EPISODE ${episode.number}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: context.zeroPalette.textSecondary),
        const SizedBox(width: ZeroTokens.space1),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.entry});

  final ListEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.12),
        border: Border.all(color: colors.success.withValues(alpha: 0.32)),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ZeroTokens.space3,
          vertical: ZeroTokens.space2,
        ),
        child: Text(
          '${_capitalize(entry.status.name)} · ${entry.progress} watched',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: colors.success),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 24,
          decoration: BoxDecoration(
            color: context.zeroPalette.accent,
            borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
          ),
        ),
        const SizedBox(width: ZeroTokens.space3),
        Text(label, style: Theme.of(context).textTheme.headlineMedium),
      ],
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        border: Border.all(color: colors.border),
        shape: BoxShape.circle,
        boxShadow: colors.toastShadow,
      ),
      child: IconButton(
        tooltip: 'Close',
        onPressed: onPressed,
        icon: const Icon(Icons.close_rounded),
      ),
    );
  }
}

int _initialEpisode(Media media) {
  final count = media.maxEpisode ?? 1;
  final next = (media.listEntry?.progress ?? 0) + 1;
  return next.clamp(1, count);
}

int _requestedEpisode(Media media, int? requested) {
  final count = media.maxEpisode ?? 1;
  return (requested ?? _initialEpisode(media)).clamp(1, count);
}

EpisodeInfo _episodeInfo(List<EpisodeInfo> episodes, int number, Media media) {
  final found = episodes
      .where((episode) => episode.number == number)
      .firstOrNull;
  return EpisodeInfo(
    number: number,
    title: found?.title,
    summary: found?.summary,
    imageUrl: found?.imageUrl ?? media.bannerImage ?? media.coverImage,
    durationMinutes: found?.durationMinutes ?? media.duration,
    airDate: found?.airDate,
  );
}

String _episodeDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

String _serviceTitle(DebridService service) => switch (service) {
  DebridService.alldebrid => 'AllDebrid',
  DebridService.premiumize => 'Premiumize',
  DebridService.realdebrid => 'Real-Debrid',
  DebridService.torbox => 'TorBox',
};

String _capitalize(String value) => value.isEmpty
    ? value
    : '${value.substring(0, 1).toUpperCase()}${value.substring(1)}';
