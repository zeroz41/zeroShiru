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
  bool _releaseOpen = false;
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
      _releaseOpen = widget.onEpisodeSelected == null;
      _releaseError = null;
    });
    widget.onEpisodeSelected?.call(media, episode);
  }

  void _watchNow() {
    if (widget.onEpisodeSelected case final callback?) {
      callback(media, _episode);
      return;
    }
    setState(() {
      _releaseOpen = true;
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
        _releaseError = 'Connect TorBox in Settings before starting playback.';
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
                  _DetailsBackdrop(media: media),
                  if (compact)
                    _CompactDetails(
                      media: media,
                      episode: _episode,
                      releaseOpen: _releaseOpen,
                      releaseError: _releaseError,
                      magnet: _magnet,
                      settings: currentSettings,
                      episodes: episodes,
                      onWatch: _watchNow,
                      onCloseReleases: _closeReleases,
                      onSelectEpisode: _selectEpisode,
                      onLaunch: (source) => _launch(currentSettings, source),
                    )
                  else
                    _DesktopDetails(
                      media: media,
                      episode: _episode,
                      releaseOpen: _releaseOpen,
                      releaseError: _releaseError,
                      magnet: _magnet,
                      settings: currentSettings,
                      episodes: episodes,
                      onWatch: _watchNow,
                      onCloseReleases: _closeReleases,
                      onSelectEpisode: _selectEpisode,
                      onLaunch: (source) => _launch(currentSettings, source),
                    ),
                  Positioned(
                    top: ZeroTokens.space3,
                    right: ZeroTokens.space3,
                    child: _CloseButton(
                      onPressed: () => Navigator.of(context).pop(),
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
  const _DetailsBackdrop({required this.media});

  final Media media;

  @override
  Widget build(BuildContext context) {
    final image = media.bannerImage ?? media.coverImage;
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
    required this.releaseOpen,
    required this.releaseError,
    required this.magnet,
    required this.settings,
    required this.episodes,
    required this.onWatch,
    required this.onCloseReleases,
    required this.onSelectEpisode,
    required this.onLaunch,
  });

  final Media media;
  final int episode;
  final bool releaseOpen;
  final String? releaseError;
  final TextEditingController magnet;
  final Settings? settings;
  final List<EpisodeInfo> episodes;
  final VoidCallback onWatch;
  final VoidCallback onCloseReleases;
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<_ReleaseChoice> onLaunch;

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
            onWatch: onWatch,
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
                if (releaseOpen)
                  Expanded(
                    flex: 5,
                    child: _ReleaseHandoff(
                      media: media,
                      episode: episode,
                      open: releaseOpen,
                      error: releaseError,
                      controller: magnet,
                      settings: settings,
                      onClose: onCloseReleases,
                      onLaunch: onLaunch,
                    ),
                  )
                else
                  _ReleaseHandoff(
                    media: media,
                    episode: episode,
                    open: releaseOpen,
                    error: releaseError,
                    controller: magnet,
                    settings: settings,
                    onClose: onCloseReleases,
                    onLaunch: onLaunch,
                  ),
                const SizedBox(height: ZeroTokens.space3),
                Expanded(
                  flex: releaseOpen ? 6 : 10,
                  child: EpisodeSelector(
                    episodeCount: media.maxEpisode ?? 1,
                    watchedThrough: media.listEntry?.progress ?? 0,
                    selectedEpisode: episode,
                    fallbackArtwork: media.bannerImage ?? media.coverImage,
                    durationMinutes: media.duration,
                    items: episodes,
                    expanded: true,
                    onSelected: onSelectEpisode,
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
    required this.releaseOpen,
    required this.releaseError,
    required this.magnet,
    required this.settings,
    required this.episodes,
    required this.onWatch,
    required this.onCloseReleases,
    required this.onSelectEpisode,
    required this.onLaunch,
  });

  final Media media;
  final int episode;
  final bool releaseOpen;
  final String? releaseError;
  final TextEditingController magnet;
  final Settings? settings;
  final List<EpisodeInfo> episodes;
  final VoidCallback onWatch;
  final VoidCallback onCloseReleases;
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<_ReleaseChoice> onLaunch;

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
          compact: true,
          onWatch: onWatch,
        ),
        const SizedBox(height: ZeroTokens.space5),
        _AboutMedia(media: media),
        if ((media.maxEpisode ?? 0) > 0) ...[
          const SizedBox(height: ZeroTokens.space5),
          SizedBox(
            height: releaseOpen ? 400 : null,
            child: _ReleaseHandoff(
              media: media,
              episode: episode,
              open: releaseOpen,
              error: releaseError,
              controller: magnet,
              settings: settings,
              onClose: onCloseReleases,
              onLaunch: onLaunch,
            ),
          ),
          const SizedBox(height: ZeroTokens.space3),
          EpisodeSelector(
            episodeCount: media.maxEpisode!,
            watchedThrough: media.listEntry?.progress ?? 0,
            selectedEpisode: episode,
            fallbackArtwork: media.bannerImage ?? media.coverImage,
            durationMinutes: media.duration,
            items: episodes,
            maxHeight: 610,
            onSelected: onSelectEpisode,
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
    required this.onWatch,
  });

  final Media media;
  final int episode;
  final VoidCallback onWatch;

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
            compact: false,
            onWatch: onWatch,
          ),
          const SizedBox(height: ZeroTokens.space6),
          _AboutMedia(media: media),
        ],
      ),
    );
  }
}

class _OverviewHeader extends StatelessWidget {
  const _OverviewHeader({
    required this.media,
    required this.episode,
    required this.compact,
    required this.onWatch,
  });

  final Media media;
  final int episode;
  final bool compact;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    final info = _TitleBlock(media: media, episode: episode, onWatch: onWatch);
    if (compact) {
      return Column(
        children: [
          _Cover(media: media, width: 176),
          const SizedBox(height: ZeroTokens.space4),
          info,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _Cover(media: media, width: 218),
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
    required this.onWatch,
  });

  final Media media;
  final int episode;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          media.title.display,
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
            shadows: const [Shadow(color: Colors.black, blurRadius: 18)],
          ),
        ),
        const SizedBox(height: ZeroTokens.space4),
        Wrap(
          spacing: ZeroTokens.space4,
          runSpacing: ZeroTokens.space2,
          children: [
            if (media.averageScore != null)
              _MetaItem(
                icon: Icons.trending_up_rounded,
                label: '${media.averageScore}% score',
              ),
            if (media.format != null)
              _MetaItem(icon: Icons.tv_rounded, label: _format(media.format!)),
            if (media.episodes != null)
              _MetaItem(
                icon: Icons.movie_filter_outlined,
                label: '${media.episodes} episodes',
              ),
            if (media.duration != null)
              _MetaItem(
                icon: Icons.schedule_rounded,
                label: '${media.duration} min',
              ),
            if (media.season != null || media.seasonYear != null)
              _MetaItem(
                icon: Icons.calendar_month_rounded,
                label: [
                  if (media.season != null) _capitalize(media.season!.name),
                  if (media.seasonYear != null) '${media.seasonYear}',
                ].join(' '),
              ),
          ],
        ),
        const SizedBox(height: ZeroTokens.space5),
        Wrap(
          spacing: ZeroTokens.space2,
          runSpacing: ZeroTokens.space2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const ValueKey('watch-now'),
              onPressed: onWatch,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text('Watch episode $episode'),
              style: FilledButton.styleFrom(minimumSize: const Size(214, 44)),
            ),
            if (media.listEntry case final entry?) _StatusPill(entry: entry),
          ],
        ),
      ],
    );
  }
}

class _AboutMedia extends StatelessWidget {
  const _AboutMedia({required this.media});

  final Media media;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (media.genres.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final genre in media.genres)
                  Padding(
                    padding: const EdgeInsets.only(right: ZeroTokens.space2),
                    child: Chip(
                      avatar: const Icon(Icons.tag_rounded, size: 15),
                      label: Text(genre),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: ZeroTokens.space6),
        ],
        const _SectionTitle(label: 'Synopsis'),
        const SizedBox(height: ZeroTokens.space4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Text(
            _plainDescription(media.description),
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

class _ReleaseChoice {
  const _ReleaseChoice(this.magnet, {this.releaseEpisode});

  final String magnet;
  final int? releaseEpisode;
}

class _ReleaseHandoff extends ConsumerStatefulWidget {
  const _ReleaseHandoff({
    required this.media,
    required this.episode,
    required this.open,
    required this.error,
    required this.controller,
    required this.settings,
    required this.onClose,
    required this.onLaunch,
  });

  final Media media;
  final int episode;
  final bool open;
  final String? error;
  final TextEditingController controller;
  final Settings? settings;
  final VoidCallback onClose;
  final ValueChanged<_ReleaseChoice> onLaunch;

  @override
  ConsumerState<_ReleaseHandoff> createState() => _ReleaseHandoffState();
}

enum _ReleaseSort { best, seeders, quality, size }

class _ReleaseHandoffState extends ConsumerState<_ReleaseHandoff> {
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
  _ReleaseSort _sort = _ReleaseSort.best;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.open) unawaited(_search());
  }

  @override
  void didUpdateWidget(_ReleaseHandoff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open &&
        (!oldWidget.open ||
            oldWidget.episode != widget.episode ||
            oldWidget.media.id != widget.media.id)) {
      unawaited(_search());
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _availabilityTimer?.cancel();
    super.dispose();
  }

  Future<void> _search() async {
    final resolver = ref.read(sourceResolverProvider);
    final searchSettings =
        ref.read(settingsControllerProvider).value ?? widget.settings;
    await _subscription?.cancel();
    _availabilityTimer?.cancel();
    final generation = ++_generation;
    setState(() {
      _results.clear();
      _availability.clear();
      _availabilityDetails.clear();
      _releaseEpisodes.clear();
      _rejectedHashes.clear();
      _checked.clear();
      _sourceErrors.clear();
      _loading = resolver != null;
      _manual = false;
    });
    if (resolver == null) return;
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
        _scheduleAvailability(generation);
      },
      onDone: () {
        if (!mounted || generation != _generation) return;
        setState(() => _loading = false);
        _scheduleAvailability(generation, immediate: true);
      },
      onError: (Object error) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _sourceErrors.add('$error');
        });
      },
    );
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

  List<TorrentResult> get _ranked {
    final values = _results.where((item) {
      if (!_canShow(item)) return false;
      if (!_cachedOnly && widget.settings?.debridCachedOnly != true) {
        return true;
      }
      final hash = _hashOf(item);
      final state = availabilityOf(_availability, hash);
      return state == Availability.cached || !_availability.containsKey(hash);
    }).toList();
    values.sort((a, b) {
      final aHash = _hashOf(a);
      final bHash = _hashOf(b);
      var order = availabilityOf(
        _availability,
        aHash,
      ).order.compareTo(availabilityOf(_availability, bHash).order);
      if (order != 0) return order;
      final preferences =
          ref.read(settingsControllerProvider).value ??
          widget.settings ??
          const Settings();
      order =
          releaseLanguagePreferenceScore(
            b,
            audioLanguage: preferences.audioLanguage,
            subtitleLanguage: preferences.releaseSubtitleLanguage,
          ).compareTo(
            releaseLanguagePreferenceScore(
              a,
              audioLanguage: preferences.audioLanguage,
              subtitleLanguage: preferences.releaseSubtitleLanguage,
            ),
          );
      if (order != 0) return order;
      if (_sort == _ReleaseSort.best) {
        order = _preferredQualityTier(
          a.title,
          preferences.rssQuality,
        ).compareTo(_preferredQualityTier(b.title, preferences.rssQuality));
        if (order != 0) return order;
      }
      order = switch (_sort) {
        _ReleaseSort.seeders => (b.seeders ?? 0).compareTo(a.seeders ?? 0),
        _ReleaseSort.quality => _quality(b.title).compareTo(_quality(a.title)),
        _ReleaseSort.size => (b.size ?? 0).compareTo(a.size ?? 0),
        _ReleaseSort.best => _typeRank(a).compareTo(_typeRank(b)),
      };
      if (order != 0) return order;
      return switch (_sort == _ReleaseSort.best
          ? preferences.torrentSort
          : null) {
        'size' => (b.size ?? 0).compareTo(a.size ?? 0),
        'quality' => _quality(b.title).compareTo(_quality(a.title)),
        _ => (b.seeders ?? 0).compareTo(a.seeders ?? 0),
      };
    });
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
                      '$provider · Episode ${widget.episode}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      connected
                          ? widget.open
                                ? _loading
                                      ? 'Searching enabled sources…'
                                      : '${results.length} playable releases'
                                : 'Native source search and direct debrid stream'
                          : 'Connect TorBox in Settings to play',
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
                  onPressed: _loading ? null : _search,
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

int _typeRank(TorrentResult result) => switch (result.type) {
  'best' => 0,
  null => 1,
  'batch' => 2,
  _ => 3,
};

int _quality(String title) =>
    int.tryParse(
      RegExp(
            r'(2160|1080|720|540|480)p?',
            caseSensitive: false,
          ).firstMatch(title)?.group(1) ??
          '',
    ) ??
    0;

int _preferredQualityTier(String title, String preferred) {
  final quality = _quality(title);
  final expected = int.tryParse(preferred);
  if (expected == null || expected <= 0) return 0;
  if (quality == expected) return 0;
  return quality > 0 ? 1 : 2;
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

class _Cover extends StatelessWidget {
  const _Cover({required this.media, required this.width});

  final Media media;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return Container(
      width: width,
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
          aspectRatio: ZeroTokens.cardArtAspect,
          child: media.coverImage == null
              ? ColoredBox(color: colors.surfaceRaised)
              : Image(
                  image: CachedNetworkImageProvider(media.coverImage!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: colors.surfaceRaised),
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

String _format(MediaFormat format) => switch (format) {
  MediaFormat.tv => 'TV series',
  MediaFormat.tvShort => 'TV short',
  MediaFormat.movie => 'Movie',
  MediaFormat.special => 'Special',
  MediaFormat.ova => 'OVA',
  MediaFormat.ona => 'ONA',
  MediaFormat.music => 'Music',
  MediaFormat.unknown => 'Anime',
};

String _serviceTitle(DebridService service) => switch (service) {
  DebridService.alldebrid => 'AllDebrid',
  DebridService.premiumize => 'Premiumize',
  DebridService.realdebrid => 'Real-Debrid',
  DebridService.torbox => 'TorBox',
};

String _capitalize(String value) => value.isEmpty
    ? value
    : '${value.substring(0, 1).toUpperCase()}${value.substring(1)}';

String _plainDescription(String? description) {
  if (description == null || description.trim().isEmpty) {
    return 'No synopsis is available yet.';
  }
  return description
      .replaceAll(RegExp('<br\\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp('<[^>]+>'), '')
      .trim();
}
