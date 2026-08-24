import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../application/library/providers.dart';
import '../../application/playback/request.dart';
import '../../application/settings/providers.dart';
import '../../application/sources/providers.dart';
import '../../application/playback/coverage.dart';
import '../../domain/models/availability.dart';
import '../../domain/models/media.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/source_extension.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/debrid_client.dart';
import '../../infrastructure/debrid/hash.dart';
import '../../infrastructure/media/filename.dart';
import 'episode_selector.dart';

typedef EpisodeSelected = void Function(Media media, int episode);

/// Opens the details experience over the current library page. The underlying
/// page remains mounted, while the details surface itself uses nearly the full
/// viewport instead of behaving like a small alert dialog.
Future<void> showMediaDetails(
  BuildContext context,
  Media media, {
  EpisodeSelected? onEpisodeSelected,
}) async {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final launch = await showGeneralDialog<PlaybackLaunch>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close details',
    barrierColor: const Color(0xD9000000),
    transitionDuration: reduceMotion ? Duration.zero : ShiruTokens.motionPanel,
    pageBuilder: (context, animation, secondaryAnimation) =>
        MediaDetails(media: media, onEpisodeSelected: onEpisodeSelected),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: ShiruTokens.easeSettle,
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
  if (launch != null && context.mounted) {
    context.push('/player', extra: launch);
  }
}

class MediaDetails extends ConsumerStatefulWidget {
  const MediaDetails({super.key, required this.media, this.onEpisodeSelected});

  final Media media;
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
    _episode = _initialEpisode(media);
    _magnet = TextEditingController();
  }

  @override
  void didUpdateWidget(MediaDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != media.id) {
      _episode = _initialEpisode(media);
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

  void _launch(Settings? settings, [String? selected]) {
    final service = settings?.debridService;
    final key = service == null ? null : settings?.debridApiKeys[service];
    if (service == null || key == null || key.isEmpty) {
      setState(() {
        _releaseError = 'Connect TorBox in Settings before starting playback.';
      });
      return;
    }
    final magnet = selected?.trim() ?? _magnet.text.trim();
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
      minimum: EdgeInsets.all(compact ? 0 : ShiruTokens.space3),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1580, maxHeight: 1040),
          child: FractionallySizedBox(
            widthFactor: compact ? 1 : 0.985,
            heightFactor: compact ? 1 : 0.985,
            child: Material(
              color: ShiruTokens.darkVeryDim,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  compact ? 0 : ShiruTokens.radiusCard,
                ),
                side: compact
                    ? BorderSide.none
                    : const BorderSide(color: ShiruTokens.surfaceBorder),
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
                      onSelectEpisode: _selectEpisode,
                      onLaunch: (source) => _launch(currentSettings, source),
                    ),
                  Positioned(
                    top: ShiruTokens.space3,
                    right: ShiruTokens.space3,
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
                ? const ColoredBox(color: ShiruTokens.darkDim)
                : Image(
                    image: CachedNetworkImageProvider(image),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: ShiruTokens.darkDim),
                  ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x5C090A0B),
                Color(0xD9090A0B),
                ShiruTokens.darkVeryDim,
              ],
              stops: [0, 0.29, 0.55],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.85, -0.75),
              radius: 1.1,
              colors: [Color(0x00123F87), Color(0x80090A0B)],
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
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<String> onLaunch;

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
              ShiruTokens.space4,
              68,
              ShiruTokens.space4,
              ShiruTokens.space4,
            ),
            child: Column(
              children: [
                if (releaseOpen)
                  Expanded(
                    flex: 6,
                    child: _ReleaseHandoff(
                      media: media,
                      episode: episode,
                      open: releaseOpen,
                      error: releaseError,
                      controller: magnet,
                      settings: settings,
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
                    onLaunch: onLaunch,
                  ),
                const SizedBox(height: ShiruTokens.space3),
                Expanded(
                  flex: releaseOpen ? 5 : 10,
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
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<String> onLaunch;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        ShiruTokens.space4,
        120,
        ShiruTokens.space4,
        ShiruTokens.space6,
      ),
      children: [
        _OverviewHeader(
          media: media,
          episode: episode,
          compact: true,
          onWatch: onWatch,
        ),
        const SizedBox(height: ShiruTokens.space5),
        _AboutMedia(media: media),
        if ((media.maxEpisode ?? 0) > 0) ...[
          const SizedBox(height: ShiruTokens.space5),
          SizedBox(
            height: releaseOpen ? 560 : null,
            child: _ReleaseHandoff(
              media: media,
              episode: episode,
              open: releaseOpen,
              error: releaseError,
              controller: magnet,
              settings: settings,
              onLaunch: onLaunch,
            ),
          ),
          const SizedBox(height: ShiruTokens.space3),
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
          ShiruTokens.space6,
          154,
          ShiruTokens.space6,
          ShiruTokens.space7,
        ),
        children: [
          _OverviewHeader(
            media: media,
            episode: episode,
            compact: false,
            onWatch: onWatch,
          ),
          const SizedBox(height: ShiruTokens.space6),
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
          const SizedBox(height: ShiruTokens.space4),
          info,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _Cover(media: media, width: 218),
        const SizedBox(width: ShiruTokens.space5),
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
        const SizedBox(height: ShiruTokens.space4),
        Wrap(
          spacing: ShiruTokens.space4,
          runSpacing: ShiruTokens.space2,
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
        const SizedBox(height: ShiruTokens.space5),
        Wrap(
          spacing: ShiruTokens.space2,
          runSpacing: ShiruTokens.space2,
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
                    padding: const EdgeInsets.only(right: ShiruTokens.space2),
                    child: Chip(
                      avatar: const Icon(Icons.tag_rounded, size: 15),
                      label: Text(genre),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: ShiruTokens.space6),
        ],
        const _SectionTitle(label: 'Synopsis'),
        const SizedBox(height: ShiruTokens.space4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Text(
            _plainDescription(media.description),
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(height: 1.6, color: ShiruTokens.textLight),
          ),
        ),
      ],
    );
  }
}

class _ReleaseHandoff extends ConsumerStatefulWidget {
  const _ReleaseHandoff({
    required this.media,
    required this.episode,
    required this.open,
    required this.error,
    required this.controller,
    required this.settings,
    required this.onLaunch,
  });

  final Media media;
  final int episode;
  final bool open;
  final String? error;
  final TextEditingController controller;
  final Settings? settings;
  final ValueChanged<String> onLaunch;

  @override
  ConsumerState<_ReleaseHandoff> createState() => _ReleaseHandoffState();
}

class _ReleaseHandoffState extends ConsumerState<_ReleaseHandoff> {
  StreamSubscription<SourceSearchBatch>? _subscription;
  Timer? _availabilityTimer;
  final _results = <TorrentResult>[];
  final _availability = <String, Availability>{};
  final _checked = <String>{};
  final _sourceErrors = <String>[];
  bool _loading = false;
  bool _manual = false;
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
    await _subscription?.cancel();
    _availabilityTimer?.cancel();
    final generation = ++_generation;
    setState(() {
      _results.clear();
      _availability.clear();
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
        resolution: widget.settings?.rssQuality ?? '',
        exclusions: const [],
      ),
      movie: widget.media.format == MediaFormat.movie,
    );
    _subscription = stream.listen(
      (batch) {
        if (!mounted || generation != _generation) return;
        final existing = {
          for (final item in _results) (item.hash ?? item.link).toLowerCase(),
        };
        final additions = batch.results.where((item) {
          if (!_holdsEpisode(item)) return false;
          return existing.add((item.hash ?? item.link).toLowerCase());
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
    episodeCount: widget.media.maxEpisode,
  );

  void _scheduleAvailability(int generation, {bool immediate = false}) {
    final settings = widget.settings;
    if ((settings?.debridCacheCheck != true &&
            settings?.debridCachedOnly != true) ||
        settings?.debridService == null ||
        settings?.activeDebridKey?.isNotEmpty != true) {
      return;
    }
    _availabilityTimer?.cancel();
    _availabilityTimer = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 45),
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
      final hash = parseHash(result.hash ?? result.link);
      if (hash != null && _checked.add(hash)) hashes.add(hash);
    }
    if (hashes.isEmpty) return;
    try {
      final answers = await client.availability(key, hashes);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final hash in hashes) {
          _availability[hash] = answers[hash] ?? Availability.unknown;
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _sourceErrors.add('Cache check: $error'));
    }
  }

  List<TorrentResult> get _ranked {
    final values = _results.where((item) {
      if (widget.settings?.debridCachedOnly != true) return true;
      final hash = parseHash(item.hash ?? item.link);
      final state = availabilityOf(_availability, hash);
      return state == Availability.cached || !_availability.containsKey(hash);
    }).toList();
    values.sort((a, b) {
      final aHash = parseHash(a.hash ?? a.link);
      final bHash = parseHash(b.hash ?? b.link);
      var order = availabilityOf(
        _availability,
        aHash,
      ).order.compareTo(availabilityOf(_availability, bHash).order);
      if (order != 0) return order;
      order = _typeRank(a).compareTo(_typeRank(b));
      if (order != 0) return order;
      if (widget.settings?.preferDubs == true) {
        order = _isDub(b.title).compareTo(_isDub(a.title));
        if (order != 0) return order;
      }
      return switch (widget.settings?.torrentSort) {
        'size' => (b.size ?? 0).compareTo(a.size ?? 0),
        'quality' => _quality(b.title).compareTo(_quality(a.title)),
        _ => (b.seeders ?? 0).compareTo(a.seeders ?? 0),
      };
    });
    return values;
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final service = settings?.debridService;
    final connected =
        service != null && (settings?.activeDebridKey?.isNotEmpty ?? false);
    final provider = service == null ? 'TorBox' : _serviceTitle(service);
    final results = _ranked;
    return AnimatedContainer(
      key: const ValueKey('release-handoff'),
      duration: ShiruTokens.motionPanel,
      curve: ShiruTokens.easeSettle,
      width: double.infinity,
      padding: const EdgeInsets.all(ShiruTokens.space3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xF0202327), Color(0xF0121416)],
        ),
        border: Border.all(
          color: widget.open
              ? const Color(0x665D93EA)
              : ShiruTokens.surfaceBorder,
        ),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
      ),
      child: Column(
        mainAxisSize: widget.open ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SourceCloudIcon(),
              const SizedBox(width: ShiruTokens.space2),
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
                            ? ShiruTokens.completed
                            : ShiruTokens.warning,
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
              _ConnectionDot(connected: connected),
            ],
          ),
          if (widget.open) ...[
            const SizedBox(height: ShiruTokens.space2),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: ShiruTokens.space2),
            Expanded(
              child: results.isEmpty
                  ? _EmptyReleaseResults(
                      loading: _loading,
                      hasErrors: _sourceErrors.isNotEmpty,
                      onManual: () => setState(() => _manual = true),
                    )
                  : ListView.separated(
                      key: const ValueKey('source-results'),
                      itemCount: results.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: ShiruTokens.space2),
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final hash = parseHash(result.hash ?? result.link);
                        return _ReleaseResultTile(
                          result: result,
                          availability: availabilityOf(_availability, hash),
                          checking:
                              hash != null &&
                              (settings?.debridCacheCheck == true ||
                                  settings?.debridCachedOnly == true) &&
                              !_availability.containsKey(hash),
                          connected: connected,
                          provider: provider,
                          onPlay: () => widget.onLaunch(result.link),
                        );
                      },
                    ),
            ),
            if (_sourceErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: ShiruTokens.space2),
                child: Text(
                  '${_sourceErrors.length} source operation${_sourceErrors.length == 1 ? '' : 's'} failed; other results remain available.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: ShiruTokens.warning),
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
            if (_manual)
              _ManualRelease(
                controller: widget.controller,
                error: widget.error,
                connected: connected,
                provider: provider,
                onLaunch: () => widget.onLaunch(widget.controller.text),
              ),
          ],
        ],
      ),
    );
  }
}

class _SourceCloudIcon extends StatelessWidget {
  const _SourceCloudIcon();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(color: Color(0x292F75E4), shape: BoxShape.circle),
    child: Padding(
      padding: EdgeInsets.all(7),
      child: Icon(
        Icons.cloud_outlined,
        size: 18,
        color: ShiruTokens.accentVeryLight,
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              installed == 0
                  ? Icons.extension_off_outlined
                  : Icons.manage_search_rounded,
              size: 32,
              color: ShiruTokens.grayVeryDim,
            ),
            const SizedBox(height: ShiruTokens.space2),
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
                  ?.copyWith(color: ShiruTokens.textLight),
            ),
            if (!loading) ...[
              const SizedBox(height: ShiruTokens.space2),
              TextButton(
                onPressed: onManual,
                child: const Text('Enter a link manually'),
              ),
            ],
          ],
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
      color: ShiruTokens.darkVeryLight,
      borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
      child: InkWell(
        key: ValueKey('source-result-${result.hash ?? result.link.hashCode}'),
        onTap: canPlay ? onPlay : null,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        child: Padding(
          padding: const EdgeInsets.all(ShiruTokens.space3),
          child: Row(
            children: [
              _AvailabilityBadge(state: availability, checking: checking),
              const SizedBox(width: ShiruTokens.space3),
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
                    const SizedBox(height: ShiruTokens.space1),
                    Wrap(
                      spacing: ShiruTokens.space2,
                      runSpacing: ShiruTokens.space1,
                      children: [
                        Text(
                          result.sourceId ?? 'Source',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: ShiruTokens.accentVeryLight),
                        ),
                        if (result.size != null) Text(_fileSize(result.size!)),
                        if (result.seeders != null)
                          Text('${result.seeders} seeders'),
                        if (result.type != null)
                          Text(result.type!.toUpperCase()),
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
                      ? ShiruTokens.accentLight
                      : ShiruTokens.grayVeryDim,
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
    final (label, color, icon) = checking
        ? ('Checking', ShiruTokens.textLight, Icons.sync_rounded)
        : switch (state) {
            Availability.cached => (
              'Cached',
              ShiruTokens.completed,
              Icons.bolt_rounded,
            ),
            Availability.available => (
              'Not cached',
              ShiruTokens.warning,
              Icons.cloud_queue_rounded,
            ),
            Availability.unavailable => (
              'Unavailable',
              ShiruTokens.errorVeryLight,
              Icons.cloud_off_outlined,
            ),
            Availability.unknown => (
              'Unknown',
              ShiruTokens.textLight,
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
          const SizedBox(height: ShiruTokens.space2),
          Text(
            error!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: ShiruTokens.errorVeryLight),
          ),
        ],
        const SizedBox(height: ShiruTokens.space2),
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

int _isDub(String title) =>
    RegExp(
      r'\b(dual[ ._-]*audio|dub(?:bed)?|eng(?:lish)?[ ._-]*audio)\b',
      caseSensitive: false,
    ).hasMatch(title)
    ? 1
    : 0;

int _quality(String title) =>
    int.tryParse(
      RegExp(
            r'(2160|1080|720|540|480)p?',
            caseSensitive: false,
          ).firstMatch(title)?.group(1) ??
          '',
    ) ??
    0;

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
    return Tooltip(
      message: connected ? 'Connected' : 'Not configured',
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: connected ? ShiruTokens.completed : ShiruTokens.warning,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (connected ? ShiruTokens.completed : ShiruTokens.warning)
                  .withValues(alpha: 0.35),
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
    return Container(
      width: width,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
        border: Border.all(color: const Color(0x38FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0xA6000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusCard - 1),
        child: AspectRatio(
          aspectRatio: ShiruTokens.cardArtAspect,
          child: media.coverImage == null
              ? const ColoredBox(color: ShiruTokens.darkVeryLight)
              : Image(
                  image: CachedNetworkImageProvider(media.coverImage!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: ShiruTokens.darkVeryLight),
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
        Icon(icon, size: 19, color: ShiruTokens.textLight),
        const SizedBox(width: ShiruTokens.space1),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x1F69D454),
        border: Border.all(color: const Color(0x5269D454)),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.space3,
          vertical: ShiruTokens.space2,
        ),
        child: Text(
          '${_capitalize(entry.status.name)} · ${entry.progress} watched',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: ShiruTokens.completed),
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
            color: ShiruTokens.accent,
            borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
          ),
        ),
        const SizedBox(width: ShiruTokens.space3),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9202327),
        border: Border.all(color: ShiruTokens.surfaceBorder),
        shape: BoxShape.circle,
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 12)],
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
